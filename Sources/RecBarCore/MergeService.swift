import AVFoundation
import Foundation

/// One audio source to merge: its crash-safe segments and the standalone
/// backup file that should be produced for it.
public struct MergeAudioTrack: Sendable {
    public var id: String
    public var name: String
    public var kind: AudioTrackKind
    public var segments: [URL]
    /// Relative to the session folder, e.g. "audio/system.m4a".
    public var outputFileName: String

    public init(id: String, name: String, kind: AudioTrackKind, segments: [URL], outputFileName: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.segments = segments
        self.outputFileName = outputFileName
    }
}

/// Result of joining a session's screen and camera segment tracks.
public struct MergeOutcome: Sendable {
    public var screenURL: URL?
    public var cameraURL: URL?
    /// Audio track ID -> standalone backup file.
    public var audioURLs: [String: URL]
    public var duration: Double
    public var screenSegments: Int
    public var cameraSegments: Int

    public init(screenURL: URL?, cameraURL: URL?, audioURLs: [String: URL] = [:], duration: Double,
                screenSegments: Int, cameraSegments: Int) {
        self.screenURL = screenURL
        self.cameraURL = cameraURL
        self.audioURLs = audioURLs
        self.duration = duration
        self.screenSegments = screenSegments
        self.cameraSegments = cameraSegments
    }
}

/// Joins the per-segment files produced by the segment writers into the final
/// session files:
///
///   * `recording.mp4` — screen video plus one audio track per source
///     (system audio and every microphone).
///   * `camera.mp4` — camera video plus microphone tracks only.
///   * `audio/<track>.m4a` — one standalone backup file per source.
///
/// Every step is a lossless passthrough export (no re-encode). If AVFoundation
/// refuses a composition, the service falls back to `ffmpeg -c copy`.
public final class MergeService {
    public init() {}

