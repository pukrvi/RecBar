import AVFoundation
import Foundation

/// Finds recording sessions that were interrupted (an app crash or power loss leaves
/// a manifest stuck in `.recording` / `.finalizing`) and finishes them on demand.
public enum RecoveryService {
    private static let manifestFileName = "manifest.json"
    private static let segmentsDirectoryName = "segments"
    private static let audioSegmentsDirectoryName = "audio/segments"
    private static let partialSuffix = ".partial.mp4"
    private static let partialAudioSuffix = ".partial.m4a"

    // MARK: - Scanning

    public static func scan(folderURL: URL) -> [RecoverableSession] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folderURL.path) else { return [] }

        var sessions: [RecoverableSession] = []

        for entry in FSUtility.contents(of: folderURL) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let manifestURL = entry.appendingPathComponent(manifestFileName)
            guard manager.fileExists(atPath: manifestURL.path) else { continue }
            guard let manifest = try? ManifestStore.load(from: entry) else { continue }
            // `.failed` is included so a recording whose merge failed can still be
            // recovered later instead of stranding its segments forever.
            guard manifest.status == .recording
                || manifest.status == .finalizing
                || manifest.status == .failed else { continue }

            let segmentsURL = entry.appendingPathComponent(segmentsDirectoryName)
            let audioSegmentsURL = entry.appendingPathComponent(audioSegmentsDirectoryName)

            // A crash can land between a segment's atomic rename and the manifest
            // write that records it, so always union the manifest list with what is
            // actually on disk rather than trusting either source alone.
            let screenURLs = mergedSegmentURLs(
                from: manifest.screenSegments,
                kind: "screen",
                segmentsURL: segmentsURL
            )
            let cameraURLs = mergedSegmentURLs(
                from: manifest.cameraSegments,
                kind: "camera",
                segmentsURL: segmentsURL
            )
            let audioTracks = mergedAudioTracks(
                from: manifest.audioTracks,
                audioSegmentsURL: audioSegmentsURL
            )

            // An empty session (crash before the first segment) is not recoverable.
            guard !screenURLs.isEmpty || !cameraURLs.isEmpty || !audioTracks.isEmpty else { continue }

            var duration = 0.0
            for segment in manifest.screenSegments where manager.fileExists(atPath: segmentsURL.appendingPathComponent(segment.fileName).path) {
                duration += segment.duration
            }
            for segment in manifest.cameraSegments where manager.fileExists(atPath: segmentsURL.appendingPathComponent(segment.fileName).path) {
                duration += segment.duration
            }

            var bytes: Int64 = 0
            for url in screenURLs { bytes += FSUtility.fileSize(at: url) }
            for url in cameraURLs { bytes += FSUtility.fileSize(at: url) }
            for track in audioTracks {
                for segment in track.segments {
                    bytes += FSUtility.fileSize(at: audioSegmentsURL.appendingPathComponent(segment.fileName))
                }
            }

            sessions.append(
                RecoverableSession(
                    folderURL: entry,
                    manifest: manifest,
                    screenSegments: screenURLs,
                    cameraSegments: cameraURLs,
                    audioTracks: audioTracks,
                    duration: duration,
                    bytes: bytes
                )
            )
        }

        return sessions.sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    // MARK: - Recovery

    public static func recover(
        _ session: RecoverableSession,
        keepSegments: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RecordingResult {
        let folderURL = session.folderURL
        let segmentsURL = folderURL.appendingPathComponent(segmentsDirectoryName)
        let audioSegmentsURL = folderURL.appendingPathComponent(audioSegmentsDirectoryName)
        let manager = FileManager.default

        let existingScreen = session.screenSegments.filter { manager.fileExists(atPath: $0.path) }
        let existingCamera = session.cameraSegments.filter { manager.fileExists(atPath: $0.path) }
        let existingAudio = session.audioTracks.compactMap { track -> MergeAudioTrack? in
            let segments = track.segments
                .sorted { $0.index < $1.index }
                .map { audioSegmentsURL.appendingPathComponent($0.fileName) }
                .filter { manager.fileExists(atPath: $0.path) }
            guard !segments.isEmpty else { return nil }
            return MergeAudioTrack(
                id: track.id,
                name: track.name,
                kind: track.kind,
                segments: segments,
                outputFileName: "audio/\(track.id).m4a"
            )
        }

        guard !existingScreen.isEmpty || !existingCamera.isEmpty || !existingAudio.isEmpty else {
            throw RecBarError.invalidSession("No recording segments were found in \(folderURL.lastPathComponent).")
        }

        let partialFiles = partialSegmentURLs(in: segmentsURL)
        let partialAudioFiles = partialAudioSegmentURLs(in: audioSegmentsURL)

        let outcome: MergeOutcome
        do {
            outcome = try await MergeService().merge(
                screenSegments: existingScreen,
                cameraSegments: existingCamera,
                audioTracks: existingAudio,
                folderURL: folderURL,
                screenFileName: "recording.mp4",
                cameraFileName: "camera.mp4",
                progress: progress
            )
        } catch let error as RecBarError {
            throw error
        } catch {
            throw RecBarError.mergeFailed(error.localizedDescription)
        }

        let outputs = [outcome.screenURL, outcome.cameraURL].compactMap { $0 }
        guard !outputs.isEmpty else {
            throw RecBarError.mergeFailed("The recovery merge produced no output files.")
        }
        for output in outputs {
            guard manager.fileExists(atPath: output.path), FSUtility.fileSize(at: output) > 0 else {
                throw RecBarError.mergeFailed("The recovered file \(output.lastPathComponent) could not be verified on disk.")
            }
        }

        var manifest: SessionManifest
        do {
            manifest = try ManifestStore.load(from: folderURL)
        } catch {
            throw RecBarError.invalidSession("The session manifest could not be read: \(error.localizedDescription)")
        }

        manifest.status = .recovered
        manifest.endedAt = Date()
        if let screenURL = outcome.screenURL {
            manifest.outputs[TrackKind.screen.rawValue] = screenURL.lastPathComponent
        }
        if let cameraURL = outcome.cameraURL {
            manifest.outputs[TrackKind.camera.rawValue] = cameraURL.lastPathComponent
        }

        // The manifest may be missing the last segment(s) that were renamed into
        // place just before the crash. Record everything that actually merged so
        // the recovered session's duration and segment list are accurate.
        manifest.screenSegments = completeVideoSegments(
            urls: existingScreen,
            manifestSegments: manifest.screenSegments,
            kind: .screen
        )
        manifest.cameraSegments = completeVideoSegments(
            urls: existingCamera,
            manifestSegments: manifest.cameraSegments,
            kind: .camera
        )

        var updatedTracks: [AudioTrackInfo] = []
        for mergeTrack in existingAudio {
            guard let scannedTrack = session.audioTracks.first(where: { $0.id == mergeTrack.id }) else { continue }
            var updated = scannedTrack
            if let url = outcome.audioURLs[mergeTrack.id] {
                let relative = relativePath(of: url, in: folderURL)
                updated.outputFileName = relative
                manifest.audioOutputs[mergeTrack.id] = relative
            }
            updatedTracks.append(updated)
        }
        manifest.audioTracks = updatedTracks
        manifest.notes.append("Recovered after an interrupted recording.")
        if !partialFiles.isEmpty || !partialAudioFiles.isEmpty {
            manifest.notes.append("The final in-progress segment (up to one segment length) was not recoverable.")
        }
        try ManifestStore.write(manifest, to: folderURL)

        for partial in partialFiles + partialAudioFiles {
            FSUtility.removeIfExists(partial)
        }

        if !keepSegments {
            // Only drop the segment folders once the merged files are known to exist.
            let allOutputsPresent = outputs.allSatisfy {
                manager.fileExists(atPath: $0.path) && FSUtility.fileSize(at: $0) > 0
            }
            if allOutputsPresent {
                try? manager.removeItem(at: segmentsURL)
                try? manager.removeItem(at: audioSegmentsURL)
            }
        }

        let bytes = (outputs + Array(outcome.audioURLs.values)).reduce(Int64(0)) { total, url in
            total + FSUtility.fileSize(at: url)
        }

        return RecordingResult(
            sessionID: manifest.id,
            folderURL: folderURL,
            screenURL: outcome.screenURL,
            cameraURL: outcome.cameraURL,
            audioURLs: outcome.audioURLs.values.sorted { $0.lastPathComponent < $1.lastPathComponent },
            duration: outcome.duration,
            bytes: bytes
        )
    }

    // MARK: - Segment discovery

    /// Builds the authoritative segment list for a recovered session: every URL
    /// that was merged, with manifest metadata where available and measured
    /// duration/bytes for segments the manifest never recorded.
    private static func completeVideoSegments(
        urls: [URL],
        manifestSegments: [SegmentInfo],
        kind: TrackKind
    ) -> [SegmentInfo] {
        let byName = Dictionary(manifestSegments.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = urls.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }

        var result: [SegmentInfo] = []
        var runningOffset = 0.0
        for url in sorted {
            let name = url.lastPathComponent
            if let existing = byName[name] {
                result.append(existing)
                runningOffset = max(runningOffset, existing.startOffset + existing.duration)
                continue
            }

            let duration = videoDuration(of: url)
            let index = parseVideoIndex(name, kind: kind) ?? ((result.last?.index ?? 0) + 1)
            result.append(
                SegmentInfo(
                    kind: kind,
                    index: index,
                    fileName: name,
                    startOffset: runningOffset,
                    duration: duration,
                    bytes: FSUtility.fileSize(at: url)
                )
            )
            runningOffset += duration
        }
        return result.sorted { $0.index < $1.index }
    }

    private static func parseVideoIndex(_ name: String, kind: TrackKind) -> Int? {
        let prefix = "\(kind.rawValue)-"
        guard name.hasPrefix(prefix), name.hasSuffix(".mp4") else { return nil }
        let number = name.dropFirst(prefix.count).dropLast(4)
        return Int(number)
    }

    private static func videoDuration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Every existing segment from the manifest and from disk, de-duplicated by file
    /// name and sorted numerically (`screen-00002.mp4` before `screen-00010.mp4`).
    private static func mergedSegmentURLs(
        from segments: [SegmentInfo],
        kind: String,
        segmentsURL: URL
    ) -> [URL] {
        let manager = FileManager.default
        var byName: [String: URL] = [:]

        for segment in segments {
            let url = segmentsURL.appendingPathComponent(segment.fileName)
            guard manager.fileExists(atPath: url.path) else { continue }
            byName[url.lastPathComponent] = url
        }

        for url in scannedSegmentURLs(kind: kind, in: segmentsURL) {
            byName[url.lastPathComponent] = url
        }

        return byName.values.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    private static func scannedSegmentURLs(kind: String, in segmentsURL: URL) -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: segmentsURL.path) else { return [] }

        let prefix = "\(kind)-"
        let matches = FSUtility.contents(of: segmentsURL).filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".mp4") else { return false }
            guard !name.hasSuffix(partialSuffix) else { return false }
            return manager.fileExists(atPath: url.path)
        }

        return matches.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    /// Unions the manifest's audio tracks with the M4A files that actually exist,
    /// including tracks whose manifest entry never landed before the crash.
    private static func mergedAudioTracks(
        from tracks: [AudioTrackInfo],
        audioSegmentsURL: URL
    ) -> [AudioTrackInfo] {
        let manager = FileManager.default
        var byID: [String: AudioTrackInfo] = [:]
        for track in tracks {
            byID[track.id] = AudioTrackInfo(id: track.id, name: track.name, kind: track.kind)
        }

        let scanned = scannedAudioFiles(in: audioSegmentsURL)
        for url in scanned {
            guard let parsed = parseAudioFileName(url.lastPathComponent) else { continue }
            var track = byID[parsed.trackID] ?? AudioTrackInfo(
                id: parsed.trackID,
                name: parsed.trackID == "system" ? "System Audio" : "Microphone \(parsed.trackID)",
                kind: parsed.trackID == "system" ? .system : .microphone
            )
            if !track.segments.contains(where: { $0.fileName == url.lastPathComponent }) {
                track.segments.append(
                    AudioSegmentInfo(
                        index: parsed.index,
                        fileName: url.lastPathComponent,
                        startOffset: 0,
                        duration: 0,
                        bytes: FSUtility.fileSize(at: url)
                    )
                )
            }
            byID[track.id] = track
        }

        // Drop tracks that have neither manifest segments nor files on disk.
        return byID.values
            .filter { track in
                track.segments.contains { segment in
                    manager.fileExists(atPath: audioSegmentsURL.appendingPathComponent(segment.fileName).path)
                }
            }
            .map { track in
                var copy = track
                copy.segments.sort { $0.index < $1.index }
                return copy
            }
            .sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.id < rhs.id }
                return lhs.kind == .system
            }
    }

    private static func scannedAudioFiles(in audioSegmentsURL: URL) -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioSegmentsURL.path) else { return [] }
        return FSUtility.contents(of: audioSegmentsURL).filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".m4a"), !name.hasSuffix(partialAudioSuffix) else { return false }
            return manager.fileExists(atPath: url.path)
        }
    }

    /// Parses `<track-id>-<NNNNN>.m4a`. Track IDs may contain hyphens, so the
    /// numeric index is always the final hyphen-separated component.
    private static func parseAudioFileName(_ name: String) -> (trackID: String, index: Int)? {
        guard name.hasSuffix(".m4a") else { return nil }
        let base = String(name.dropLast(4))
        guard let separator = base.lastIndex(of: "-") else { return nil }
        let indexPart = String(base[base.index(after: separator)...])
        let trackPart = String(base[..<separator])
        guard !trackPart.isEmpty, let index = Int(indexPart) else { return nil }
        return (trackPart, index)
    }

    private static func partialSegmentURLs(in segmentsURL: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: segmentsURL.path) else { return [] }
        return FSUtility.contents(of: segmentsURL).filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(partialSuffix) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func partialAudioSegmentURLs(in audioSegmentsURL: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: audioSegmentsURL.path) else { return [] }
        return FSUtility.contents(of: audioSegmentsURL).filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(partialAudioSuffix) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func relativePath(of url: URL, in folder: URL) -> String {
        let prefix = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }
}
