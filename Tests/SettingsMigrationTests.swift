import Foundation

@main struct SettingsMigrationTests {
    private enum Interrupted: Error { case write }

    static func main() throws {
        let suite = "WakecupSettingsMigration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyKey = "displayRestoreShortcut"
        let versionKey = SettingsKey.schemaVersion
        let shortcutKey = SettingsKey.displayRestoreShortcut

        let samples: [(UInt32, UInt32, UInt32, String)] = [
            (8, 8, 1, "⌘C"),
            (120, 1, 8, "⇧F2"),
            (120, 2, 4, "⌃F2"),
            (120, 4, 2, "⌥F2"),
            (8, 10, 5, "⌃⌘C")
        ]
        for (keyCode, oldMask, newMask, label) in samples {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(legacy(keyCode, oldMask), forKey: legacyKey)
            try SettingsMigrator.run(defaults: defaults)
            let data = defaults.data(forKey: shortcutKey)!
            let shortcut = try JSONDecoder().decode(DisplayShortcut.self, from: data)
            try expect(shortcut.keyCode == keyCode && shortcut.modifiers == newMask && shortcut.displayName == label,
                       "Migration must preserve the physical combination \(label)")
            try expect(defaults.integer(forKey: versionKey) == 1 && defaults.object(forKey: legacyKey) == nil,
                       "Completing migration must commit the version and retire the old key")
            try SettingsMigrator.run(defaults: defaults)
            try expect(defaults.data(forKey: shortcutKey) == data, "Running migrations again must keep the current value")
        }

        defaults.removePersistentDomain(forName: suite)
        defaults.set(legacy(8, 8), forKey: legacyKey)
        let alreadySaved = try JSONEncoder().encode(DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.command))
        defaults.set(alreadySaved, forKey: shortcutKey)
        try SettingsMigrator.run(defaults: defaults)
        try expect(defaults.data(forKey: shortcutKey) == alreadySaved && defaults.object(forKey: legacyKey) == nil,
                   "Restarting after a partial migration must preserve the new value")
        defaults.removeObject(forKey: shortcutKey)
        try SettingsMigrator.run(defaults: defaults)
        try expect(defaults.object(forKey: shortcutKey) == nil, "A cleared shortcut must not be restored by migration")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(legacy(8, 1), forKey: legacyKey)
        try SettingsMigrator.run(defaults: defaults)
        try expect(defaults.object(forKey: shortcutKey) == nil && defaults.object(forKey: legacyKey) == nil,
                   "An invalid legacy Shift-only letter must not become a global shortcut")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(90, forKey: versionKey)
        defaults.set(legacy(8, 8), forKey: legacyKey)
        do {
            try SettingsMigrator.run(defaults: defaults)
            throw WakecupError(message: "The migrator must reject an unknown future version")
        } catch SettingsMigrator.Failure.unsupportedVersion(90) {}
        try expect(defaults.integer(forKey: versionKey) == 90 && defaults.data(forKey: legacyKey) == legacy(8, 8),
                   "An older build must leave settings from an unknown schema intact")

        defaults.removePersistentDomain(forName: suite)
        var visits: [Int] = []
        let first: SettingsMigrator.Step = { _ in visits.append(1) }
        let second: SettingsMigrator.Step = { _ in visits.append(2); throw Interrupted.write }
        do {
            try SettingsMigrator.run(defaults: defaults, steps: [first, second])
            throw WakecupError(message: "A failed migration must report its error")
        } catch Interrupted.write {}
        try expect(visits == [1, 2] && defaults.integer(forKey: versionKey) == 1,
                   "A failing step must retain the version of the last completed step")
        try SettingsMigrator.run(defaults: defaults, steps: [first, { store in
            visits.append(3)
            store.set(true, forKey: "unrelatedSetting")
        }])
        try expect(visits == [1, 2, 3] && defaults.integer(forKey: versionKey) == 2 && defaults.bool(forKey: "unrelatedSetting"),
                   "Registered steps can extend the settings schema and safely retry after failure")

        print("PASS: ordered settings migrations, legacy shortcuts, interruptions, clearing and future versions")
    }

    private static func legacy(_ keyCode: UInt32, _ modifiers: UInt32) -> Data {
        Data("{\"keyCode\":\(keyCode),\"modifiers\":\(modifiers)}".utf8)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WakecupError(message: message) }
    }
}
