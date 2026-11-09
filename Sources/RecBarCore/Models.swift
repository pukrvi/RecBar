import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Quality presets

public enum QualityPreset: String, Codable, CaseIterable, Sendable {
    case compact1080p30
    case native30
    case native60

    public var displayName: String {
        switch self {
        case .compact1080p30: return "Compact — 1080p30 (~1.5 GB/h)"
        case .native30: return "Balanced — Native 30 (~4 GB/h)"
        case .native60: return "Crisp — Native 60 (~9 GB/h)"
        }
    }

    public var shortName: String {
        switch self {
        case .compact1080p30: return "1080p30"
        case .native30: return "Native 30"
        case .native60: return "Native 60"
        }
    }

    public var frameRate: Int {
        switch self {
        case .compact1080p30, .native30: return 30
        case .native60: return 60
        }
    }

    public var videoBitrate: Int {
        switch self {
        case .compact1080p30: return 3_200_000
        case .native30: return 9_000_000
        case .native60: return 20_000_000
        }
    }

    /// Encoder dimensions that fit inside the preset's bounding box, preserving aspect ratio.
    /// Always returns even dimensions (required by the HEVC encoder).
    public func encodedSize(forDisplayWidth displayWidth: Int, height displayHeight: Int) -> (width: Int, height: Int) {
        let width = max(2, displayWidth)
        let height = max(2, displayHeight)
        let scale: Double
        switch self {
        case .compact1080p30:
            scale = min(1.0, min(1920.0 / Double(width), 1080.0 / Double(height)))
        case .native30, .native60:
            scale = 1.0
        }
        var outWidth = max(2, Int((Double(width) * scale).rounded()))
        var outHeight = max(2, Int((Double(height) * scale).rounded()))
        outWidth -= outWidth % 2
        outHeight -= outHeight % 2
        return (outWidth, outHeight)
    }
}

// MARK: - Devices

public struct DisplayInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

public struct AudioDeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public struct CameraDeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - Audio tracks

/// Where an audio track came from. Screen recordings get system audio plus every
/// selected microphone; camera recordings get microphones only.
public enum AudioTrackKind: String, Codable, Sendable {
    case system
    case microphone
}

