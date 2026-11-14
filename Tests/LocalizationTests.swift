import Foundation
@main struct LocalizationTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw NSError(domain: label, code: 1) }
        }
        try expect(AppLanguage.preferred(from: ["ru-RU"]) == .russian, "Russian locale detection")
        try expect(AppLanguage.preferred(from: ["en-GB"]) == .english, "English locale detection")
        try expect(AppLanguage.preferred(from: ["de-DE"]) == .english, "Unsupported language fallback")
        let suite = "WakecupLocalizationTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppLocalization(defaults: defaults, preferredLanguages: ["ru-RU"])
        try expect(first.language == .russian, "First launch uses system language")
        first.select(.english)
        let second = AppLocalization(defaults: defaults, preferredLanguages: ["ru-RU"])
        try expect(second.language == .english, "Explicit language persists across launches")
        defaults.set("invalid", forKey: AppLocalization.languageKey)
        try expect(AppLocalization(defaults: defaults, preferredLanguages: ["ru-RU"]).language == .russian,
                   "Invalid preference falls back to system language")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var tables: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let data = try Data(contentsOf: root.appendingPathComponent(language.rawValue + ".lproj/Localizable.strings"))
            tables[language] = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        }
        try expect(Set(tables[.english]!.keys) == Set(tables[.russian]!.keys), "Both languages cover the same keys")
        try expect(tables[.russian]!["Settings"] == "Настройки", "Russian settings accessibility label")
        for language in AppLanguage.allCases {
            for key in ["Cancel", "OK", "helper.explanation", "Update helper", "Remove"] {
                try expect(tables[language]![key]?.isEmpty == false, "Helper dialogs require complete translations: " + key)
            }
            try expect(tables[language]!["Keep awake on battery"] != nil, "Battery label exists in catalog")
            try expect(tables[language]!["battery.power.help"]?.isEmpty == false, "Battery explanation exists in catalog")
            try expect(tables[language]!["closed.lid.help"]?.isEmpty == false, "Closed-lid explanation exists in catalog")
        }
        if CommandLine.arguments.count > 2 {
            guard let bundle = Bundle(path: CommandLine.arguments[2]) else {
                throw NSError(domain: "App bundle is unavailable", code: 1)
            }
            for language in AppLanguage.allCases {
                let packaged = AppLocalizer(language: language, bundle: bundle)
                try expect(packaged.text("unknown-test-key") == "unknown-test-key",
                           "A missing translation must return the original key")
                try expect(packaged.text("Settings") == tables[language]!["Settings"], "Packaged settings accessibility label")
                try expect(packaged.text("Keep awake on battery") == tables[language]!["Keep awake on battery"], "Packaged battery translation")
                try expect(packaged.text("battery.power.help") == tables[language]!["battery.power.help"], "Packaged battery explanation")
                try expect(packaged.text("closed.lid.help") == tables[language]!["closed.lid.help"], "Packaged closed-lid explanation")
                try expect(packaged.text("How to restore Mac sleep") == tables[language]!["How to restore Mac sleep"], "Packaged recovery translation")
                try expect(packaged.text("recovery.section.1") == tables[language]!["recovery.section.1"], "Packaged full recovery text")
            }
        }
        print("Localization checks: \(checks), failures: 0")
    }
}