    public func merge(
        screenSegments: [URL],
        cameraSegments: [URL],
        audioTracks: [MergeAudioTrack] = [],
        folderURL: URL,
        screenFileName: String = "recording.mp4",
        cameraFileName: String = "camera.mp4",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MergeOutcome {
        try FSUtility.ensureDirectory(folderURL)

        let usableAudioTracks = audioTracks.filter { !$0.segments.isEmpty }

        // 1. Standalone per-source audio backups.
        var audioURLs: [String: URL] = [:]
        for (index, track) in usableAudioTracks.enumerated() {
            let range = subRange(0.0...0.25, index: index, count: usableAudioTracks.count)
            let url = try await mergeAudioTrack(
                track,
                folderURL: folderURL,
                progressRange: range,
                progress: progress
            )
            audioURLs[track.id] = url
        }

        let hasCamera = !cameraSegments.isEmpty
        let screenRange: ClosedRange<Double> = hasCamera ? 0.25...0.72 : 0.25...1.0
        let cameraRange: ClosedRange<Double> = 0.72...1.0

        // Screen video carries system audio and every microphone. Camera video
        // carries microphones only, never system audio.
        let screenAudio = usableAudioTracks.compactMap { audioURLs[$0.id] }
        let cameraAudio = usableAudioTracks
            .filter { $0.kind == .microphone }
            .compactMap { audioURLs[$0.id] }

        var screenOutput: URL?
        var cameraOutput: URL?

        if !screenSegments.isEmpty {
            screenOutput = try await mergeVideoTrack(
                segments: screenSegments,
                overlayAudio: screenAudio,
                includeEmbeddedAudio: usableAudioTracks.isEmpty,
                destination: folderURL.appendingPathComponent(screenFileName),
                progressRange: screenRange,
                progress: progress
            )
        }

        if !cameraSegments.isEmpty {
            cameraOutput = try await mergeVideoTrack(
                segments: cameraSegments,
                overlayAudio: cameraAudio,
                includeEmbeddedAudio: usableAudioTracks.isEmpty,
                destination: folderURL.appendingPathComponent(cameraFileName),
                progressRange: cameraRange,
                progress: progress
            )
        }

        // Make the merged files durable before the caller deletes the source segments.
        // Without this a power loss right after "Saved" could leave a truncated output
        // while the only other copy has already been unlinked.
        for output in [screenOutput, cameraOutput].compactMap({ $0 }) + Array(audioURLs.values) {
            try? FSUtility.fsyncFile(at: output)
        }
        try? FSUtility.fsyncDirectory(at: folderURL)

        progress?(1.0)

        let duration: Double
        if let screenOutput {
            duration = mediaDuration(of: screenOutput)
        } else if let cameraOutput {
            duration = mediaDuration(of: cameraOutput)
        } else {
            duration = 0
        }

        return MergeOutcome(
            screenURL: screenOutput,
            cameraURL: cameraOutput,
            audioURLs: audioURLs,
            duration: duration,
            screenSegments: screenSegments.count,
            cameraSegments: cameraSegments.count
        )
    }

    // MARK: - Audio-only merging

    private func mergeAudioTrack(
        _ track: MergeAudioTrack,
        folderURL: URL,
        progressRange: ClosedRange<Double>,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let existing = track.segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            throw RecBarError.mergeFailed("No audio segments were found for \(track.name).")
        }

        let destination = folderURL.appendingPathComponent(track.outputFileName)
        try FSUtility.ensureDirectory(destination.deletingLastPathComponent())

        // A single segment is already a valid M4A; copy it without touching the bytes.
        if existing.count == 1 {
            FSUtility.removeIfExists(destination)
            do {
                try FileManager.default.copyItem(at: existing[0], to: destination)
            } catch {
                throw RecBarError.mergeFailed("Could not copy audio segment \(existing[0].lastPathComponent): \(error.localizedDescription)")
            }
            try verifyOutput(destination)
            progress?(progressRange.upperBound)
            return destination
        }

        var avFoundationFailure = "unknown error"
        do {
            let output = try await exportAudioWithAVFoundation(
                segments: existing,
                destination: destination,
                progressRange: progressRange,
                progress: progress
            )
            try verifyOutput(output)
            return output
        } catch RecBarError.cancelled {
            throw RecBarError.cancelled
        } catch {
            avFoundationFailure = describe(error)
        }

        guard let ffmpeg = locateFFmpeg() else {
            throw RecBarError.mergeFailed("AVFoundation audio merge failed: \(avFoundationFailure). ffmpeg was not found for the fallback export.")
        }

        do {
            let output = try await exportAudioWithFFmpeg(ffmpeg: ffmpeg, segments: existing, destination: destination)
            try verifyOutput(output)
            progress?(progressRange.upperBound)
            return output
        } catch {
            throw RecBarError.mergeFailed("AVFoundation audio merge failed: \(avFoundationFailure). ffmpeg fallback failed: \(describe(error))")
        }
    }

    private func exportAudioWithAVFoundation(
        segments: [URL],
        destination: URL,
        progressRange: ClosedRange<Double>,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecBarError.mergeFailed("Could not create an audio track in the composition.")
        }

