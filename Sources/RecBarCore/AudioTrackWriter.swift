import Foundation
import AVFoundation
import CoreMedia

/// Writes one audio source ("system" or a single microphone) as a crash-safe
/// chain of short M4A segments.
///
/// One `AVAssetWriter` per segment, created lazily on the first sample of that
/// segment. Segments are written to
/// `<folderURL>/<trackID>-<NNNNN>.partial.m4a`, fsynced, atomically renamed and
/// reported through `onSegmentFinalized`. Rotation is driven by the controller
/// (there is no internal timer); `finish()` drains every pending
/// `finishWriting` before returning the finalized segment list.
public final class AudioTrackWriter: @unchecked Sendable {

    public struct Config {
        /// Stable id such as "system" or "mic-abc123".
        public var trackID: String
        /// Human-readable name such as "System Audio" or "Blue Yeti".
        public var displayName: String
        public var kind: AudioTrackKind
        /// `<session>/audio` — created if needed.
        public var folderURL: URL
        public var segmentSeconds: Double
        public var sampleRate: Double
        public var channels: Int
        public var bitrate: Int
        /// Logical timeline offset (seconds) for the first segment.
        public var initialStartOffset: Double

        public init(trackID: String, displayName: String, kind: AudioTrackKind, folderURL: URL,
                    segmentSeconds: Double, sampleRate: Double, channels: Int, bitrate: Int,
                    initialStartOffset: Double = 0) {
            self.trackID = trackID
            self.displayName = displayName
            self.kind = kind
            self.folderURL = folderURL
            self.segmentSeconds = max(1, segmentSeconds)
            self.sampleRate = max(1, sampleRate)
            self.channels = max(1, channels)
            self.bitrate = max(1, bitrate)
            self.initialStartOffset = max(0, initialStartOffset)
        }
    }

    public var onSegmentFinalized: ((AudioSegmentInfo) -> Void)?
    public var onError: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let config: Config
    private let sanitizedTrackID: String

    private var started = false
    private var done = false       // finish() or cancel() was called
    private var cancelled = false
    private var nextIndex = 1
    private var current: Record?
    private var finalized: [AudioSegmentInfo] = []
    private var errors: [Error] = []
    private var outstandingFinishes = 0
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingStartOffset: Double

    // MARK: - Lifecycle

    public init(config: Config) {
        self.config = config
        self.sanitizedTrackID = AudioTrackWriter.sanitize(config.trackID)
        self.pendingStartOffset = max(0, config.initialStartOffset)
        self.queue = DispatchQueue(label: "app.recbar.audio.\(AudioTrackWriter.sanitize(config.trackID))")
        do {
            try FSUtility.ensureDirectory(config.folderURL)
        } catch {
            NSLog("RecBar AudioTrackWriter[%@]: could not create audio folder %@: %@",
                  config.trackID, config.folderURL.path, String(describing: error))
        }
    }