/// A source that is being captured this session.
public struct AudioTrackDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AudioTrackKind

    public init(id: String, name: String, kind: AudioTrackKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One crash-safe audio segment file on disk.
public struct AudioSegmentInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var fileName: String
    public var startOffset: Double
    public var duration: Double
    public var bytes: Int64
    public var createdAt: Date

    public init(index: Int, fileName: String, startOffset: Double, duration: Double, bytes: Int64, createdAt: Date = Date()) {
        self.index = index
        self.fileName = fileName
        self.startOffset = startOffset
        self.duration = duration
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

/// One logical audio track (system audio or one microphone) and its segments.
public struct AudioTrackInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AudioTrackKind
    public var segments: [AudioSegmentInfo]
    /// Merged standalone backup file, relative to the session folder.
    public var outputFileName: String?

    public init(id: String, name: String, kind: AudioTrackKind, segments: [AudioSegmentInfo] = [], outputFileName: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.segments = segments
        self.outputFileName = outputFileName
    }
}

// MARK: - Settings

public struct RecorderSettings: Codable, Equatable, Sendable {
    public var quality: QualityPreset
    /// AVCaptureDevice.uniqueIDs recorded simultaneously, each to its own track.
    /// Empty means "the system default microphone only".
    public var microphoneIDs: [String]
    /// Capture the Mac's system audio (what the speakers play) as its own track.
    public var recordSystemAudio: Bool
    /// AVCaptureDevice.uniqueID. nil = system default camera.
    public var cameraID: String?
    public var recordCamera: Bool
    /// CGDirectDisplayID. nil = main display.
    public var captureDisplayID: UInt32?
    public var segmentSeconds: Double
    public var keepSegments: Bool
    public var recordingsFolderPath: String
    public var launchAtLogin: Bool
    public var showCursor: Bool
    public var audioBitrate: Int
    public var audioSampleRate: Double
    public var audioChannels: Int
    public var cameraWidth: Int
    public var cameraHeight: Int
    public var cameraBitrate: Int
    public var cameraFrameRate: Int

    public init() {
        self.quality = .compact1080p30
        self.microphoneIDs = []
        self.recordSystemAudio = true
        self.cameraID = nil
        self.recordCamera = true
        self.captureDisplayID = nil
        self.segmentSeconds = 30
        self.keepSegments = false
        self.recordingsFolderPath = RecorderSettings.defaultRecordingsFolder.path
        self.launchAtLogin = false
        self.showCursor = true
        self.audioBitrate = 256_000
        self.audioSampleRate = 48_000
        self.audioChannels = 1
        self.cameraWidth = 1280
        self.cameraHeight = 720
        self.cameraBitrate = 2_000_000
        self.cameraFrameRate = 30
    }

    public static var defaultRecordingsFolder: URL {
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            return movies.appendingPathComponent("RecBar", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/RecBar", isDirectory: true)
    }

    public var recordingsFolder: URL {
        URL(fileURLWithPath: recordingsFolderPath, isDirectory: true)
    }

    public func encodedSize(for display: DisplayInfo) -> (width: Int, height: Int) {
        quality.encodedSize(forDisplayWidth: display.width, height: display.height)
    }

    /// Resolves the selected microphones against what is actually plugged in.
    /// Empty selection means the system default, so a fresh install always records
    /// something without asking the user to pick a device first.
    public func resolvedMicrophoneIDs(from available: [AudioDeviceInfo]) -> [String] {
        let valid = Set(available.map(\.id))
        let selected = microphoneIDs.filter { valid.contains($0) }
        if !selected.isEmpty { return selected }
        if let fallback = available.first(where: { $0.isDefault }) ?? available.first {
            return [fallback.id]
        }
        return []
    }

    private enum CodingKeys: String, CodingKey {
        case quality
        case microphoneID
        case microphoneIDs
        case recordSystemAudio
        case cameraID
        case recordCamera
        case captureDisplayID
        case segmentSeconds
        case keepSegments
        case recordingsFolderPath
        case launchAtLogin
        case showCursor
        case audioBitrate
        case audioSampleRate
        case audioChannels
        case cameraWidth
        case cameraHeight
        case cameraBitrate
        case cameraFrameRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecorderSettings()
        self.quality = try container.decodeIfPresent(QualityPreset.self, forKey: .quality) ?? defaults.quality
        if let ids = try container.decodeIfPresent([String].self, forKey: .microphoneIDs) {
            self.microphoneIDs = ids
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .microphoneID) {
            // Settings written before multi-microphone support.
            self.microphoneIDs = [legacy]
        } else {
            self.microphoneIDs = []
        }
        self.recordSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? defaults.recordSystemAudio
        self.cameraID = try container.decodeIfPresent(String.self, forKey: .cameraID)
        self.recordCamera = try container.decodeIfPresent(Bool.self, forKey: .recordCamera) ?? defaults.recordCamera
        self.captureDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .captureDisplayID)
        self.segmentSeconds = try container.decodeIfPresent(Double.self, forKey: .segmentSeconds) ?? defaults.segmentSeconds
        self.keepSegments = try container.decodeIfPresent(Bool.self, forKey: .keepSegments) ?? defaults.keepSegments
        self.recordingsFolderPath = try container.decodeIfPresent(String.self, forKey: .recordingsFolderPath) ?? defaults.recordingsFolderPath
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        self.showCursor = try container.decodeIfPresent(Bool.self, forKey: .showCursor) ?? defaults.showCursor
        self.audioBitrate = try container.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? defaults.audioBitrate
        self.audioSampleRate = try container.decodeIfPresent(Double.self, forKey: .audioSampleRate) ?? defaults.audioSampleRate
        self.audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels) ?? defaults.audioChannels
        self.cameraWidth = try container.decodeIfPresent(Int.self, forKey: .cameraWidth) ?? defaults.cameraWidth
        self.cameraHeight = try container.decodeIfPresent(Int.self, forKey: .cameraHeight) ?? defaults.cameraHeight
        self.cameraBitrate = try container.decodeIfPresent(Int.self, forKey: .cameraBitrate) ?? defaults.cameraBitrate
        self.cameraFrameRate = try container.decodeIfPresent(Int.self, forKey: .cameraFrameRate) ?? defaults.cameraFrameRate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(microphoneIDs, forKey: .microphoneIDs)
        try container.encode(recordSystemAudio, forKey: .recordSystemAudio)
        try container.encodeIfPresent(cameraID, forKey: .cameraID)
        try container.encode(recordCamera, forKey: .recordCamera)
        try container.encodeIfPresent(captureDisplayID, forKey: .captureDisplayID)
        try container.encode(segmentSeconds, forKey: .segmentSeconds)
        try container.encode(keepSegments, forKey: .keepSegments)
        try container.encode(recordingsFolderPath, forKey: .recordingsFolderPath)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showCursor, forKey: .showCursor)
        try container.encode(audioBitrate, forKey: .audioBitrate)
        try container.encode(audioSampleRate, forKey: .audioSampleRate)
        try container.encode(audioChannels, forKey: .audioChannels)
        try container.encode(cameraWidth, forKey: .cameraWidth)
        try container.encode(cameraHeight, forKey: .cameraHeight)
        try container.encode(cameraBitrate, forKey: .cameraBitrate)
        try container.encode(cameraFrameRate, forKey: .cameraFrameRate)
    }
}

