import Foundation

/// Owns the session manifest. Every mutation is serialized and written atomically
/// with an fsync, so the manifest on disk is always a valid snapshot.
public final class ManifestStore {
    public let folderURL: URL
    public let manifestURL: URL

    private let queue = DispatchQueue(label: "app.recbar.manifest")
    private var stored: SessionManifest

    public init(folderURL: URL, settings: RecorderSettings, display: DisplayInfo?) throws {
        self.folderURL = folderURL
        self.manifestURL = folderURL.appendingPathComponent("manifest.json")
        try FSUtility.ensureDirectory(folderURL)
        self.stored = SessionManifest(
            id: folderURL.lastPathComponent,
            startedAt: Date(),
            status: .recording,
            settings: settings,
            display: display
        )
        try writeLocked()
    }

    public var manifest: SessionManifest {
        queue.sync { stored }
    }

    public func addSegment(_ segment: SegmentInfo) {
        queue.sync {
            switch segment.kind {
            case .screen:
                stored.screenSegments.append(segment)
                stored.screenSegments.sort { $0.index < $1.index }
            case .camera:
                stored.cameraSegments.append(segment)
                stored.cameraSegments.sort { $0.index < $1.index }
            }
            try? writeLocked()
        }
    }

    public func setStatus(_ status: SessionStatus) {
        queue.sync {
            stored.status = status
            if status == .complete || status == .recovered || status == .failed {
                if stored.endedAt == nil { stored.endedAt = Date() }
            }
            try? writeLocked()
        }
    }

    public func setEndedNow() {
        queue.sync {
            stored.endedAt = Date()
            try? writeLocked()
        }
    }

    public func setOutput(kind: TrackKind, fileName: String) {
        queue.sync {
            stored.outputs[kind.rawValue] = fileName
            try? writeLocked()
        }
    }

    /// Declares an audio source up front so the manifest lists it even when the
    /// device stays silent for the whole recording.
    public func registerAudioTrack(_ track: AudioTrackDescriptor) {
        queue.sync {
            guard !stored.audioTracks.contains(where: { $0.id == track.id }) else { return }
            stored.audioTracks.append(
                AudioTrackInfo(id: track.id, name: track.name, kind: track.kind)
            )
            try? writeLocked()
        }
    }

    /// Adds one finalized audio segment to its logical track, creating the track on
    /// first use. The track order in the manifest follows capture start order.
    public func addAudioSegment(_ segment: AudioSegmentInfo, track: AudioTrackDescriptor) {
        queue.sync {
            if let index = stored.audioTracks.firstIndex(where: { $0.id == track.id }) {
                stored.audioTracks[index].segments.append(segment)
                stored.audioTracks[index].segments.sort { $0.index < $1.index }
            } else {
                stored.audioTracks.append(
                    AudioTrackInfo(
                        id: track.id,
                        name: track.name,
                        kind: track.kind,
                        segments: [segment]
                    )
                )
            }
            try? writeLocked()
        }
    }

    public func setAudioOutput(trackID: String, fileName: String) {
        queue.sync {
            stored.audioOutputs[trackID] = fileName
            if let index = stored.audioTracks.firstIndex(where: { $0.id == trackID }) {
                stored.audioTracks[index].outputFileName = fileName
            }
            try? writeLocked()
        }
    }

    public func addNote(_ note: String) {
        queue.sync {
            stored.notes.append(note)
            try? writeLocked()
        }
    }

    public func markLost(seconds: Double) {
        queue.sync {
            stored.lostSeconds = max(stored.lostSeconds, seconds)
            try? writeLocked()
        }
    }

    public func updateDisplay(_ display: DisplayInfo) {
        queue.sync {
            stored.display = display
            try? writeLocked()
        }
    }

    public func update(_ body: (inout SessionManifest) -> Void) {
        queue.sync {
            body(&stored)
            try? writeLocked()
        }
    }

    private func writeLocked() throws {
        try ManifestStore.write(stored, to: folderURL)
    }

    public static func write(_ manifest: SessionManifest, to folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try FSUtility.atomicWrite(data, to: folderURL.appendingPathComponent("manifest.json"))
    }

    public static func load(from folderURL: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folderURL.appendingPathComponent("manifest.json"))
        return try decoder.decode(SessionManifest.self, from: data)
    }
}
