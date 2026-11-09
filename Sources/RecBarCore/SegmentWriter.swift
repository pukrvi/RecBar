import Foundation
import AVFoundation
import CoreMedia

/// Writes one video track ("screen" or "camera") as a chain of MP4 segments.
///
/// One `AVAssetWriter` per segment, created lazily on the first sample of that
/// segment so timestarts stay dead-on. Segments are written to
/// `<folderURL>/<kind>-<NNNNN>.partial.mp4`, fsynced, atomically renamed and
/// reported through `onSegmentFinalized`. Rotation is driven by the controller
/// so every video and audio writer closes its segment at the same logical time;
/// `finish()` drains every pending `finishWriting` before returning the
/// finalized segment list.
public final class SegmentWriter: @unchecked Sendable {

    public struct Config {
        public var kind: TrackKind
        /// `<session>/segments` — created if needed.
        public var folderURL: URL
        public var segmentSeconds: Double
        public var spec: SegmentSpec

        public init(kind: TrackKind, folderURL: URL, segmentSeconds: Double, spec: SegmentSpec) {
            self.kind = kind
            self.folderURL = folderURL
            self.segmentSeconds = max(1, segmentSeconds)
            self.spec = spec
        }
    }

    public var onSegmentFinalized: ((SegmentInfo) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onStateChange: (() -> Void)?

    private let queue = DispatchQueue(label: "app.recbar.segment")
    private let config: Config

    private var started = false
    private var done = false       // finish() or cancel() was called
    private var cancelled = false
    private var nextIndex = 1
    private var current: Record?
    private var finalized: [SegmentInfo] = []
    private var accumulatedDuration = 0.0
    /// Logical timeline offset for the next segment, supplied by the controller
    /// so video and audio segment boundaries share one clock.
    private var pendingStartOffset: Double?
    private var errors: [Error] = []
    private var outstandingFinishes = 0
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []

    // MARK: - Lifecycle

    public init(config: Config) {
        self.config = config
        do {
            try FSUtility.ensureDirectory(config.folderURL)
        } catch {
            NSLog("RecBar SegmentWriter[%@]: could not create segment folder %@: %@", config.kind.rawValue, config.folderURL.path, String(describing: error))
        }
    }

    /// Starts accepting samples. Rotation is driven by the controller through
    /// `rotate(at:)`, which keeps every track on the same logical timeline.
    public func start(at startOffset: Double = 0) {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.pendingStartOffset = max(0, startOffset)
            self.onStateChange?()
        }
    }

    // MARK: - Appending