// MARK: - Recording session model

public enum TrackKind: String, Codable, CaseIterable, Sendable {
    case screen
    case camera
}

public struct SegmentInfo: Codable, Equatable, Sendable {
    public var kind: TrackKind
    public var index: Int
    public var fileName: String
    public var startOffset: Double
    public var duration: Double
    public var bytes: Int64
    public var createdAt: Date
    /// Audio track IDs that actually received samples in this segment, in the same
    /// order as the segment file's audio tracks. Empty for video-only segments and
    /// for manifests written before multi-track support.
    public var audioTrackIDs: [String]

    public init(kind: TrackKind, index: Int, fileName: String, startOffset: Double, duration: Double, bytes: Int64, createdAt: Date = Date(), audioTrackIDs: [String] = []) {
        self.kind = kind
        self.index = index
        self.fileName = fileName
        self.startOffset = startOffset
        self.duration = duration
        self.bytes = bytes
        self.createdAt = createdAt
        self.audioTrackIDs = audioTrackIDs
    }

    private enum CodingKeys: String, CodingKey {
        case kind, index, fileName, startOffset, duration, bytes, createdAt, audioTrackIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(TrackKind.self, forKey: .kind)
        self.index = try container.decode(Int.self, forKey: .index)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.startOffset = try container.decode(Double.self, forKey: .startOffset)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.bytes = try container.decode(Int64.self, forKey: .bytes)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.audioTrackIDs = try container.decodeIfPresent([String].self, forKey: .audioTrackIDs) ?? []
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case recording
    case finalizing
    case complete
    case recovered
    case failed
}

public struct SessionManifest: Codable, Sendable {
    public var version: Int
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var settings: RecorderSettings
    public var display: DisplayInfo?
    public var screenSegments: [SegmentInfo]
    public var cameraSegments: [SegmentInfo]
    /// System audio and each microphone, each with its own crash-safe segments.
    public var audioTracks: [AudioTrackInfo]
    /// TrackKind.rawValue -> file name relative to the session folder.
    public var outputs: [String: String]
    /// Audio track ID -> standalone backup file name relative to the session folder.
    public var audioOutputs: [String: String]
    public var lostSeconds: Double
    public var notes: [String]

    public init(id: String, startedAt: Date, status: SessionStatus, settings: RecorderSettings, display: DisplayInfo?) {
        self.version = 2
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.status = status
        self.settings = settings
        self.display = display
        self.screenSegments = []
        self.cameraSegments = []
        self.audioTracks = []
        self.outputs = [:]
        self.audioOutputs = [:]
        self.lostSeconds = 0
        self.notes = []
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, startedAt, endedAt, status, settings, display
        case screenSegments, cameraSegments, audioTracks, outputs, audioOutputs
        case lostSeconds, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.id = try container.decode(String.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.status = try container.decode(SessionStatus.self, forKey: .status)
        self.settings = try container.decode(RecorderSettings.self, forKey: .settings)
        self.display = try container.decodeIfPresent(DisplayInfo.self, forKey: .display)
        self.screenSegments = try container.decodeIfPresent([SegmentInfo].self, forKey: .screenSegments) ?? []
        self.cameraSegments = try container.decodeIfPresent([SegmentInfo].self, forKey: .cameraSegments) ?? []
        self.audioTracks = try container.decodeIfPresent([AudioTrackInfo].self, forKey: .audioTracks) ?? []
        self.outputs = try container.decodeIfPresent([String: String].self, forKey: .outputs) ?? [:]
        self.audioOutputs = try container.decodeIfPresent([String: String].self, forKey: .audioOutputs) ?? [:]
        self.lostSeconds = try container.decodeIfPresent(Double.self, forKey: .lostSeconds) ?? 0
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public var allSegments: [SegmentInfo] {
        (screenSegments + cameraSegments).sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.index < rhs.index }
            return lhs.kind == .screen
        }
    }

    public func segmentURLs(for kind: TrackKind, in folderURL: URL) -> [URL] {
        let segments = kind == .screen ? screenSegments : cameraSegments
        return segments
            .sorted { $0.index < $1.index }
            .map { folderURL.appendingPathComponent("segments").appendingPathComponent($0.fileName) }
    }

    public func outputURL(for kind: TrackKind, in folderURL: URL) -> URL? {
        guard let name = outputs[kind.rawValue] else { return nil }
        return folderURL.appendingPathComponent(name)
    }

    public func audioTrack(id: String) -> AudioTrackInfo? {
        audioTracks.first { $0.id == id }
    }

