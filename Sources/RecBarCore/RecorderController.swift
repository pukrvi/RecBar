import Foundation
import AppKit
import ServiceManagement

/// Orchestrates a recording session:
///   capture engines -> video SegmentWriters + one AudioTrackWriter per source
///   -> manifest -> lossless multi-track merge.
///
/// The controller is main-actor bound; capture callbacks never touch it directly,
/// they only append into the thread-safe writers.
@MainActor
public final class RecorderController {
    // MARK: Public state

    public private(set) var state: RecorderState = .idle
    public private(set) var settings: RecorderSettings
    public private(set) var lastResult: RecordingResult?
    public private(set) var recoverableSessions: [RecoverableSession] = []
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var currentBytes: Int64 = 0
    public private(set) var mergeProgress: Double = 0
    public private(set) var lastError: Error?
    public private(set) var sessionFolderURL: URL?

    /// Called whenever the recording state or settings change. Main thread.
    public var onStateChanged: (() -> Void)?
    /// Called roughly once a second so the menu bar can refresh its clock and sizes. Main thread.
    public var onTick: (() -> Void)?
    /// Lightweight informational messages ("Recording started", "Saved …").
    public var onNotice: ((String) -> Void)?
    /// Errors that should be shown to the user. Main thread.
    public var onError: ((Error) -> Void)?

    // MARK: Private state

    private let settingsStore: SettingsStore
    private let screenEngine = ScreenCaptureEngine()
    private let cameraEngine = CameraCaptureEngine()
    /// One capture engine per selected microphone, keyed by AVCaptureDevice.uniqueID.
    private var audioEngines: [String: AudioCaptureEngine] = [:]

    private var manifestStore: ManifestStore?
    private var screenWriter: SegmentWriter?
    private var cameraWriter: SegmentWriter?
    /// One audio-only backup writer per source (system audio + each microphone).
    private var audioWriters: [String: AudioTrackWriter] = [:]
    private var audioDescriptors: [AudioTrackDescriptor] = []
    /// Microphone device ID -> audio track ID, for restarting on resume.
    private var activeMicrophones: [(deviceID: String, trackID: String)] = []

    private var sessionDisplay: DisplayInfo?
    private var screenSpec: SegmentSpec?
    private var cameraSpec: SegmentSpec?

    private var recordingStartedAt: Date?
    private var accumulatedElapsed: TimeInterval = 0
    private var tickTimer: Timer?
    private var rotationTimer: Timer?
    private var tickCount = 0
    private var diskWarningShown = false
    private var autoStopping = false
    private var cameraActive = false
    /// False when system audio was requested but ScreenCaptureKit could not start
    /// it; resume then skips it instead of failing the whole recording.
    private var systemAudioActive = false

    /// Buffers can already be in flight on a capture queue when pause/stop begins.
    /// These gates drop them immediately so a late frame can never open a segment
    /// that spans the whole pause (or lands after the writers were finalized).
    private let captureGate = CaptureGate()
    private let cameraGate = CaptureGate()
    /// The camera actually chosen for this session (may be a fallback, not settings.cameraID).
    private var activeCameraDeviceID: String?

    // MARK: Init

    public init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()

        // Keep the stored flag honest about the real login-item state.
        let loginEnabled = SMAppService.mainApp.status == .enabled
        if self.settings.launchAtLogin != loginEnabled {
            self.settings.launchAtLogin = loginEnabled
            settingsStore.save(self.settings)
        }

