import Foundation

enum SleepRecoveryGuide {
    static var title: String { localized("How to restore Mac sleep") }
    static var introduction: String { localized("recovery.introduction") }
    static let resetCommand = "sudo /usr/bin/pmset disablesleep 0"
    static let checkCommand = "/usr/bin/pmset -g"
    static let assertionsCommand = "/usr/bin/pmset -g assertions"

    struct Section {
        let title: String
        let text: String
        let command: String?
    }

    private static let definitions: [(String, String, String?)] = [
        ("If your Mac stops sleeping", "recovery.section.2", nil),
        ("Manual recovery without Wakecup", "recovery.section.3", resetCommand),
        ("Check the result", "recovery.section.4", checkCommand),
        ("If your Mac still stays awake", "recovery.section.5", assertionsCommand),
        ("Optional helper", "recovery.helper", nil),
        ("What Wakecup changes", "recovery.section.1", nil)
    ]

    static var sections: [Section] { sections(using: AppLocalization.shared.localizer) }

    static func sections(using localizer: AppLocalizer) -> [Section] {
        definitions.map { Section(title: localizer.text($0.0), text: localizer.text($0.1), command: $0.2) }
    }

    static func plainText(language: AppLanguage) -> String {
        let localizer = AppLocalizer(language: language)
        return localizer.text("How to restore Mac sleep") + "\n\n" + localizer.text("recovery.introduction") + "\n\n" + sections(using: localizer).map { section in
            section.title + "\n" + section.text + (section.command.map { "\n\n" + $0 } ?? "")
        }.joined(separator: "\n\n") + "\n"
    }
}