    /// Marks the writer started and resets all per-recording state. Segments are
    /// still opened lazily on the first appended sample.
    public func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.done = false
            self.cancelled = false
            self.nextIndex = 1
            self.current = nil
            self.finalized = []
            self.errors = []
            self.outstandingFinishes = 0
            self.pendingStartOffset = max(0, self.config.initialStartOffset)
        }
    }

    // MARK: - Appending

    public func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.started, !self.done, !self.cancelled else { return }
            self.appendLocked(sampleBuffer)
        }
    }

    // MARK: - Rotation / teardown

    /// Finalizes the current segment and makes the next one start at `startOffset`
    /// on the session's logical timeline (pauses are excluded from that timeline).
    public func rotate(at startOffset: Double) {
        queue.async { [weak self] in
            guard let self = self, !self.done, !self.cancelled else { return }
            self.pendingStartOffset = max(0, startOffset)
            guard let record = self.current else { return }
            self.current = nil
            self.closeRecordLocked(record)
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self = self, !self.done else { return }
            self.done = true
            self.cancelled = true
            self.started = false
            if let record = self.current {
                self.current = nil
                self.abandonRecordLocked(record)
            }
        }
    }

    /// Stops accepting samples, finalizes the current segment, waits for every
    /// pending `finishWriting`, then returns the finalized segments sorted by
    /// index. Throws only when nothing could be finalized and an error occurred.
    /// Safe to call more than once.
    public func finish() async throws -> [AudioSegmentInfo] {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self = self else { waiter.resume(returning: ()); return }
                self.finishLocked(waiter)
            }
        }
        return finalizedSegments
    }

    // MARK: - Getters

    /// Size of the in-progress partial file, or 0 when no segment is open.
    public var currentPartialBytes: Int64 {
        queue.sync {
            guard let record = current, !record.closed, record.writer != nil else { return 0 }
            return FSUtility.fileSize(at: record.partialURL)
        }
    }

    public var finalizedSegments: [AudioSegmentInfo] {
        queue.sync {
            finalized.sorted { $0.index < $1.index }
        }
    }

    public var totalFinalizedBytes: Int64 {
        queue.sync {
            finalized.reduce(0) { $0 + $1.bytes }
        }
    }

    // MARK: - Internals (all running on `queue`)

    /// Per-segment bookkeeping. Only ever touched on `queue`.
    private final class Record {
        let index: Int
        let finalFileName: String
        let finalURL: URL
        let partialURL: URL
        /// Logical offset on the session timeline, captured when the segment opens.
        let startOffset: Double
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var sessionStart: CMTime?
        var firstPTS: CMTime?
        var lastPTS: CMTime?
        var lastSampleDuration: Double
        var awaitingFinish = false   // finishWriting scheduled, completion not yet consumed
        var closed = false           // completion path already ran for this record

        init(index: Int, finalFileName: String, finalURL: URL, partialURL: URL,
             startOffset: Double, fallbackSampleDuration: Double) {
            self.index = index
            self.finalFileName = finalFileName
            self.finalURL = finalURL
            self.partialURL = partialURL
            self.startOffset = startOffset
            self.lastSampleDuration = fallbackSampleDuration
        }

        var writeErrorDescription: String {
            if let error = writer?.error {
                return "\(error)"
            }
            return "finishWriting did not complete (status \(writer?.status.rawValue ?? -1))"
        }

        var writeError: Error {
            RecBarError.writerFailed(writeErrorDescription)
        }
    }

    private var fallbackSampleDuration: Double {
        1024.0 / max(1, config.sampleRate)
    }

    private func appendLocked(_ sampleBuffer: CMSampleBuffer) {
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid, pts.isNumeric else { return }

        if current == nil {
            guard let record = makeRecordLocked(firstPTS: pts) else { return }
            current = record
        }
        guard let record = current, !record.closed else { return }
        guard record.writer?.status == .writing else { return }
        // A sample older than the session start would break the segment timeline.
        if let start = record.sessionStart, CMTimeCompare(pts, start) < 0 { return }
        guard let input = record.input, input.isReadyForMoreMediaData else { return }

        if input.append(sampleBuffer) {
            if record.firstPTS == nil { record.firstPTS = pts }
            record.lastPTS = pts
            let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
            if sampleDuration.isValid, sampleDuration.isNumeric, sampleDuration > .zero {
                record.lastSampleDuration = sampleDuration.seconds
            }
        } else {
            reportLocked(record.writeError)
        }
    }

    private func finishLocked(_ waiter: CheckedContinuation<Void, Error>) {
        guard !done else {
            // finish() called twice, or once after cancel(): wait for whatever
            // is still in flight and return the same snapshot again.
            finishWaiters.append(waiter)
            checkFinishWaitersLocked()
            return
        }
        done = true
        started = false
        if !cancelled, let record = current {
            current = nil
            closeRecordLocked(record)
        }
        finishWaiters.append(waiter)
        checkFinishWaitersLocked()
    }

    // MARK: Segment creation

    private func makeRecordLocked(firstPTS: CMTime) -> Record? {
        let index = nextIndex
        let baseName = "\(sanitizedTrackID)-\(String(format: "%05d", index))"
        let finalName = "\(baseName).m4a"
        let finalURL = config.folderURL.appendingPathComponent(finalName)
        let partialURL = config.folderURL.appendingPathComponent("\(baseName).partial.m4a")

        // A stale partial from a previous failed attempt must not block the writer.
        FSUtility.removeIfExists(partialURL)

        guard let writer = try? AVAssetWriter(url: partialURL, fileType: .m4a) else {
            reportLocked(RecBarError.writerFailed("could not create AVAssetWriter for \(partialURL.path)"))
            return nil
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: config.sampleRate,
            AVNumberOfChannelsKey: config.channels,
            AVEncoderBitRateKey: config.bitrate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            reportLocked(RecBarError.writerFailed("audio input not accepted for \(finalName)"))
            FSUtility.removeIfExists(partialURL)
            return nil
        }
        writer.add(input)

        guard writer.startWriting(), writer.status == .writing else {
            let message = writer.error.map { "\($0)" } ?? "startWriting failed (status \(writer.status.rawValue))"
            reportLocked(RecBarError.writerFailed(message))
            FSUtility.removeIfExists(partialURL)
            return nil
        }
        writer.startSession(atSourceTime: firstPTS)

        let record = Record(
            index: index,
            finalFileName: finalName,
            finalURL: finalURL,
            partialURL: partialURL,
            startOffset: pendingStartOffset,
            fallbackSampleDuration: fallbackSampleDuration
        )
        record.writer = writer
        record.input = input
        record.sessionStart = firstPTS
        nextIndex += 1
        return record
    }

    // MARK: Segment finalization

    private func closeRecordLocked(_ record: Record) {
        guard !record.closed else { return }
        guard let writer = record.writer else {
            record.closed = true
            return
        }
        switch writer.status {
        case .writing:
            record.input?.markAsFinished()
            record.awaitingFinish = true
            outstandingFinishes += 1
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.queue.async { self.completeRecord(record) }
            }
        case .failed, .unknown:
            record.closed = true
            FSUtility.removeIfExists(record.partialURL)
            reportLocked(RecBarError.writerFailed(record.writeErrorDescription))
        case .cancelled, .completed:
            // Either cancel() already tore this down or writing completed out of
            // band; run the normal completion path so bookkeeping stays exact.
            completeRecord(record)
        @unknown default:
            record.closed = true
            FSUtility.removeIfExists(record.partialURL)
            reportLocked(RecBarError.writerFailed("unknown writer status \(writer.status.rawValue)"))
        }
    }

    /// Called from the finishWriting completion (hopped back onto `queue`).
    private func completeRecord(_ record: Record) {
        guard !record.closed else { return }
        let wasAwaiting = record.awaitingFinish
        record.awaitingFinish = false
        record.closed = true
        defer {
            if wasAwaiting { outstandingFinishes -= 1 }
            checkFinishWaitersLocked()
        }

        if cancelled {
            // cancel() aborted the session: never publish anything from here.
            FSUtility.removeIfExists(record.partialURL)
            return
        }

        guard let writer = record.writer, writer.status == .completed else {
            FSUtility.removeIfExists(record.partialURL)
            reportLocked(RecBarError.writerFailed(record.writeErrorDescription))
            return
        }

        // A segment with no appended samples is not useful; drop it silently.
        guard let first = record.firstPTS else {
            FSUtility.removeIfExists(record.partialURL)
            return
        }
        let last = record.lastPTS ?? first

        do {
            try FSUtility.fsyncFile(at: record.partialURL)
            guard rename(record.partialURL.path, record.finalURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try FSUtility.fsyncDirectory(at: config.folderURL)
        } catch {
            FSUtility.removeIfExists(record.partialURL)
            FSUtility.removeIfExists(record.finalURL)
            reportLocked(error)
            return
        }

        let spanSeconds = max(0, (last - first).seconds)
        let duration = max(0, spanSeconds + record.lastSampleDuration)
        let info = AudioSegmentInfo(
            index: record.index,
            fileName: record.finalFileName,
            startOffset: record.startOffset,
            duration: duration,
            bytes: FSUtility.fileSize(at: record.finalURL),
            createdAt: Date()
        )
        finalized.append(info)
        onSegmentFinalized?(info)
    }

    /// cancel()-only teardown of the open segment.
    private func abandonRecordLocked(_ record: Record) {
        guard !record.closed else { return }
        if record.awaitingFinish {
            // finishWriting is already scheduled; its completion handler will
            // see `cancelled` and delete the partial file.
            return
        }
        record.awaitingFinish = false
        record.closed = true
        if let writer = record.writer, writer.status == .writing {
            writer.cancelWriting()
        }
        FSUtility.removeIfExists(record.partialURL)
    }

    // MARK: finish() continuation bookkeeping

    private func checkFinishWaitersLocked() {
        guard outstandingFinishes == 0, !finishWaiters.isEmpty else { return }
        let waiters = finishWaiters
        finishWaiters = []
        let segments = finalized.sorted { $0.index < $1.index }
        let failure = errors.first
        for waiter in waiters {
            if segments.isEmpty, let failure = failure {
                waiter.resume(throwing: failure)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    private func reportLocked(_ error: Error?) {
        guard let error = error else { return }
        errors.append(error)
        NSLog("RecBar AudioTrackWriter[%@]: %@", config.trackID, String(describing: error))
        onError?(error)
    }

    // MARK: - Naming

    /// Lowercase letters, digits and hyphens only; collapses separators and
    /// falls back to "audio" when nothing usable remains.
    private static func sanitize(_ raw: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                result.append(Character(scalar))
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "audio" : trimmed
    }
}
