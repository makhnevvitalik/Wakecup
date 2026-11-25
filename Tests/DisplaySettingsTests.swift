import Foundation

@main struct DisplaySettingsTests {
    static func main() throws {
        var failures: [String] = []
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        expect(DisplayShortcut.command == 1 && DisplayShortcut.option == 2
            && DisplayShortcut.control == 4 && DisplayShortcut.shift == 8,
            "Wakecup modifiers must use the same flags as LangSwitch")
        expect(!DisplayMode.mayTurnOff.keepsDisplayOn && DisplayMode.keepOn.keepsDisplayOn
            && DisplayMode.backlightOff.keepsDisplayOn, "Backlight off keeps the logical display awake")
        // macOS F1–F20 virtual keys, in function-number order (same keys as Lang Switcher).
        let functionKeys: [UInt32] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let letters: [UInt32] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits: [UInt32] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for code: UInt32 in 0...127 {
            for modifiers: UInt32 in [1, 2, 4, 8, 15] {
                let chord = DisplayShortcut(keyCode: code, modifiers: modifiers)
                let isAlphanumeric = letters.contains(code) || digits.contains(code)
                let expected = functionKeys.contains(code) || (isAlphanumeric && modifiers != DisplayShortcut.shift)
                expect(chord.isValid == expected, "Supported physical key and modifier combination: \(code)/\(modifiers)")
            }
        }
        for (code, label) in zip(letters + digits, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") {
            let value = DisplayShortcut(keyCode: code, modifiers: DisplayShortcut.control | DisplayShortcut.shift)
            expect(value.displayName == "⌃⇧\(label)", "Physical key labels stay stable across layouts")
            expect(try JSONDecoder().decode(DisplayShortcut.self, from: JSONEncoder().encode(value)) == value,
                   "Alphanumeric shortcuts round-trip without losing the physical key")
        }
        for modifiers: UInt32 in [0,16,24,0x80000008] {
            expect(!DisplayShortcut(keyCode: 120, modifiers: modifiers).isValid, "Bare F keys and unsupported modifier bits are rejected")
        }
        for (index, code) in functionKeys.enumerated() {
            let value = DisplayShortcut(keyCode: code, modifiers: 15)
            expect(value.displayName == "⌃⌥⇧⌘F\(index + 1)", "Function labels must be stable on every layout")
        }
        let chord = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.command)
        expect(try JSONDecoder().decode(DisplayShortcut.self, from: JSONEncoder().encode(chord)) == chord, "Supported shortcut persists exactly")
        let newLetter = try JSONDecoder().decode(DisplayShortcut.self, from: Data(#"{"keyCode":15,"modifiers":1}"#.utf8))
        expect(newLetter.isValid && newLetter.displayName == "⌘R", "Stored modifiers match LangSwitch and keep the physical key label")
        print("Display shortcut checks: \(checks), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