        loadLatestResultIfAvailable()
        startTicker()
    }

    deinit {
        tickTimer?.invalidate()
        rotationTimer?.invalidate()
    }

    // MARK: Public helpers

    public var isRecording: Bool { state == .recording }
    public var isPaused: Bool { state == .paused }
    public var isBusy: Bool { state.isActive }
    public var recordingsFolder: URL { settings.recordingsFolder }
    public var freeDiskBytes: Int64? { FSUtility.availableBytes(at: settings.recordingsFolder) }

    public func updateSettings(_ mutate: (inout RecorderSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        let loginChanged = updated.launchAtLogin != settings.launchAtLogin
        settings = updated
        settingsStore.save(updated)
        if loginChanged {
            applyLaunchAtLogin(updated.launchAtLogin)
        }
        onStateChanged?()
    }

    // MARK: Start

    public func startRecording() async throws {
        guard state == .idle else { return }
        lastError = nil
        mergeProgress = 0
        diskWarningShown = false
        tickCount = 0
        setState(.starting)

        do {
            try await prepareAndStart()
        } catch {
            await abortStart(error: error)
            throw error
        }
    }

    private func prepareAndStart() async throws {
        // Disk guard: never start if the volume is already critically full.
        let folder = settings.recordingsFolder
        try FSUtility.ensureDirectory(folder)
        if let available = FSUtility.availableBytes(at: folder), available < 5_000_000_000 {
            throw RecBarError.diskSpaceLow(available: available)
        }

        // Screen recording permission must be granted before ScreenCaptureKit will
        // list displays. Never call CGRequestScreenCaptureAccess() here: repeated
        // requests are what produced the endless permission prompts. The menu's
        // permission alert owns the one-time request + relaunch flow.
        guard ScreenCaptureEngine.hasPermission() else {
            throw RecBarError.screenPermissionDenied
        }

        let displays: [DisplayInfo]
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
        } catch {
            if !ScreenCaptureEngine.hasPermission() {
                throw RecBarError.screenPermissionDenied
            }
            throw RecBarError.captureFailed(error.localizedDescription)
        }
        guard let display = pickDisplay(from: displays) else {
            throw RecBarError.noDisplay
        }

        // Microphone permission.
        let availableMicrophones = AudioCaptureEngine.availableMicrophones()
        let resolvedMicrophoneIDs = settings.resolvedMicrophoneIDs(from: availableMicrophones)
        if !resolvedMicrophoneIDs.isEmpty {
            if !AudioCaptureEngine.hasPermission() {
                let granted = await AudioCaptureEngine.requestPermission()
                if !granted { throw RecBarError.microphonePermissionDenied }
            }
            guard !availableMicrophones.isEmpty else {
                throw RecBarError.noMicrophone
            }
        }

        // Camera is optional: if it is unavailable or denied, record screen only.
        var cameraDevice: CameraDeviceInfo?
        if settings.recordCamera {
            let cameras = CameraCaptureEngine.availableCameras()
            let chosen = settings.cameraID.flatMap { id in cameras.first { $0.id == id } }
                ?? cameras.first(where: { $0.isDefault })
                ?? cameras.first
            if let chosen {
                if CameraCaptureEngine.hasPermission() {
                    cameraDevice = chosen
                } else {
                    let granted = await CameraCaptureEngine.requestPermission()
                    if granted {
                        cameraDevice = chosen
                    } else {
                        onNotice?("Camera access denied — recording the screen only.")
                    }
                }
            } else {
                onNotice?("No camera found — recording the screen only.")
            }
        }

        // Create the session folder + manifest.
        let sessionFolder = try makeSessionFolder()
        let manifest = try ManifestStore(folderURL: sessionFolder, settings: settings, display: display)
        let segmentFolder = sessionFolder.appendingPathComponent("segments", isDirectory: true)
        let audioSegmentFolder = sessionFolder
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)

        let (encodedWidth, encodedHeight) = settings.encodedSize(for: display)
        let segmentSeconds = min(300, max(5, settings.segmentSeconds))
        let sampleRate = settings.audioSampleRate
        let microphoneChannels = max(1, min(2, settings.audioChannels))
        let systemAudioEnabled = settings.recordSystemAudio

        // Describe every audio source before starting anything so the manifest and
        // the writers agree on IDs and order.
        let descriptors = makeAudioDescriptors(
            microphoneIDs: resolvedMicrophoneIDs,
            microphones: availableMicrophones,
            includeSystemAudio: systemAudioEnabled
        )
        audioDescriptors = descriptors

        let screenSpec = SegmentSpec(
            width: encodedWidth,
            height: encodedHeight,
            frameRate: settings.quality.frameRate,
            videoBitrate: settings.quality.videoBitrate
        )
        let screenWriter = SegmentWriter(config: .init(
            kind: .screen,
            folderURL: segmentFolder,
            segmentSeconds: segmentSeconds,
            spec: screenSpec
        ))
        screenWriter.onSegmentFinalized = { segment in
            manifest.addSegment(segment)
        }
        screenWriter.onError = { [weak self] error in
            Task { @MainActor in self?.onError?(error) }
        }
        screenWriter.start(at: 0)

        var cameraWriter: SegmentWriter?
        var cameraSpec: SegmentSpec?
        if cameraDevice != nil {
            let camSpec = SegmentSpec(
                width: settings.cameraWidth,
                height: settings.cameraHeight,
                frameRate: settings.cameraFrameRate,
                videoBitrate: settings.cameraBitrate
            )
            let writer = SegmentWriter(config: .init(
                kind: .camera,
                folderURL: segmentFolder,
                segmentSeconds: segmentSeconds,
                spec: camSpec
            ))
            writer.onSegmentFinalized = { segment in
                manifest.addSegment(segment)
            }
            writer.onError = { [weak self] error in
                Task { @MainActor in self?.onError?(error) }
            }
            writer.start(at: 0)
            cameraWriter = writer
            cameraSpec = camSpec
        }

        // Audio writers: one crash-safe M4A chain per source.
        var audioWriters: [String: AudioTrackWriter] = [:]
        for descriptor in descriptors {
            manifest.registerAudioTrack(descriptor)
            let channels = descriptor.kind == .system ? 2 : microphoneChannels
            let writer = AudioTrackWriter(config: .init(
                trackID: descriptor.id,
                displayName: descriptor.name,
                kind: descriptor.kind,
                folderURL: audioSegmentFolder,
                segmentSeconds: segmentSeconds,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: settings.audioBitrate
            ))
            writer.onSegmentFinalized = { segment in
                manifest.addAudioSegment(segment, track: descriptor)
            }
            writer.onError = { [weak self] error in
                Task { @MainActor in
                    self?.onNotice?("Audio stopped for \(descriptor.name): \(error.localizedDescription)")
                }
            }
            writer.start()
            audioWriters[descriptor.id] = writer
        }

        // Microphone engines and their track IDs, in descriptor order.
        var microphones: [(deviceID: String, trackID: String)] = []
        let micDescriptors = descriptors.filter { $0.kind == .microphone }
        for (index, deviceID) in resolvedMicrophoneIDs.enumerated() where index < micDescriptors.count {
            microphones.append((deviceID: deviceID, trackID: micDescriptors[index].id))
        }

        // Wire capture callbacks to the writers (strong captures keep writers alive until stop).
        let screenWriterRef = screenWriter
        let cameraWriterRef = cameraWriter
        let gate = captureGate
        let camGate = cameraGate
        gate.setOpen(true)
        camGate.setOpen(cameraDevice != nil)

        let systemWriter = descriptors.first(where: { $0.kind == .system }).flatMap { audioWriters[$0.id] }
        screenEngine.onSystemAudio = { buffer in
            guard gate.allows() else { return }
            systemWriter?.append(buffer)
        }
        screenEngine.onVideo = { buffer in
            guard gate.allows() else { return }
            screenWriterRef.append(video: buffer)
        }
        screenEngine.onError = { [weak self] error in
            Task { @MainActor in self?.handleScreenError(error) }
        }
        cameraEngine.onVideo = { buffer in
            guard gate.allows(), camGate.allows() else { return }
            cameraWriterRef?.append(video: buffer)
        }
        cameraEngine.onError = { [weak self] error in
            Task { @MainActor in self?.handleCameraError(error) }
        }

        var engines: [String: AudioCaptureEngine] = [:]
        for microphone in microphones {
            guard let writer = audioWriters[microphone.trackID] else { continue }
            let engine = AudioCaptureEngine()
            engine.onAudio = { buffer in
                guard gate.allows() else { return }
                writer.append(buffer)
            }
            engine.onError = { [weak self] error in
                Task { @MainActor in
                    self?.onNotice?("Microphone stopped: \(error.localizedDescription)")
                }
            }
            engines[microphone.deviceID] = engine
        }

        do {
            // Screen first: the segment's session start should be a video timestamp,
            // not a microphone buffer that arrives a few hundred ms earlier.
            let options = ScreenCaptureEngine.Options(
                display: display,
                width: encodedWidth,
                height: encodedHeight,
                frameRate: settings.quality.frameRate,
                showsCursor: settings.showCursor,
                capturesSystemAudio: systemAudioEnabled,
                systemAudioSampleRate: sampleRate,
                systemAudioChannels: 2
            )
            do {
                try await screenEngine.start(options: options)
                systemAudioActive = systemAudioEnabled
            } catch {
                guard systemAudioEnabled else { throw error }
                // A system-audio problem must not block the screen recording.
                onNotice?("System audio could not start — recording without it.")
                var videoOnly = options
                videoOnly.capturesSystemAudio = false
                try await screenEngine.start(options: videoOnly)
                screenEngine.onSystemAudio = nil
                systemAudioActive = false
            }

            for microphone in microphones {
                guard let engine = engines[microphone.deviceID] else { continue }
                do {
                    try engine.start(
                        deviceID: microphone.deviceID,
                        sampleRate: sampleRate,
                        channels: microphoneChannels
                    )
                } catch {
                    onNotice?("Microphone \(microphone.deviceID) could not start: \(error.localizedDescription)")
                }
            }

            if let cameraDevice {
                do {
                    try cameraEngine.start(
                        deviceID: cameraDevice.id,
                        width: settings.cameraWidth,
                        height: settings.cameraHeight,
                        frameRate: settings.cameraFrameRate,
                        mirror: true
                    )
                    cameraActive = true
                    activeCameraDeviceID = cameraDevice.id
                } catch {
                    cameraActive = false
                    cameraGate.setOpen(false)
                    cameraWriter?.cancel()
                    cameraWriter = nil
                    cameraSpec = nil
                    onNotice?("Camera could not start — recording the screen only.")
                }
            }
        } catch {
            // The caller aborts and cleans up.
            self.manifestStore = manifest
            self.sessionFolderURL = sessionFolder
            self.screenWriter = screenWriter
            self.cameraWriter = cameraWriter
            self.audioWriters = audioWriters
            self.audioEngines = engines
            self.activeMicrophones = microphones
            throw error
        }

        self.manifestStore = manifest
        self.sessionFolderURL = sessionFolder
        self.sessionDisplay = display
        self.screenSpec = screenSpec
        self.cameraSpec = cameraSpec
        self.screenWriter = screenWriter
        self.cameraWriter = cameraWriter
        self.audioWriters = audioWriters
        self.audioEngines = engines
        self.activeMicrophones = microphones
        self.recordingStartedAt = Date()
        self.accumulatedElapsed = 0
        self.elapsed = 0
        self.currentBytes = 0
        self.mergeProgress = 0
        startRotationTimer()
        setState(.recording)
        onNotice?("Recording started")
    }

    // MARK: Pause / resume

    public func pauseRecording() async {
        guard state == .recording else { return }
        if let started = recordingStartedAt {
            accumulatedElapsed += Date().timeIntervalSince(started)
        }
        recordingStartedAt = nil
        elapsed = accumulatedElapsed
        stopRotationTimer()
        setState(.paused)

        // Close the gates before stopping the engines: a buffer already dispatched on
        // a capture queue must not open a segment at pause time that then spans the
        // entire pause until the next resume frame.
        captureGate.setOpen(false)
        cameraGate.setOpen(false)

        await screenEngine.stop()
        stopMicrophoneEngines()
        cameraEngine.stop()
        cameraActive = false
        rotateAllWriters(at: accumulatedElapsed)
        onNotice?("Recording paused")
    }

    public func resumeRecording() async throws {
        guard state == .paused else { return }
        guard let display = sessionDisplay, let screenSpec else {
            throw RecBarError.notRecording
        }
        setState(.starting)
        do {
            // Update the logical offset for the next segment on every writer before
            // any new samples arrive.
            rotateAllWriters(at: accumulatedElapsed)
            captureGate.setOpen(true)

            let options = ScreenCaptureEngine.Options(
                display: display,
                width: screenSpec.width,
                height: screenSpec.height,
                frameRate: screenSpec.frameRate,
                showsCursor: settings.showCursor,
                capturesSystemAudio: systemAudioActive,
                systemAudioSampleRate: settings.audioSampleRate,
                systemAudioChannels: 2
            )
            do {
                try await screenEngine.start(options: options)
            } catch {
                guard systemAudioActive else { throw error }
                onNotice?("System audio could not restart — continuing without it.")
                var videoOnly = options
                videoOnly.capturesSystemAudio = false
                try await screenEngine.start(options: videoOnly)
                screenEngine.onSystemAudio = nil
                systemAudioActive = false
            }

            let sampleRate = settings.audioSampleRate
            let microphoneChannels = max(1, min(2, settings.audioChannels))
            for microphone in activeMicrophones {
                guard let engine = audioEngines[microphone.deviceID] else { continue }
                do {
                    try engine.start(
                        deviceID: microphone.deviceID,
                        sampleRate: sampleRate,
                        channels: microphoneChannels
                    )
                } catch {
                    onNotice?("Microphone could not restart: \(error.localizedDescription)")
                }
            }

            if cameraWriter != nil {
                do {
                    try cameraEngine.start(
                        deviceID: activeCameraDeviceID ?? settings.cameraID,
                        width: settings.cameraWidth,
                        height: settings.cameraHeight,
                        frameRate: settings.cameraFrameRate,
                        mirror: true
                    )
                    cameraActive = true
                    cameraGate.setOpen(true)
                } catch {
                    cameraActive = false
                    cameraGate.setOpen(false)
                    // Close the current camera record so the still-running mic does not
                    // keep filling it with audio-only segments for the rest of the session.
                    cameraWriter?.rotate(at: accumulatedElapsed)
                    onNotice?("Camera could not restart — continuing with screen only.")
                }
            }

            recordingStartedAt = Date()
            startRotationTimer()
            setState(.recording)
            onNotice?("Recording resumed")
        } catch {
            captureGate.setOpen(false)
            cameraGate.setOpen(false)
            stopMicrophoneEngines()
            cameraEngine.stop()
            cameraActive = false
            // Drop any record that a stray audio buffer opened before the failure.
            rotateAllWriters(at: accumulatedElapsed)
            setState(.paused)
            throw error
        }
    }

    // MARK: Stop

    @discardableResult
    public func stopRecording() async throws -> RecordingResult {
        guard state == .recording || state == .paused else {
            throw RecBarError.notRecording
        }

        if let started = recordingStartedAt {
            accumulatedElapsed += Date().timeIntervalSince(started)
            recordingStartedAt = nil
        }
        elapsed = accumulatedElapsed
        stopRotationTimer()
        setState(.stopping)

        // Drop in-flight buffers before finalizing so they cannot reopen a segment.
        captureGate.setOpen(false)
        cameraGate.setOpen(false)

        // Stop capture first so no new buffers arrive while we finalize.
        await screenEngine.stop()
        stopMicrophoneEngines()
        cameraEngine.stop()
        cameraActive = false
        activeCameraDeviceID = nil
        systemAudioActive = false

        screenEngine.onVideo = nil
        screenEngine.onSystemAudio = nil
        screenEngine.onError = nil
        cameraEngine.onVideo = nil
        cameraEngine.onError = nil

        let screenWriter = self.screenWriter
        let cameraWriter = self.cameraWriter
        let audioWriters = self.audioWriters
        let descriptors = self.audioDescriptors
        self.screenWriter = nil
        self.cameraWriter = nil
        self.audioWriters = [:]
        self.audioEngines = [:]
        self.activeMicrophones = []

        var screenSegments: [SegmentInfo] = []
        var cameraSegments: [SegmentInfo] = []
        if let screenWriter {
            do {
                screenSegments = try await screenWriter.finish()
            } catch {
                lastError = error
                onError?(error)
            }
        }
        if let cameraWriter {
            do {
                cameraSegments = try await cameraWriter.finish()
            } catch {
                lastError = error
                onError?(error)
            }
        }

        var audioSegmentsByTrack: [String: [AudioSegmentInfo]] = [:]
        for (trackID, writer) in audioWriters {
            do {
                audioSegmentsByTrack[trackID] = try await writer.finish()
            } catch {
                NSLog("RecBar: audio finish failed for %@: %@", trackID, String(describing: error))
            }
        }

        guard !screenSegments.isEmpty || !cameraSegments.isEmpty else {
            manifestStore?.setStatus(.failed)
            manifestStore?.addNote("No video frames were captured.")
            manifestStore = nil
            sessionFolderURL = nil
            sessionDisplay = nil
            screenSpec = nil
            cameraSpec = nil
            audioDescriptors = []
            setState(.idle)
            let error = RecBarError.writerFailed("No video frames were captured.")
            lastError = error
            throw error
        }

        guard let folder = sessionFolderURL, let manifest = manifestStore else {
            setState(.idle)
            throw RecBarError.invalidSession("The session folder is missing.")
        }

        manifest.setStatus(.finalizing)
        manifest.setEndedNow()
        setState(.merging)
        mergeProgress = 0
        onTick?()

        let segmentFolder = folder.appendingPathComponent("segments", isDirectory: true)
        let audioSegmentFolder = folder
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)
        let screenURLs = screenSegments.map { segmentFolder.appendingPathComponent($0.fileName) }
        let cameraURLs = cameraSegments.map { segmentFolder.appendingPathComponent($0.fileName) }

        let mergeAudioTracks: [MergeAudioTrack] = descriptors.compactMap { descriptor in
            let segments = (audioSegmentsByTrack[descriptor.id] ?? [])
                .sorted { $0.index < $1.index }
                .map { audioSegmentFolder.appendingPathComponent($0.fileName) }
            guard !segments.isEmpty else { return nil }
            return MergeAudioTrack(
                id: descriptor.id,
                name: descriptor.name,
                kind: descriptor.kind,
                segments: segments,
                outputFileName: "audio/\(descriptor.id).m4a"
            )
        }

        do {
            let outcome = try await MergeService().merge(
                screenSegments: screenURLs,
                cameraSegments: cameraURLs,
                audioTracks: mergeAudioTracks,
                folderURL: folder,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.mergeProgress = progress
                        self?.onTick?()
                    }
                }
            )

            if let url = outcome.screenURL {
                manifest.setOutput(kind: .screen, fileName: url.lastPathComponent)
            }
            if let url = outcome.cameraURL {
                manifest.setOutput(kind: .camera, fileName: url.lastPathComponent)
            }
            for track in mergeAudioTracks {
                guard let url = outcome.audioURLs[track.id] else { continue }
                manifest.setAudioOutput(trackID: track.id, fileName: relativePath(of: url, in: folder))
            }
            manifest.setStatus(.complete)
            manifest.setEndedNow()

            if !settings.keepSegments {
                try? FileManager.default.removeItem(at: segmentFolder)
                try? FileManager.default.removeItem(at: audioSegmentFolder)
            }

            let outputURLs = [outcome.screenURL, outcome.cameraURL].compactMap { $0 } + Array(outcome.audioURLs.values)
            let outputBytes = outputURLs.map { FSUtility.fileSize(at: $0) }.reduce(0, +)

            let result = RecordingResult(
                sessionID: folder.lastPathComponent,
                folderURL: folder,
                screenURL: outcome.screenURL,
                cameraURL: outcome.cameraURL,
                audioURLs: outcome.audioURLs.values.sorted { $0.lastPathComponent < $1.lastPathComponent },
                duration: outcome.duration,
                bytes: outputBytes
            )
            lastResult = result
            currentBytes = outputBytes
            mergeProgress = 1

            self.manifestStore = nil
            self.sessionFolderURL = nil
            self.sessionDisplay = nil
            self.screenSpec = nil
            self.cameraSpec = nil
            self.audioDescriptors = []
            setState(.idle)
            onNotice?("Saved \(outcome.screenURL?.lastPathComponent ?? folder.lastPathComponent)")
            return result
        } catch {
            manifest.setStatus(.failed)
            manifest.addNote("Merge failed: \(error.localizedDescription)")
            lastError = error
            self.manifestStore = nil
            self.sessionFolderURL = nil
            self.sessionDisplay = nil
            self.screenSpec = nil
            self.cameraSpec = nil
            self.audioDescriptors = []
            setState(.idle)
            onError?(error)
            throw error
        }
    }

    // MARK: Recovery

    public func refreshRecoverableSessions() {
        let folder = recordingsFolder
        Task { [weak self] in
            let sessions = await Task.detached(priority: .utility) {
                RecoveryService.scan(folderURL: folder)
            }.value
            guard let self else { return }
            self.recoverableSessions = sessions
            self.onStateChanged?()
        }
    }

    public func recoverAllInterrupted(keepSegments: Bool? = nil) async {
        guard !recoverableSessions.isEmpty, state == .idle else { return }
        let sessions = recoverableSessions
        let keep = keepSegments ?? settings.keepSegments
        setState(.recovering)
        mergeProgress = 0
        var recovered: RecordingResult?

        for session in sessions {
            do {
                let result = try await RecoveryService.recover(
                    session,
                    keepSegments: keep,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.mergeProgress = progress
                            self?.onTick?()
                        }
                    }
                )
                recovered = result
                lastResult = result
                recoverableSessions.removeAll { $0.id == session.id }
                onNotice?("Recovered \(result.sessionID)")
            } catch {
                lastError = error
                onError?(error)
            }
        }

        mergeProgress = 0
        setState(.idle)
        refreshRecoverableSessions()
        if let recovered {
            lastResult = recovered
        }
    }

    // MARK: Menu helpers

    public func openRecordingsFolder() {
        let folder = recordingsFolder
        try? FSUtility.ensureDirectory(folder)
        NSWorkspace.shared.open(folder)
    }

    public func openLastRecording() {
        if let url = lastResult?.primaryURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            openRecordingsFolder()
        }
    }

    public func revealLastRecording() {
        if let url = lastResult?.primaryURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openRecordingsFolder()
        }
    }

    public func copyLastRecordingPath() {
        guard let url = lastResult?.primaryURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        onNotice?("Copied \(url.path)")
    }

    // MARK: Internal helpers

    private func setState(_ newState: RecorderState) {
        guard state != newState else { return }
        state = newState
        onStateChanged?()
    }

    private func startTicker() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func startRotationTimer() {
        stopRotationTimer()
        let interval = min(300, max(5, settings.segmentSeconds))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateSegments() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func stopRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    private func currentLogicalOffset() -> TimeInterval {
        if let started = recordingStartedAt {
            return accumulatedElapsed + Date().timeIntervalSince(started)
        }
        return accumulatedElapsed
    }

    private func rotateSegments() {
        guard state == .recording else { return }
        rotateAllWriters(at: currentLogicalOffset())
    }

    /// Closes the current segment on every writer at the same logical instant, so
    /// video and audio segment boundaries stay aligned through pauses.
    private func rotateAllWriters(at offset: TimeInterval) {
        let clamped = max(0, offset)
        screenWriter?.rotate(at: clamped)
        cameraWriter?.rotate(at: clamped)
        for writer in audioWriters.values {
            writer.rotate(at: clamped)
        }
    }

    private func stopMicrophoneEngines() {
        for engine in audioEngines.values {
            engine.stop()
        }
    }

    private func tick() {
        tickCount += 1

        if state == .recording {
            if let started = recordingStartedAt {
                elapsed = accumulatedElapsed + Date().timeIntervalSince(started)
            }
            var bytes = (screenWriter?.totalFinalizedBytes ?? 0) + (screenWriter?.currentPartialBytes ?? 0)
            bytes += (cameraWriter?.totalFinalizedBytes ?? 0) + (cameraWriter?.currentPartialBytes ?? 0)
            for writer in audioWriters.values {
                bytes += writer.totalFinalizedBytes + writer.currentPartialBytes
            }
            currentBytes = bytes

            if tickCount % 10 == 0 {
                checkDiskSpace()
            }
        } else if state == .paused {
            elapsed = accumulatedElapsed
        }

        onTick?()
    }

    private func checkDiskSpace() {
        guard !autoStopping, state == .recording else { return }
        guard let available = freeDiskBytes else { return }

        if available < 5_000_000_000 {
            autoStopping = true
            let error = RecBarError.diskSpaceLow(available: available)
            lastError = error
            onError?(error)
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.stopRecording()
                    self.onNotice?("Recording saved before the disk filled up.")
                } catch {
                    self.onNotice?("Could not finish the recording: \(error.localizedDescription)")
                }
                self.autoStopping = false
            }
        } else if available < 15_000_000_000, !diskWarningShown {
            diskWarningShown = true
            onNotice?("Only \(Formatting.bytes(available)) free. Recording stops automatically below 5 GB.")
        }
    }

    private func pickDisplay(from displays: [DisplayInfo]) -> DisplayInfo? {
        if let requested = settings.captureDisplayID,
           let match = displays.first(where: { $0.id == requested }) {
            return match
        }
        return displays.first(where: { $0.isMain }) ?? displays.first
    }

    private func makeSessionFolder() throws -> URL {
        let base = settings.recordingsFolder
        try FSUtility.ensureDirectory(base)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let stamp = formatter.string(from: Date())
        var candidate = base.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FSUtility.ensureDirectory(candidate)
        try FSUtility.ensureDirectory(candidate.appendingPathComponent("segments", isDirectory: true))
        try FSUtility.ensureDirectory(
            candidate
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent("segments", isDirectory: true)
        )
        return candidate
    }

    /// Builds stable track IDs. The system track is always "system"; microphones
    /// get a readable slug from their device name plus a numeric suffix on collision.
    private func makeAudioDescriptors(
        microphoneIDs: [String],
        microphones: [AudioDeviceInfo],
        includeSystemAudio: Bool
    ) -> [AudioTrackDescriptor] {
        var descriptors: [AudioTrackDescriptor] = []
        if includeSystemAudio {
            descriptors.append(AudioTrackDescriptor(id: "system", name: "System Audio", kind: .system))
        }

        var used = Set(descriptors.map(\.id))
        for (index, deviceID) in microphoneIDs.enumerated() {
            let name = microphones.first(where: { $0.id == deviceID })?.name ?? "Microphone \(index + 1)"
            let base = "mic-" + slug(name)
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            descriptors.append(AudioTrackDescriptor(id: candidate, name: name, kind: .microphone))
        }
        return descriptors
    }

    private func slug(_ value: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            let code = scalar.value
            let isLetter = code >= 97 && code <= 122
            let isDigit = code >= 48 && code <= 57
            if isLetter || isDigit {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "microphone" : trimmed
    }

    private func relativePath(of url: URL, in folder: URL) -> String {
        let prefix = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    private func abortStart(error: Error) async {
        captureGate.setOpen(false)
        cameraGate.setOpen(false)
        stopRotationTimer()
        await screenEngine.stop()
        stopMicrophoneEngines()
        cameraEngine.stop()
        cameraActive = false
        activeCameraDeviceID = nil
        systemAudioActive = false

        screenEngine.onVideo = nil
        screenEngine.onSystemAudio = nil
        screenEngine.onError = nil
        cameraEngine.onVideo = nil
        cameraEngine.onError = nil

        screenWriter?.cancel()
        cameraWriter?.cancel()
        for writer in audioWriters.values {
            writer.cancel()
        }
        screenWriter = nil
        cameraWriter = nil
        audioWriters = [:]
        audioEngines = [:]
        activeMicrophones = []
        audioDescriptors = []

        if let manifestStore {
            manifestStore.setStatus(.failed)
            manifestStore.addNote("Start failed: \(error.localizedDescription)")
        }

        // Remove a completely empty session folder so aborted starts don't clutter things.
        if let folder = sessionFolderURL {
            let segmentFolder = folder.appendingPathComponent("segments", isDirectory: true)
            let videoFiles = FSUtility.contents(of: segmentFolder).filter { $0.pathExtension == "mp4" }
            if videoFiles.isEmpty {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        manifestStore = nil
        sessionFolderURL = nil
        sessionDisplay = nil
        screenSpec = nil
        cameraSpec = nil
        recordingStartedAt = nil
        accumulatedElapsed = 0
        elapsed = 0
        currentBytes = 0
        mergeProgress = 0
        lastError = error
        setState(.idle)
    }

    private func handleScreenError(_ error: Error) {
        guard state == .recording || state == .paused, !autoStopping else { return }
        autoStopping = true
        lastError = error
        onError?(error)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.stopRecording()
                self.onNotice?("Screen capture stopped — the recording was saved.")
            } catch {
                self.onNotice?("Screen capture stopped. \(error.localizedDescription)")
            }
            self.autoStopping = false
        }
    }

    private func handleCameraError(_ error: Error) {
        cameraEngine.stop()
        cameraActive = false
        cameraGate.setOpen(false)
        cameraWriter?.rotate(at: currentLogicalOffset())
        onNotice?("Camera stopped — continuing with screen only.")
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsStore.save(settings)
            onError?(error)
        }
    }

    private func loadLatestResultIfAvailable() {
        let folder = recordingsFolder
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let candidates = FSUtility.contents(of: folder)
        var manifests: [(URL, SessionManifest)] = []
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let manifest = try? ManifestStore.load(from: candidate),
               manifest.status == .complete || manifest.status == .recovered {
                manifests.append((candidate, manifest))
            }
        }
        guard let latest = manifests.max(by: { $0.1.startedAt < $1.1.startedAt }) else { return }
        let (folderURL, manifest) = latest
        let screenURL = manifest.outputURL(for: .screen, in: folderURL)
        let cameraURL = manifest.outputURL(for: .camera, in: folderURL)
        guard screenURL != nil || cameraURL != nil else { return }
        let audioURLs = manifest.audioTracks.compactMap { manifest.audioOutputURL(for: $0, in: folderURL) }
        let duration = (manifest.screenSegments + manifest.cameraSegments).map(\.duration).reduce(0, +)
        let bytes = ([screenURL, cameraURL].compactMap { $0 } + audioURLs)
            .map { FSUtility.fileSize(at: $0) }
            .reduce(0, +)
        lastResult = RecordingResult(
            sessionID: manifest.id,
            folderURL: folderURL,
            screenURL: screenURL,
            cameraURL: cameraURL,
            audioURLs: audioURLs,
            duration: duration,
            bytes: bytes
        )
    }
}

/// A tiny thread-safe open/closed gate. Capture callbacks run on their own queues,
/// so pause/stop must be able to close the gate without racing a buffer append.
private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func setOpen(_ value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }

    func allows() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }
}