    public func audioSegmentURLs(for track: AudioTrackInfo, in folderURL: URL) -> [URL] {
        track.segments
            .sorted { $0.index < $1.index }
            .map {
                folderURL
                    .appendingPathComponent("audio", isDirectory: true)
                    .appendingPathComponent("segments", isDirectory: true)
                    .appendingPathComponent($0.fileName)
            }
    }

    public func audioOutputURL(for track: AudioTrackInfo, in folderURL: URL) -> URL? {
        guard let name = audioOutputs[track.id] ?? track.outputFileName else { return nil }
        return folderURL.appendingPathComponent(name)
    }
}

public struct RecordingResult: Sendable {
    public var sessionID: String
    public var folderURL: URL
    public var screenURL: URL?
    public var cameraURL: URL?
    /// Standalone backup audio files (system + each microphone).
    public var audioURLs: [URL]
    public var duration: Double
    public var bytes: Int64

    public init(sessionID: String, folderURL: URL, screenURL: URL?, cameraURL: URL?, audioURLs: [URL] = [], duration: Double, bytes: Int64) {
        self.sessionID = sessionID
        self.folderURL = folderURL
        self.screenURL = screenURL
        self.cameraURL = cameraURL
        self.audioURLs = audioURLs
        self.duration = duration
        self.bytes = bytes
    }

    public var primaryURL: URL? { screenURL ?? cameraURL }
}

public struct RecoverableSession: Sendable, Identifiable {
    public var id: String { manifest.id }
    public var folderURL: URL
    public var manifest: SessionManifest
    public var screenSegments: [URL]
    public var cameraSegments: [URL]
    public var audioTracks: [AudioTrackInfo]
    public var duration: Double
    public var bytes: Int64

    public init(folderURL: URL, manifest: SessionManifest, screenSegments: [URL], cameraSegments: [URL], audioTracks: [AudioTrackInfo] = [], duration: Double, bytes: Int64) {
        self.folderURL = folderURL
        self.manifest = manifest
        self.screenSegments = screenSegments
        self.cameraSegments = cameraSegments
        self.audioTracks = audioTracks
        self.duration = duration
        self.bytes = bytes
    }
}

// MARK: - Runtime state

public enum RecorderState: String, Sendable {
    case idle
    case starting
    case recording
    case paused
    case stopping
    case merging
    case recovering

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Stopping…"
        case .merging: return "Merging…"
        case .recovering: return "Recovering…"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .paused, .stopping, .merging, .recovering: return true
        case .idle: return false
        }
    }
}

// MARK: - Encoding spec

/// Video encoding settings for one segment file. Audio is never muxed into
/// segment files: every source writes its own crash-safe audio chain instead,
/// and the merge step composes the final multi-track files.
public struct SegmentSpec: Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var videoBitrate: Int

    public init(width: Int, height: Int, frameRate: Int, videoBitrate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
    }
}

// MARK: - Errors

public enum RecBarError: LocalizedError {
    case screenPermissionDenied
    case microphonePermissionDenied
    case cameraPermissionDenied
    case noDisplay
    case noMicrophone
    case noCamera
    case diskSpaceLow(available: Int64)
    case writerFailed(String)
    case captureFailed(String)
    case mergeFailed(String)
    case notRecording
    case invalidSession(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .screenPermissionDenied:
            return "Screen Recording permission is required."
        case .microphonePermissionDenied:
            return "Microphone permission is required."
        case .cameraPermissionDenied:
            return "Camera permission is required."
        case .noDisplay:
            return "No display is available to record."
        case .noMicrophone:
            return "No microphone is available."
        case .noCamera:
            return "No camera is available."
        case .diskSpaceLow(let available):
            return "Low disk space (\(Formatting.bytes(available)) free). Recording stopped safely."
        case .writerFailed(let message):
            return "The video writer failed: \(message)"
        case .captureFailed(let message):
            return "Screen capture failed: \(message)"
        case .mergeFailed(let message):
            return "Could not join the recording segments: \(message)"
        case .notRecording:
            return "RecBar is not recording."
        case .invalidSession(let message):
            return "Invalid recording session: \(message)"
        case .cancelled:
            return "Cancelled."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .screenPermissionDenied:
            return "Open System Settings → Privacy & Security → Screen Recording, enable RecBar, then quit and reopen RecBar."
        case .microphonePermissionDenied:
            return "Open System Settings → Privacy & Security → Microphone and enable RecBar."
        case .cameraPermissionDenied:
            return "Open System Settings → Privacy & Security → Camera and enable RecBar."
        case .diskSpaceLow:
            return "All finalized segments were kept. Free some space and try again."
        default:
            return nil
        }
    }
}

// MARK: - Formatting helpers

public enum Formatting {
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }

    /// HH:MM:SS
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// M:SS for the menu bar, H:MM:SS once past an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
