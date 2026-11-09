import Foundation
import AVFoundation
import CoreMedia
import RecBarCore

/// Headless end-to-end check: synthetic video + two audio sources ->
/// video SegmentWriters + AudioTrackWriters -> multi-track lossless merge.
/// Run with: RecBar --selftest
public enum SelfTest {
    public static func run() async -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recbar-selftest-\(UUID().uuidString)", isDirectory: true)
        let segmentFolder = root.appendingPathComponent("segments", isDirectory: true)
        let audioSegmentFolder = root
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)
        do {
            try FSUtility.ensureDirectory(segmentFolder)
            try FSUtility.ensureDirectory(audioSegmentFolder)

            let screenSpec = SegmentSpec(width: 1280, height: 720, frameRate: 30, videoBitrate: 2_000_000)
            let cameraSpec = SegmentSpec(width: 640, height: 360, frameRate: 30, videoBitrate: 1_000_000)

            let screenWriter = SegmentWriter(config: .init(
                kind: .screen, folderURL: segmentFolder, segmentSeconds: 1.0, spec: screenSpec
            ))
            let cameraWriter = SegmentWriter(config: .init(
                kind: .camera, folderURL: segmentFolder, segmentSeconds: 1.0, spec: cameraSpec
            ))

            screenWriter.onError = { error in
                FileHandle.standardError.write(Data("SELFTEST writer error: \(error)\n".utf8))
            }
            cameraWriter.onError = { error in
                FileHandle.standardError.write(Data("SELFTEST camera writer error: \(error)\n".utf8))
            }

            let systemWriter = AudioTrackWriter(config: .init(
                trackID: "system",
                displayName: "System Audio",
                kind: .system,
                folderURL: audioSegmentFolder,
                segmentSeconds: 1.0,
                sampleRate: 48_000,
                channels: 2,
                bitrate: 256_000
            ))
            let micWriter = AudioTrackWriter(config: .init(
                trackID: "mic-test",
                displayName: "Test Microphone",
                kind: .microphone,
                folderURL: audioSegmentFolder,
                segmentSeconds: 1.0,
                sampleRate: 48_000,
                channels: 1,
                bitrate: 256_000
            ))
            let secondMicWriter = AudioTrackWriter(config: .init(
                trackID: "mic-test-2",
                displayName: "Test Microphone 2",
                kind: .microphone,
                folderURL: audioSegmentFolder,
                segmentSeconds: 1.0,
                sampleRate: 48_000,
                channels: 1,
                bitrate: 256_000
            ))
            systemWriter.onError = { error in
                FileHandle.standardError.write(Data("SELFTEST system audio error: \(error)\n".utf8))
            }
            micWriter.onError = { error in
                FileHandle.standardError.write(Data("SELFTEST mic audio error: \(error)\n".utf8))
            }
            secondMicWriter.onError = { error in
                FileHandle.standardError.write(Data("SELFTEST second mic audio error: \(error)\n".utf8))
            }

            screenWriter.start(at: 0)
            cameraWriter.start(at: 0)
            systemWriter.start()
            micWriter.start()
            secondMicWriter.start()

            let base = CMTime(seconds: 10_000, preferredTimescale: 600)
            let totalFrames = 120 // 4 seconds at 30 fps
            var systemPhase = 0.0
            var micPhase = 0.0
            var secondMicPhase = 0.0
            let samplesPerFrame = 1_600 // 48 kHz / 30 fps

            for frame in 0..<totalFrames {
                let videoPTS = base + CMTime(value: CMTimeValue(frame), timescale: 30)

                // Close a segment every second on every writer, at the same offset.
                if frame > 0, frame % 30 == 0 {
                    let offset = Double(frame) / 30.0
                    screenWriter.rotate(at: offset)
                    cameraWriter.rotate(at: offset)
                    systemWriter.rotate(at: offset)
                    micWriter.rotate(at: offset)
                    secondMicWriter.rotate(at: offset)
                }

                if let screenBuffer = SampleBufferFactory.videoSampleBuffer(
                    width: 1280, height: 720, presentationTime: videoPTS, frameIndex: frame
                ) {
                    screenWriter.append(video: screenBuffer)
                }
                if let cameraBuffer = SampleBufferFactory.videoSampleBuffer(
                    width: 640, height: 360, presentationTime: videoPTS, frameIndex: frame
                ) {
                    cameraWriter.append(video: cameraBuffer)
                }

                if let systemAudio = SampleBufferFactory.audioSampleBuffer(
                    sampleRate: 48_000, channels: 2, presentationTime: videoPTS,
                    frameCount: samplesPerFrame, phase: systemPhase
                ) {
                    systemWriter.append(systemAudio)
                    systemPhase += Double(samplesPerFrame) * 2.0 * .pi * 880.0 / 48_000.0
                }
                if let micAudio = SampleBufferFactory.audioSampleBuffer(
                    sampleRate: 48_000, channels: 1, presentationTime: videoPTS,
                    frameCount: samplesPerFrame, phase: micPhase
                ) {
                    micWriter.append(micAudio)
                    micPhase += Double(samplesPerFrame) * 2.0 * .pi * 440.0 / 48_000.0
                }
                if let secondMicAudio = SampleBufferFactory.audioSampleBuffer(
                    sampleRate: 48_000, channels: 1, presentationTime: videoPTS,
                    frameCount: samplesPerFrame, phase: secondMicPhase
                ) {
                    secondMicWriter.append(secondMicAudio)
                    secondMicPhase += Double(samplesPerFrame) * 2.0 * .pi * 660.0 / 48_000.0
                }

                try? await Task.sleep(nanoseconds: 33_000_000)
            }

            let screenSegments = try await screenWriter.finish()
            let cameraSegments = try await cameraWriter.finish()
            let systemSegments = try await systemWriter.finish()
            let micSegments = try await micWriter.finish()
            let secondMicSegments = try await secondMicWriter.finish()

            print("SELFTEST segments: screen=\(screenSegments.count) camera=\(cameraSegments.count) systemAudio=\(systemSegments.count) mic=\(micSegments.count) mic2=\(secondMicSegments.count)")
            guard screenSegments.count >= 3, cameraSegments.count >= 3,
                  systemSegments.count >= 3, micSegments.count >= 3,
                  secondMicSegments.count >= 3 else {
                print("SELFTEST FAIL: expected at least 3 segments per track")
                return 1
            }

            let screenURLs = screenSegments.map { segmentFolder.appendingPathComponent($0.fileName) }
            let cameraURLs = cameraSegments.map { segmentFolder.appendingPathComponent($0.fileName) }
            let systemURLs = systemSegments.map { audioSegmentFolder.appendingPathComponent($0.fileName) }
            let micURLs = micSegments.map { audioSegmentFolder.appendingPathComponent($0.fileName) }
            let secondMicURLs = secondMicSegments.map { audioSegmentFolder.appendingPathComponent($0.fileName) }

            let mergeService = MergeService()
            let outcome = try await mergeService.merge(
                screenSegments: screenURLs,
                cameraSegments: cameraURLs,
                audioTracks: [
                    MergeAudioTrack(
                        id: "system",
                        name: "System Audio",
                        kind: .system,
                        segments: systemURLs,
                        outputFileName: "audio/system.m4a"
                    ),
                    MergeAudioTrack(
                        id: "mic-test",
                        name: "Test Microphone",
                        kind: .microphone,
                        segments: micURLs,
                        outputFileName: "audio/mic-test.m4a"
                    ),
                    MergeAudioTrack(
                        id: "mic-test-2",
                        name: "Test Microphone 2",
                        kind: .microphone,
                        segments: secondMicURLs,
                        outputFileName: "audio/mic-test-2.m4a"
                    )
                ],
                folderURL: root,
                progress: nil
            )

            guard let screenOutput = outcome.screenURL, let cameraOutput = outcome.cameraURL else {
                print("SELFTEST FAIL: merge did not produce both video outputs")
                return 1
            }

            let screenAsset = AVURLAsset(url: screenOutput)
            let cameraAsset = AVURLAsset(url: cameraOutput)
            let screenDuration = CMTimeGetSeconds(screenAsset.duration)
            let cameraDuration = CMTimeGetSeconds(cameraAsset.duration)
            let screenVideoTracks = screenAsset.tracks(withMediaType: .video).count
            let screenAudioTracks = screenAsset.tracks(withMediaType: .audio).count
            let cameraVideoTracks = cameraAsset.tracks(withMediaType: .video).count
            let cameraAudioTracks = cameraAsset.tracks(withMediaType: .audio).count

            let screenBytes = FSUtility.fileSize(at: screenOutput)
            let cameraBytes = FSUtility.fileSize(at: cameraOutput)

            print("SELFTEST merged screen: duration=\(String(format: "%.2f", screenDuration))s tracks=v\(screenVideoTracks)/a\(screenAudioTracks) bytes=\(screenBytes)")
            print("SELFTEST merged camera: duration=\(String(format: "%.2f", cameraDuration))s tracks=v\(cameraVideoTracks)/a\(cameraAudioTracks) bytes=\(cameraBytes)")

            var failures: [String] = []
            if screenDuration < 3.0 || screenDuration > 6.0 { failures.append("screen duration \(screenDuration)") }
            if cameraDuration < 3.0 || cameraDuration > 6.0 { failures.append("camera duration \(cameraDuration)") }
            if screenVideoTracks != 1 { failures.append("screen video track count \(screenVideoTracks)") }
            if screenAudioTracks != 3 { failures.append("screen audio track count \(screenAudioTracks), expected 3") }
            if cameraVideoTracks != 1 { failures.append("camera video track count \(cameraVideoTracks)") }
            if cameraAudioTracks != 2 { failures.append("camera audio track count \(cameraAudioTracks), expected 2 (mics only)") }
            if screenBytes < 100_000 { failures.append("screen file too small (\(screenBytes))") }
            if cameraBytes < 50_000 { failures.append("camera file too small (\(cameraBytes))") }

            if outcome.audioURLs.count != 3 {
                failures.append("expected 3 standalone audio files, got \(outcome.audioURLs.count)")
            }
            for (trackID, url) in outcome.audioURLs {
                let asset = AVURLAsset(url: url)
                let duration = CMTimeGetSeconds(asset.duration)
                let audioTracks = asset.tracks(withMediaType: .audio).count
                let bytes = FSUtility.fileSize(at: url)
                print("SELFTEST standalone audio \(trackID): duration=\(String(format: "%.2f", duration))s tracks=\(audioTracks) bytes=\(bytes) path=\(url.lastPathComponent)")
                if duration < 3.0 || duration > 6.0 { failures.append("\(trackID) audio duration \(duration)") }
                if audioTracks != 1 { failures.append("\(trackID) audio track count \(audioTracks)") }
                if bytes < 10_000 { failures.append("\(trackID) audio file too small (\(bytes))") }
            }

            if failures.isEmpty {
                print("SELFTEST PASS")
                try? FileManager.default.removeItem(at: root)
                return 0
            } else {
                print("SELFTEST FAIL: \(failures.joined(separator: ", "))")
                print("SELFTEST artifacts kept at \(root.path)")
                return 1
            }
        } catch {
            print("SELFTEST FAIL: \(error)")
            print("SELFTEST artifacts kept at \(root.path)")
            return 1
        }
    }

    // MARK: - Crash recovery self-test

    /// Simulates a crash: writes real video + audio segments, records only the
    /// first two of each in the manifest, leaves an extra finalized segment and
    /// partial files on disk, then runs `RecoveryService` and verifies the result.
    /// Run with: RecBar --selftest-recovery
    public static func runRecovery() async -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recbar-recovery-\(UUID().uuidString)", isDirectory: true)
        let recordingsFolder = root.appendingPathComponent("recordings", isDirectory: true)
        let sessionFolder = recordingsFolder.appendingPathComponent("2026-01-01_00-00-00", isDirectory: true)
        let segmentFolder = sessionFolder.appendingPathComponent("segments", isDirectory: true)
        let audioSegmentFolder = sessionFolder
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)

        do {
            try FSUtility.ensureDirectory(segmentFolder)
            try FSUtility.ensureDirectory(audioSegmentFolder)

            guard let written = await writeSyntheticSegments(
                segmentFolder: segmentFolder,
                audioSegmentFolder: audioSegmentFolder,
                totalFrames: 90
            ) else {
                print("SELFTEST-RECOVERY FAIL: could not write synthetic segments")
                return 1
            }

            guard written.screen.count == 3, written.camera.count == 3,
                  written.system.count == 3, written.mic.count == 3 else {
                print("SELFTEST-RECOVERY FAIL: expected 3 segments per track, got screen=\(written.screen.count) camera=\(written.camera.count) system=\(written.system.count) mic=\(written.mic.count)")
                return 1
            }

            // The crash landed after segment 3 was renamed into place but before
            // the manifest recorded it, so the manifest only knows about two.
            var manifest = SessionManifest(
                id: sessionFolder.lastPathComponent,
                startedAt: Date(),
                status: .recording,
                settings: RecorderSettings(),
                display: nil
            )
            manifest.screenSegments = Array(written.screen.prefix(2))
            manifest.cameraSegments = Array(written.camera.prefix(2))
            manifest.audioTracks = [
                AudioTrackInfo(id: "system", name: "System Audio", kind: .system,
                               segments: Array(written.system.prefix(2))),
                AudioTrackInfo(id: "mic-test", name: "Test Microphone", kind: .microphone,
                               segments: Array(written.mic.prefix(2)))
            ]
            try ManifestStore.write(manifest, to: sessionFolder)

            let partialVideo = segmentFolder.appendingPathComponent("screen-00004.partial.mp4")
            let partialAudio = audioSegmentFolder.appendingPathComponent("system-00004.partial.m4a")
            try Data("partial".utf8).write(to: partialVideo)
            try Data("partial".utf8).write(to: partialAudio)

            let scanned = RecoveryService.scan(folderURL: recordingsFolder)
            guard scanned.count == 1, let session = scanned.first else {
                print("SELFTEST-RECOVERY FAIL: scan found \(scanned.count) sessions, expected 1")
                return 1
            }
            print("SELFTEST-RECOVERY scan: screen=\(session.screenSegments.count) camera=\(session.cameraSegments.count) audioTracks=\(session.audioTracks.count)")
            guard session.screenSegments.count == 3, session.cameraSegments.count == 3,
                  session.audioTracks.count == 2 else {
                print("SELFTEST-RECOVERY FAIL: scan did not union the manifest with disk")
                return 1
            }

            let result = try await RecoveryService.recover(session, keepSegments: false)
            guard let screenOutput = result.screenURL, let cameraOutput = result.cameraURL else {
                print("SELFTEST-RECOVERY FAIL: recovery produced no video outputs")
                return 1
            }

            var failures: [String] = []
            let screenAsset = AVURLAsset(url: screenOutput)
            let cameraAsset = AVURLAsset(url: cameraOutput)
            let screenDuration = CMTimeGetSeconds(screenAsset.duration)
            let screenVideoTracks = screenAsset.tracks(withMediaType: .video).count
            let screenAudioTracks = screenAsset.tracks(withMediaType: .audio).count
            let cameraVideoTracks = cameraAsset.tracks(withMediaType: .video).count
            let cameraAudioTracks = cameraAsset.tracks(withMediaType: .audio).count

            print("SELFTEST-RECOVERY merged screen: duration=\(String(format: "%.2f", screenDuration))s tracks=v\(screenVideoTracks)/a\(screenAudioTracks) bytes=\(FSUtility.fileSize(at: screenOutput))")
            print("SELFTEST-RECOVERY merged camera: duration=\(String(format: "%.2f", CMTimeGetSeconds(cameraAsset.duration)))s tracks=v\(cameraVideoTracks)/a\(cameraAudioTracks) bytes=\(FSUtility.fileSize(at: cameraOutput))")
            if screenDuration < 2.5 || screenDuration > 4.5 { failures.append("screen duration \(screenDuration)") }
            if screenVideoTracks != 1 || screenAudioTracks != 2 { failures.append("screen tracks v\(screenVideoTracks)/a\(screenAudioTracks), expected v1/a2") }
            if cameraVideoTracks != 1 || cameraAudioTracks != 1 { failures.append("camera tracks v\(cameraVideoTracks)/a\(cameraAudioTracks), expected v1/a1") }
            if result.audioURLs.count != 2 { failures.append("standalone audio files \(result.audioURLs.count), expected 2") }

            let reloaded = try ManifestStore.load(from: sessionFolder)
            if reloaded.status != .recovered { failures.append("manifest status \(reloaded.status.rawValue)") }
            if reloaded.audioOutputs.count != 2 { failures.append("manifest audioOutputs \(reloaded.audioOutputs.count), expected 2") }
            if reloaded.screenSegments.count != 3 { failures.append("manifest screenSegments \(reloaded.screenSegments.count), expected 3") }

            if FileManager.default.fileExists(atPath: partialVideo.path) { failures.append("partial video was not cleaned up") }
            if FileManager.default.fileExists(atPath: partialAudio.path) { failures.append("partial audio was not cleaned up") }

            if failures.isEmpty {
                print("SELFTEST-RECOVERY PASS")
                try? FileManager.default.removeItem(at: root)
                return 0
            }
            print("SELFTEST-RECOVERY FAIL: \(failures.joined(separator: ", "))")
            print("SELFTEST-RECOVERY artifacts kept at \(root.path)")
            return 1
        } catch {
            print("SELFTEST-RECOVERY FAIL: \(error)")
            print("SELFTEST-RECOVERY artifacts kept at \(root.path)")
            return 1
        }
    }

    // MARK: - Synthetic segment writing (shared by the recovery test)

    private struct SyntheticSegments {
        var screen: [SegmentInfo]
        var camera: [SegmentInfo]
        var system: [AudioSegmentInfo]
        var mic: [AudioSegmentInfo]
    }

    private static func writeSyntheticSegments(
        segmentFolder: URL,
        audioSegmentFolder: URL,
        totalFrames: Int
    ) async -> SyntheticSegments? {
        let screenSpec = SegmentSpec(width: 640, height: 360, frameRate: 30, videoBitrate: 1_000_000)
        let cameraSpec = SegmentSpec(width: 320, height: 180, frameRate: 30, videoBitrate: 500_000)

        let screenWriter = SegmentWriter(config: .init(
            kind: .screen, folderURL: segmentFolder, segmentSeconds: 1.0, spec: screenSpec
        ))
        let cameraWriter = SegmentWriter(config: .init(
            kind: .camera, folderURL: segmentFolder, segmentSeconds: 1.0, spec: cameraSpec
        ))
        let systemWriter = AudioTrackWriter(config: .init(
            trackID: "system", displayName: "System Audio", kind: .system,
            folderURL: audioSegmentFolder, segmentSeconds: 1.0,
            sampleRate: 48_000, channels: 2, bitrate: 128_000
        ))
        let micWriter = AudioTrackWriter(config: .init(
            trackID: "mic-test", displayName: "Test Microphone", kind: .microphone,
            folderURL: audioSegmentFolder, segmentSeconds: 1.0,
            sampleRate: 48_000, channels: 1, bitrate: 128_000
        ))

        let errorHandler: (Error) -> Void = { error in
            FileHandle.standardError.write(Data("SELFTEST synthetic writer error: \(error)\n".utf8))
        }
        screenWriter.onError = errorHandler
        cameraWriter.onError = errorHandler
        systemWriter.onError = errorHandler
        micWriter.onError = errorHandler

        screenWriter.start(at: 0)
        cameraWriter.start(at: 0)
        systemWriter.start()
        micWriter.start()

        let base = CMTime(seconds: 10_000, preferredTimescale: 600)
        var systemPhase = 0.0
        var micPhase = 0.0
        let samplesPerFrame = 1_600 // 48 kHz / 30 fps

        for frame in 0..<totalFrames {
            let videoPTS = base + CMTime(value: CMTimeValue(frame), timescale: 30)

            if frame > 0, frame % 30 == 0 {
                let offset = Double(frame) / 30.0
                screenWriter.rotate(at: offset)
                cameraWriter.rotate(at: offset)
                systemWriter.rotate(at: offset)
                micWriter.rotate(at: offset)
            }

            if let buffer = SampleBufferFactory.videoSampleBuffer(
                width: 640, height: 360, presentationTime: videoPTS, frameIndex: frame
            ) {
                screenWriter.append(video: buffer)
            }
            if let buffer = SampleBufferFactory.videoSampleBuffer(
                width: 320, height: 180, presentationTime: videoPTS, frameIndex: frame
            ) {
                cameraWriter.append(video: buffer)
            }
            if let buffer = SampleBufferFactory.audioSampleBuffer(
                sampleRate: 48_000, channels: 2, presentationTime: videoPTS,
                frameCount: samplesPerFrame, phase: systemPhase
            ) {
                systemWriter.append(buffer)
                systemPhase += Double(samplesPerFrame) * 2.0 * .pi * 880.0 / 48_000.0
            }
            if let buffer = SampleBufferFactory.audioSampleBuffer(
                sampleRate: 48_000, channels: 1, presentationTime: videoPTS,
                frameCount: samplesPerFrame, phase: micPhase
            ) {
                micWriter.append(buffer)
                micPhase += Double(samplesPerFrame) * 2.0 * .pi * 440.0 / 48_000.0
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        do {
            let screen = try await screenWriter.finish()
            let camera = try await cameraWriter.finish()
            let system = try await systemWriter.finish()
            let mic = try await micWriter.finish()
            return SyntheticSegments(screen: screen, camera: camera, system: system, mic: mic)
        } catch {
            print("SELFTEST synthetic writer finish failed: \(error)")
            return nil
        }
    }
}
