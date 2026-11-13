import Foundation
import Combine

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    static let languageKey = "app.language"
    @Published private(set) var language: AppLanguage
    private let defaults: UserDefaults
    private let bundle: Bundle
    private(set) var localizer: AppLocalizer

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        let selectedLanguage = defaults.string(forKey: Self.languageKey).flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.preferred(from: preferredLanguages)
        language = selectedLanguage
        localizer = AppLocalizer(language: selectedLanguage, bundle: bundle)
    }

    func select(_ language: AppLanguage) {
        localizer = AppLocalizer(language: language, bundle: bundle)
        defaults.set(language.rawValue, forKey: Self.languageKey)
        self.language = language
    }

    func text(_ key: String) -> String { localizer.text(key) }
}

func localized(_ key: String) -> String { AppLocalization.shared.text(key) }
func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    let localization = AppLocalization.shared
    return String(format: localization.text(key), locale: Locale(identifier: localization.language.rawValue), arguments: arguments)
}
