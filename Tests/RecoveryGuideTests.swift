import Foundation

// Validates the shipped instructions without running any sleep-setting command.
@main struct RecoveryGuideTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = URL(fileURLWithPath: CommandLine.arguments[2])
        let bundle = Bundle(url: app)!
        for language in AppLanguage.allCases {
            let file = root.appendingPathComponent(language.rawValue + ".lproj/Localizable.strings")
            let data = try Data(contentsOf: file)
            let translations = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            let localizer = AppLocalizer(language: language, bundle: bundle)
            let sections = SleepRecoveryGuide.sections(using: localizer)
            try expect(sections.first?.title == localizer.text("If your Mac stops sleeping"), "User actions must come first")
            try expect(sections.last?.title == localizer.text("What Wakecup changes"), "Technical explanation belongs last")
            for key in ["recovery.introduction", "recovery.helper", "Open guide separately"]
                + (1...5).map({ "recovery.section.\($0)" }) {
                try expect(translations[key]?.isEmpty == false, "Missing guide text: \(key)")
                try expect(localizer.text(key) == translations[key], "Packaged guide is stale: \(key)")
            }
            let firstSteps = localizer.text("recovery.section.2")
            for key in ["Start", "Stop", "Restore Normal Sleep"] {
                try expect(firstSteps.contains(localizer.text(key)), "Guide must use the current button title: \(key)")
            }
            let helperGuide = localizer.text("recovery.helper")
            for key in ["Install", "Configure…", "Update"] {
                try expect(helperGuide.contains(localizer.text(key)), "Helper guide must use the current action title: \(key)")
            }
            let process = Process()
            process.executableURL = app.appendingPathComponent("Contents/MacOS/Wakecup")
            process.arguments = ["--recovery-guide", "--language", language.rawValue]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let guide = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "Could not generate the separate guide")
            let shipped = try String(contentsOf: app.appendingPathComponent("Contents/Resources/RecoveryGuide.\(language.rawValue).txt"), encoding: .utf8)
            try expect(guide == shipped, "Separate guide differs from the app's current instructions")
            try expect(guide.contains(localizer.text("recovery.introduction")), "Separate guide needs the same context")
            var position = guide.startIndex
            for section in sections {
                guard let range = guide.range(of: section.title + "\n" + section.text, range: position..<guide.endIndex) else {
                    throw WakecupError(message: "A guide section is missing or out of order")
                }
                position = range.upperBound
            }
            let commands = guide.split(separator: "\n").filter { $0.hasPrefix("/usr/bin/") || $0.hasPrefix("sudo ") }
            try expect(commands.map(String.init) == [SleepRecoveryGuide.resetCommand, SleepRecoveryGuide.checkCommand, SleepRecoveryGuide.assertionsCommand],
                       "Recovery commands must remain unchanged and in the right order")
            print("PASS: \(language.rawValue) guide, current buttons, action order, exported copy and recovery commands")
        }
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WakecupError(message: message) }
    }
}