        var cursor = CMTime.zero
        var inserted = false
        for segmentURL in segments {
            let asset = AVURLAsset(url: segmentURL)
            guard let sourceAudio = asset.tracks(withMediaType: .audio).first else { continue }
            let range = sourceAudio.timeRange
            guard range.duration.isValid, CMTimeGetSeconds(range.duration) > 0 else { continue }
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: range.start, duration: range.duration),
                of: sourceAudio,
                at: cursor
            )
            cursor = CMTimeAdd(cursor, range.duration)
            inserted = true
        }

        guard inserted else {
            throw RecBarError.mergeFailed("The audio segments contain no readable audio tracks.")
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecBarError.mergeFailed("AVFoundation could not create a passthrough export session.")
        }

        // Passthrough refuses .m4a even for AAC, but an audio-only MP4 is the same
        // container; export to a temporary .mp4 and rename it to the .m4a name.
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial.mp4")
        FSUtility.removeIfExists(temporary)

        guard session.supportedFileTypes.contains(.mp4) else {
            throw RecBarError.mergeFailed("The passthrough exporter does not support MP4 audio output.")
        }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false

        do {
            try await runExport(session, progressRange: progressRange, progress: progress)
            FSUtility.removeIfExists(destination)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            FSUtility.removeIfExists(temporary)
            throw error
        }

        return destination
    }

    private func exportAudioWithFFmpeg(ffmpeg: FFmpeg, segments: [URL], destination: URL) async throws -> URL {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial.mp4")
        let listURL = try writeConcatList(for: segments, in: destination.deletingLastPathComponent())
        defer { FSUtility.removeIfExists(listURL) }
        defer { FSUtility.removeIfExists(temporary) }

        FSUtility.removeIfExists(temporary)
        var arguments = ffmpeg.leadingArguments
        arguments += [
            "-hide_banner", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", listURL.path,
            "-map", "0:a:0",
            "-c", "copy",
            "-movflags", "+faststart",
            temporary.path
        ]

        let result = try await runProcess(executable: ffmpeg.executable, arguments: arguments)
        guard result.status == 0 else {
            throw RecBarError.mergeFailed(ffmpegFailure(result))
        }

        FSUtility.removeIfExists(destination)
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    // MARK: - Video merging

    private func mergeVideoTrack(
        segments: [URL],
        overlayAudio: [URL],
        includeEmbeddedAudio: Bool,
        destination: URL,
        progressRange: ClosedRange<Double>,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let existing = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            throw RecBarError.mergeFailed("None of the \(segments.count) segment file(s) could be found on disk.")
        }

        // With no audio overlay a single segment is already exactly the file we
        // want: copy it, never re-encode. This also preserves audio embedded by
        // older RecBar versions.
        if existing.count == 1, overlayAudio.isEmpty {
            let source = existing[0]
            if source.standardizedFileURL != destination.standardizedFileURL {
                FSUtility.removeIfExists(destination)
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch {
                    throw RecBarError.mergeFailed("Could not copy segment \(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            try verifyOutput(destination)
            progress?(progressRange.upperBound)
            return destination
        }

        FSUtility.removeIfExists(destination)

        var avFoundationFailure = "unknown error"
        do {
            let output = try await exportVideoWithAVFoundation(
                segments: existing,
                overlayAudio: overlayAudio,
                includeEmbeddedAudio: includeEmbeddedAudio,
                destination: destination,
                progressRange: progressRange,
                progress: progress
            )
            try verifyOutput(output)
            return output
        } catch RecBarError.cancelled {
            throw RecBarError.cancelled
        } catch {
            avFoundationFailure = describe(error)
        }

        guard let ffmpeg = locateFFmpeg() else {
            throw RecBarError.mergeFailed("AVFoundation export failed: \(avFoundationFailure). ffmpeg was not found for the fallback export.")
        }

        do {
            let output = try await exportVideoWithFFmpeg(
                ffmpeg: ffmpeg,
                segments: existing,
                overlayAudio: overlayAudio,
                destination: destination
            )
            try verifyOutput(output)
            progress?(progressRange.upperBound)
            return output
        } catch {
            throw RecBarError.mergeFailed("AVFoundation export failed: \(avFoundationFailure). ffmpeg fallback failed: \(describe(error))")
        }
    }

    private func exportVideoWithAVFoundation(
        segments: [URL],
        overlayAudio: [URL],
        includeEmbeddedAudio: Bool,
        destination: URL,
        progressRange: ClosedRange<Double>,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var compositionVideoTrack: AVMutableCompositionTrack?
        var embeddedAudioTrack: AVMutableCompositionTrack?
        var insertedVideo = false

        for segmentURL in segments {
            let asset = AVURLAsset(url: segmentURL)
            let segmentStart = cursor

            if let sourceVideo = asset.tracks(withMediaType: .video).first {
                let track: AVMutableCompositionTrack
                if let existingTrack = compositionVideoTrack {
                    track = existingTrack
                } else {
                    guard let created = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw RecBarError.mergeFailed("Could not create a video track in the composition.")
                    }
                    compositionVideoTrack = created
                    track = created
                }
                let range = sourceVideo.timeRange
                guard range.duration.isValid, CMTimeGetSeconds(range.duration) > 0 else { continue }
                try track.insertTimeRange(
                    CMTimeRange(start: range.start, duration: range.duration),
                    of: sourceVideo,
                    at: cursor
                )
                cursor = CMTimeAdd(cursor, range.duration)
                insertedVideo = true
            }

            // Older sessions muxed audio into the segment files. Keep that path
            // working when the manifest has no separate audio tracks.
            if includeEmbeddedAudio, let sourceAudio = asset.tracks(withMediaType: .audio).first {
                let track: AVMutableCompositionTrack
                if let existingTrack = embeddedAudioTrack {
                    track = existingTrack
                } else {
                    guard let created = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw RecBarError.mergeFailed("Could not create an audio track in the composition.")
                    }
                    embeddedAudioTrack = created
                    track = created
                }
                let range = sourceAudio.timeRange
                if range.duration.isValid, CMTimeGetSeconds(range.duration) > 0 {
                    try track.insertTimeRange(
                        CMTimeRange(start: range.start, duration: range.duration),
                        of: sourceAudio,
                        at: segmentStart
                    )
                }
            }
        }

        guard insertedVideo else {
            throw RecBarError.mergeFailed("The segments contain no readable video tracks.")
        }

        let videoDuration = cursor

        // Every overlay source becomes its own audio track in the output.
        for audioURL in overlayAudio {
            let asset = AVURLAsset(url: audioURL)
            guard let sourceAudio = asset.tracks(withMediaType: .audio).first else { continue }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RecBarError.mergeFailed("Could not add an audio track for \(audioURL.lastPathComponent).")
            }
            let available = sourceAudio.timeRange
            let duration = CMTimeMinimum(available.duration, videoDuration)
            guard duration.isValid, CMTimeGetSeconds(duration) > 0 else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: available.start, duration: duration),
                of: sourceAudio,
                at: .zero
            )
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecBarError.mergeFailed("AVFoundation could not create a passthrough export session.")
        }

        var outputURL = destination
        var fileType = AVFileType.mp4
        let supported = session.supportedFileTypes
        if !supported.contains(.mp4) {
            guard supported.contains(.mov) else {
                throw RecBarError.mergeFailed("The passthrough exporter supports neither MP4 nor MOV output.")
            }
            fileType = .mov
            outputURL = destination.deletingPathExtension().appendingPathExtension("mov")
        }

        FSUtility.removeIfExists(outputURL)
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false

        do {
            try await runExport(session, progressRange: progressRange, progress: progress)
        } catch {
            FSUtility.removeIfExists(outputURL)
            throw error
        }

        return outputURL
    }

    private func exportVideoWithFFmpeg(
        ffmpeg: FFmpeg,
        segments: [URL],
        overlayAudio: [URL],
        destination: URL
    ) async throws -> URL {
        let listURL = try writeConcatList(for: segments, in: destination.deletingLastPathComponent())
        defer { FSUtility.removeIfExists(listURL) }

        if overlayAudio.isEmpty {
            // Legacy path: segments already carry their audio.
            FSUtility.removeIfExists(destination)
            var arguments = ffmpeg.leadingArguments
            arguments += [
                "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                "-movflags", "+faststart",
                destination.path
            ]
            let result = try await runProcess(executable: ffmpeg.executable, arguments: arguments)
            guard result.status == 0 else {
                throw RecBarError.mergeFailed(ffmpegFailure(result))
            }
            return destination
        }

        // New path: join the video-only segments, then mux every audio source as
        // its own track without re-encoding.
        let joined = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).video.mp4")
        defer { FSUtility.removeIfExists(joined) }

        var joinArguments = ffmpeg.leadingArguments
        joinArguments += [
            "-hide_banner", "-loglevel", "error",
            "-f", "concat", "-safe", "0",
            "-i", listURL.path,
            "-map", "0:v:0",
            "-c", "copy",
            joined.path
        ]
        let joinResult = try await runProcess(executable: ffmpeg.executable, arguments: joinArguments)
        guard joinResult.status == 0 else {
            throw RecBarError.mergeFailed(ffmpegFailure(joinResult))
        }

        FSUtility.removeIfExists(destination)
        var arguments = ffmpeg.leadingArguments
        arguments += ["-hide_banner", "-loglevel", "error", "-i", joined.path]
        for audioURL in overlayAudio {
            arguments += ["-i", audioURL.path]
        }
        arguments += ["-map", "0:v:0"]
        for index in overlayAudio.indices {
            arguments += ["-map", "\(index + 1):a:0"]
        }
        arguments += ["-c", "copy", "-movflags", "+faststart", destination.path]

        let result = try await runProcess(executable: ffmpeg.executable, arguments: arguments)
        guard result.status == 0 else {
            throw RecBarError.mergeFailed(ffmpegFailure(result))
        }
        return destination
    }

    // MARK: - AVFoundation passthrough export

    private func runExport(
        _ session: AVAssetExportSession,
        progressRange: ClosedRange<Double>,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let box = ExportSessionBox(session)
        let lower = progressRange.lowerBound
        let span = progressRange.upperBound - progressRange.lowerBound

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.recbar.merge.progress"))
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler {
                let fraction = MergeService.clamp(Double(box.session.progress))
                progress?(lower + span * fraction)
            }
            timer.resume()

            box.session.exportAsynchronously {
                timer.cancel()
                switch box.session.status {
                case .completed:
                    progress?(progressRange.upperBound)
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: RecBarError.cancelled)
                default:
                    let message = box.session.error?.localizedDescription
                        ?? "The passthrough export did not complete (status \(box.session.status.rawValue))."
                    continuation.resume(throwing: RecBarError.mergeFailed(message))
                }
            }
        }
    }

    // MARK: - ffmpeg fallback

    private struct FFmpeg {
        var executable: String
        var leadingArguments: [String]
    }

    private func locateFFmpeg() -> FFmpeg? {
        let manager = FileManager.default
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where manager.isExecutableFile(atPath: candidate) {
            return FFmpeg(executable: candidate, leadingArguments: [])
        }
        if manager.isExecutableFile(atPath: "/usr/bin/env") {
            return FFmpeg(executable: "/usr/bin/env", leadingArguments: ["ffmpeg"])
        }
        return nil
    }

    private func writeConcatList(for segments: [URL], in directory: URL) throws -> URL {
        let listURL = directory.appendingPathComponent(".recbar-concat-\(UUID().uuidString).txt")
        let lines = segments.map { segmentURL -> String in
            let path = MergeService.absolutePath(for: segmentURL)
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }
        let contents = lines.joined(separator: "\n") + "\n"
        do {
            try contents.write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            throw RecBarError.mergeFailed("Could not write the ffmpeg concat list: \(error.localizedDescription)")
        }
        return listURL
    }

    private struct ProcessResult: Sendable {
        var status: Int32
        var stderr: String
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let errorPipe = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RecBarError.mergeFailed("Could not launch \(executable): \(error.localizedDescription)"))
                    return
                }

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, stderr: stderr))
            }
        }
    }

    // MARK: - Helpers

    private static func absolutePath(for url: URL) -> String {
        if url.path.hasPrefix("/") {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: url.path).standardizedFileURL.path
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private func subRange(_ range: ClosedRange<Double>, index: Int, count: Int) -> ClosedRange<Double> {
        guard count > 0 else { return range }
        let span = (range.upperBound - range.lowerBound) / Double(count)
        let lower = range.lowerBound + span * Double(index)
        return lower...(lower + span)
    }

    private func ffmpegFailure(_ result: ProcessResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "ffmpeg exited with status \(result.status)."
        }
        return "ffmpeg exited with status \(result.status): \(detail)"
    }

    private func verifyOutput(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecBarError.mergeFailed("The merged file \(url.lastPathComponent) was not created.")
        }
        guard FSUtility.fileSize(at: url) > 0 else {
            throw RecBarError.mergeFailed("The merged file \(url.lastPathComponent) is empty.")
        }
    }

    private func mediaDuration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private func describe(_ error: Error) -> String {
        if let recBarError = error as? RecBarError, let description = recBarError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// Lets the export completion handler and the progress timer share the session
/// across queues without tripping concurrency annotations.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
