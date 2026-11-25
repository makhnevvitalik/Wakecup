import Foundation

enum SettingsKey {
    static let schemaVersion = "settingsSchemaVersion"
    static let displayRestoreShortcut = "displayRestoreShortcutV1"
}

enum SettingsMigrator {
    typealias Step = (UserDefaults) throws -> Void

    enum Failure: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "This build cannot read settings version \(version)."
            }
        }
    }

    // Each entry upgrades one schema version. Append later migrations in order.
    private static let steps: [Step] = [migrateRestoreShortcut]

    static func run(defaults: UserDefaults = .standard) throws {
        try run(defaults: defaults, steps: steps)
    }

    static func run(defaults: UserDefaults, steps: [Step]) throws {
        let version = defaults.integer(forKey: SettingsKey.schemaVersion)
        guard (0...steps.count).contains(version) else { throw Failure.unsupportedVersion(version) }
        for (oldVersion, step) in steps.enumerated().dropFirst(version) {
            try step(defaults)
            defaults.set(oldVersion + 1, forKey: SettingsKey.schemaVersion)
        }
    }

    private static func migrateRestoreShortcut(_ defaults: UserDefaults) throws {
        let legacyKey = "displayRestoreShortcut"
        let currentKey = SettingsKey.displayRestoreShortcut
        // A repeat after interruption takes the value already written in the new format.
        if defaults.object(forKey: currentKey) == nil,
           let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode(LegacyDisplayShortcut.self, from: data),
           let shortcut = legacy.current {
            defaults.set(try JSONEncoder().encode(shortcut), forKey: currentKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}
