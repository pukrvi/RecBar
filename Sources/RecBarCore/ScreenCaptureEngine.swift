import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Captures one display through ScreenCaptureKit and hands raw `CMSampleBuffer`s to the
/// controller. Buffers are delivered on a private serial queue, never the main thread.
public final class ScreenCaptureEngine: NSObject {
    public struct Options: Sendable {
        public var display: DisplayInfo
        public var width: Int
        public var height: Int
        public var frameRate: Int
        public var showsCursor: Bool
        /// Capture the Mac's own audio output as a separate stream.
        public var capturesSystemAudio: Bool
        public var systemAudioSampleRate: Double
        public var systemAudioChannels: Int

        public init(display: DisplayInfo, width: Int, height: Int, frameRate: Int, showsCursor: Bool,
                    capturesSystemAudio: Bool = false, systemAudioSampleRate: Double = 48_000,
                    systemAudioChannels: Int = 2) {
            self.display = display
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.showsCursor = showsCursor
            self.capturesSystemAudio = capturesSystemAudio
            self.systemAudioSampleRate = systemAudioSampleRate
            self.systemAudioChannels = systemAudioChannels
        }
    }

    public var onVideo: ((CMSampleBuffer) -> Void)?
    /// System audio (what the speakers play), delivered on `sampleQueue`.
    public var onSystemAudio: ((CMSampleBuffer) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onStopped: (() -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.recbar.capture.screen", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    /// Guarantees `onStopped` fires exactly once per start/stop cycle.
    private var stopNotified = false

    // Frame tracking. Only touched from `sampleQueue` (the stream output callback queue),
    // which is also where `resetFrameTracking()` hops before a new capture session starts.
    private var lastCompletePixelBuffer: CVPixelBuffer?
    private var lastCompleteFormatDescription: CMVideoFormatDescription?
    private var loggedFirstCompleteFrame = false

    public override init() {
        super.init()
    }

    // MARK: - Displays

    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()

        // NSScreen is main-thread only, so resolve names up front and hand back a Sendable map.
        let namesByDisplayID = await MainActor.run { () -> [UInt32: String] in
            var names: [UInt32: String] = [:]
            for screen in NSScreen.screens {
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                if let displayID = number?.uint32Value {
                    names[displayID] = screen.localizedName
                }
            }
            return names
        }

        var displays: [DisplayInfo] = content.displays.map { display in
            DisplayInfo(
                id: display.displayID,
                name: namesByDisplayID[display.displayID] ?? "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                isMain: display.displayID == mainDisplayID
            )
        }

        displays.sort { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return displays
    }

    // MARK: - Permission

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Asks the system exactly once in the app's lifetime. Repeated
    /// `CGRequestScreenCaptureAccess()` calls are what made RecBar re-prompt on
    /// every start; after the first request the alert/settings flow takes over.
    public static func requestPermissionOnceOnFirstLaunch() {
        let key = "RecBarDidRequestScreenCapture"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard !hasPermission() else { return }
        _ = requestPermission()
    }

    public static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    public func start(options: Options) async throws {
        // Replace any previous capture cleanly instead of leaking a running stream.
        await stopExistingStream()
        resetFrameTracking()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw RecBarError.captureFailed(error.localizedDescription)
        }

        guard let display = content.displays.first(where: { $0.displayID == options.display.id }) else {
            throw RecBarError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, options.width)
        configuration.height = max(2, options.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.frameRate)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = options.showsCursor
        configuration.queueDepth = 5
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if options.capturesSystemAudio {
            configuration.sampleRate = Int(options.systemAudioSampleRate)
            configuration.channelCount = max(1, min(2, options.systemAudioChannels))
        }
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.capturesSystemAudio {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
        } catch {
            throw RecBarError.captureFailed("Could not attach the capture output: \(error.localizedDescription)")
        }

        installStream(newStream)

        do {
            try await newStream.startCapture()
        } catch {
            discardStream(newStream)
            throw RecBarError.captureFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        let existing = takeStream()
        let shouldNotify = markStopNotified()

        if let existing {
            try? await existing.stopCapture()
        }
        if shouldNotify {
            onStopped?()
        }
    }

    /// Stops a previously running stream without touching `onStopped`; used when restarting.
    private func stopExistingStream() async {
        if let existing = takeStream() {
            try? await existing.stopCapture()
        }
    }

    // MARK: - Stream state (synchronous so it is safe to call from async contexts)

    private func installStream(_ newStream: SCStream) {
        stateLock.lock()
        stream = newStream
        stopNotified = false
        stateLock.unlock()
    }

    private func takeStream() -> SCStream? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let existing = stream
        stream = nil
        return existing
    }

    private func discardStream(_ candidate: SCStream) {
        stateLock.lock()
        if stream === candidate {
            stream = nil
        }
        stateLock.unlock()
    }

    /// Returns true the first time it is called in a start/stop cycle.
    private func markStopNotified() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let shouldNotify = !stopNotified
        stopNotified = true
        return shouldNotify
    }

