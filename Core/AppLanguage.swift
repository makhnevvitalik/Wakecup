import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    var displayName: String { self == .english ? "English" : "Русский" }

    static func preferred(from identifiers: [String]) -> AppLanguage {
        let match = Bundle.preferredLocalizations(from: allCases.map(\.rawValue), forPreferences: identifiers).first
        return match.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

struct AppLocalizer {
    private let table: [String: String]

    init(language: AppLanguage, bundle: Bundle = .main) {
        let url = bundle.url(forResource: language.rawValue, withExtension: "lproj")?
            .appendingPathComponent("Localizable.strings")
        table = url.flatMap { try? Data(contentsOf: $0) }.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String]
        } ?? [:]
    }

    func text(_ key: String) -> String { table[key] ?? key }
}
