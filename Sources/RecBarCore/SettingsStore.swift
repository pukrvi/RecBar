import Foundation

public final class SettingsStore {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("RecBar/settings.json")
        }
    }

    public func load() -> RecorderSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return RecorderSettings() }
        do {
            return try JSONDecoder().decode(RecorderSettings.self, from: data)
        } catch {
            NSLog("RecBar: could not read settings (%@), using defaults", String(describing: error))
            return RecorderSettings()
        }
    }

    public func save(_ settings: RecorderSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try FSUtility.atomicWrite(data, to: fileURL)
        } catch {
            NSLog("RecBar: could not save settings (%@)", String(describing: error))
        }
    }
}