    public func append(video sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.started, !self.done, !self.cancelled else { return }
            self.appendVideoLocked(sampleBuffer)
        }
    }

    // MARK: - Rotation / teardown

    /// Finalizes the current segment now. The next appended sample lazily opens a
    /// new one at `startOffset` on the session's logical timeline.
    public func rotate(at startOffset: Double) {
        queue.async {
            self.pendingStartOffset = max(0, startOffset)
            self.rotateLocked()
        }
    }

    /// Finalizes the current segment, keeping the previously supplied offset.
    public func rotate() {
        queue.async {
            self.rotateLocked()
        }
    }

    public func cancel() {
        queue.async {
            guard !self.done else { return }
            self.done = true
            self.cancelled = true
            self.started = false
            if let record = self.current {
                self.current = nil
                self.abandonRecordLocked(record)
            }
            self.onStateChange?()
        }
    }

    /// Finalizes the current segment, waits for every pending `finishWriting`,
    /// then returns the finalized segments sorted by index. Throws only when
    /// nothing could be finalized and an error occurred.
    public func finish() async throws -> [SegmentInfo] {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self = self else { waiter.resume(returning: ()); return }
                self.finishLocked(waiter)
            }
        }
        return finalizedSegments
    }

    // MARK: Getters

    /// Size of the in-progress partial file, or 0 when no segment is open.
    public var currentPartialBytes: Int64 {
        queue.sync {
            guard let record = current, !record.closed, record.writer != nil else { return 0 }
            return FSUtility.fileSize(at: record.partialURL)
        }
    }

    public var finalizedSegments: [SegmentInfo] {
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
        var videoInput: AVAssetWriterInput?
        var sessionStart: CMTime?
        var firstVideoPTS: CMTime?
        var lastVideoPTS: CMTime?
        var awaitingFinish = false   // finishWriting scheduled, completion not yet consumed
        var closed = false           // completion path already ran for this record

        init(index: Int, finalFileName: String, finalURL: URL, partialURL: URL, startOffset: Double) {
            self.index = index
            self.finalFileName = finalFileName
            self.finalURL = finalURL
            self.partialURL = partialURL
            self.startOffset = startOffset
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

    private var frameDurationSeconds: Double {
        1.0 / Double(max(1, config.spec.frameRate))
    }

    private func appendVideoLocked(_ sampleBuffer: CMSampleBuffer) {
        guard let record = currentRecordLocked(forSampleBuffer: sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        // Never append a sample older than the session start; it would break the MP4 timeline.
        if let start = record.sessionStart, CMTimeCompare(pts, start) < 0 { return }
        guard let input = record.videoInput, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            if record.firstVideoPTS == nil { record.firstVideoPTS = pts }
            record.lastVideoPTS = pts
        } else {
            reportLocked(record.writeError)
        }
    }

    private func currentRecordLocked(forSampleBuffer sampleBuffer: CMSampleBuffer) -> Record? {
        if current == nil {
            guard let record = makeRecordLocked(firstPTS: sampleBuffer.presentationTimeStamp) else { return nil }
            current = record
        }
        guard let record = current, !record.closed else { return nil }
        guard record.writer?.status == .writing else { return nil }
        return record
    }

    private func rotateLocked() {
        guard started, !done, !cancelled else { return }
        guard let record = current else { return }
        current = nil
        closeRecordLocked(record)
        onStateChange?()
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
        let baseName = "\(config.kind.rawValue)-\(String(format: "%05d", index))"
        let finalName = "\(baseName).mp4"
        let finalURL = config.folderURL.appendingPathComponent(finalName)
        let partialURL = config.folderURL.appendingPathComponent("\(baseName).partial.mp4")

        // A stale partial from a previous failed attempt must not block the writer.
        FSUtility.removeIfExists(partialURL)

        guard let writer = try? AVAssetWriter(url: partialURL, fileType: .mp4) else {
            reportLocked(RecBarError.writerFailed("could not create AVAssetWriter for \(partialURL.path)"))
            return nil
        }

        let spec = config.spec
        let frameRate = max(1, spec.frameRate)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: spec.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: max(2, spec.width),
            AVVideoHeightKey: max(2, spec.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        // HEVC first; the H.264 fallback keeps low-end Macs recording.
        videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        // BT.709 color properties so screen colors do not wash out. These must be
        // nested under AVVideoColorPropertiesKey; AVAssetWriter rejects them at top level.
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            reportLocked(RecBarError.writerFailed("video input not accepted for \(finalName)"))
            return nil
        }
        writer.add(videoInput)

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
            startOffset: pendingStartOffset ?? accumulatedDuration
        )
        record.writer = writer
        record.videoInput = videoInput
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
            record.videoInput?.markAsFinished()
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

        // A segment with no video frames is not useful; drop it without emitting an entry.
        guard let first = record.firstVideoPTS else {
            FSUtility.removeIfExists(record.partialURL)
            return
        }
        let last = record.lastVideoPTS ?? first

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
        let duration = spanSeconds + frameDurationSeconds
        let info = SegmentInfo(
            kind: config.kind,
            index: record.index,
            fileName: record.finalFileName,
            startOffset: record.startOffset,
            duration: duration,
            bytes: FSUtility.fileSize(at: record.finalURL),
            createdAt: Date()
        )
        accumulatedDuration = max(accumulatedDuration, record.startOffset + duration)
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
        NSLog("RecBar SegmentWriter[%@]: %@", config.kind.rawValue, String(describing: error))
        onError?(error)
    }
}