    /// Clears the remembered frame so a new session starts clean. Frame state lives on
    /// `sampleQueue`, so reset it there to avoid racing the output callback.
    private func resetFrameTracking() {
        sampleQueue.sync {
            lastCompletePixelBuffer = nil
            lastCompleteFormatDescription = nil
            loggedFirstCompleteFrame = false
        }
    }

    // MARK: - Stream events

    private func handleStreamStopped(_ stream: SCStream, error: Error) {
        stateLock.lock()
        let isCurrent = self.stream === stream
        if isCurrent {
            self.stream = nil
        }
        let shouldNotify = isCurrent && !stopNotified
        if shouldNotify {
            stopNotified = true
        }
        stateLock.unlock()

        guard shouldNotify else { return }
        onError?(RecBarError.captureFailed(error.localizedDescription))
        onStopped?()
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureEngine: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            onSystemAudio?(sampleBuffer)
            return
        }
        guard type == .screen else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let rawStatus = attachments?.first?[.status] as? Int
        let status = rawStatus.flatMap(SCFrameStatus.init(rawValue:))

        // A missing status attachment means the buffer is a normal frame on some OS versions.
        if status == nil || status == .complete {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                // A frame with no pixels would only poison the encoder.
                return
            }
            lastCompletePixelBuffer = imageBuffer
            lastCompleteFormatDescription = formatDescription

            if !loggedFirstCompleteFrame {
                loggedFirstCompleteFrame = true
                let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
                let b0 = Int32((subtype >> 24) & 0xFF)
                let b1 = Int32((subtype >> 16) & 0xFF)
                let b2 = Int32((subtype >> 8) & 0xFF)
                let b3 = Int32(subtype & 0xFF)
                NSLog(
                    "RecBar screen: first complete frame %dx%d fmt=%c%c%c%c status=%d",
                    dimensions.width,
                    dimensions.height,
                    b0,
                    b1,
                    b2,
                    b3,
                    Int32(rawStatus ?? -1)
                )
            }

            onVideo?(sampleBuffer)
            return
        }

        guard status == .idle else {
            // `.blank`, `.started`, `.suspended`, `.stopped`, unknown: no new pixels.
            return
        }

        // Idle: the screen is static. Re-emit the last complete frame at the idle buffer's
        // timing so the video track has no gap and the encoder keeps receiving valid pixels.
        guard let pixelBuffer = lastCompletePixelBuffer,
              let formatDescription = lastCompleteFormatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )
        let idleDuration = CMSampleBufferGetDuration(sampleBuffer)
        if idleDuration.isValid, idleDuration > .zero {
            timing.duration = idleDuration
        }

        var repeatedBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &repeatedBuffer
        )
        guard createStatus == noErr, let repeatedBuffer else { return }

        onVideo?(repeatedBuffer)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureEngine: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(stream, error: error)
    }
}
