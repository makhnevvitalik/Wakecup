import Foundation

@main struct DisplaySettingsTests {
    static func main() throws {
        var failures: [String] = []
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        expect(!DisplayMode.mayTurnOff.keepsDisplayOn && DisplayMode.keepOn.keepsDisplayOn
            && DisplayMode.backlightOff.keepsDisplayOn, "Backlight off keeps the logical display awake")
        // macOS F1–F20 virtual keys, in function-number order (same keys as Lang Switcher).
        let functionKeys: [UInt32] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        for code: UInt32 in 0...127 {
            for modifiers: UInt32 in [1,2,4,8,15] {
                let chord = DisplayShortcut(keyCode: code, modifiers: modifiers)
                expect(chord.isValid == functionKeys.contains(code), "Only F1–F20 with supported modifiers may be recorded: \(code)/\(modifiers)")
            }
        }
        for modifiers: UInt32 in [0,16,24,0x80000008] {
            expect(!DisplayShortcut(keyCode: 120, modifiers: modifiers).isValid, "Bare F keys and unsupported modifier bits are rejected")
        }
        for (index, code) in functionKeys.enumerated() {
            let value = DisplayShortcut(keyCode: code, modifiers: 15)
            expect(value.displayName == "⌃⌥⇧⌘F\(index + 1)", "Function labels must be stable on every layout")
        }
        let chord = DisplayShortcut(keyCode: 120, modifiers: 8)
        expect(try JSONDecoder().decode(DisplayShortcut.self, from: JSONEncoder().encode(chord)) == chord, "Supported shortcut persists exactly")
        let oldLetter = try JSONDecoder().decode(DisplayShortcut.self, from: Data(#"{"keyCode":15,"modifiers":8}"#.utf8))
        expect(!oldLetter.isValid, "Old letter chords cannot enter native registration")
        print("Function-key shortcut checks: \(checks), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
