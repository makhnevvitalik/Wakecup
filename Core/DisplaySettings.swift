import Foundation

enum DisplayMode: String, Codable {
    case mayTurnOff
    case keepOn
    case backlightOff

    var keepsDisplayOn: Bool { self != .mayTurnOff }
}

/// A modified physical key. Letter and digit labels use the US keyboard positions.
struct DisplayShortcut: Codable, Equatable {
    // Match Language Switcher's KeyModifiers representation.
    static let command: UInt32 = 1 << 0
    static let option: UInt32 = 1 << 1
    static let control: UInt32 = 1 << 2
    static let shift: UInt32 = 1 << 3

    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(functionNumber: Int, modifiers: UInt32) {
        guard let keyCode = Self.functionNumbers.first(where: { $0.value == functionNumber })?.key else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var isValid: Bool {
        let supported = Self.shift | Self.control | Self.option | Self.command
        guard modifiers != 0, modifiers & ~supported == 0 else { return false }
        if functionNumber != nil { return true }
        return modifiers != Self.shift && Self.alphanumericKeys[keyCode] != nil
    }

    var modifierSymbols: String { Self.modifierSymbols(for: modifiers) }

    static func modifierSymbols(for modifiers: UInt32) -> String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }

    var functionNumber: Int? { Self.functionNumbers[keyCode] }
    var alphanumericName: String? { Self.alphanumericKeys[keyCode] }
    var displayName: String {
        modifierSymbols + (functionNumber.map { "F\($0)" } ?? alphanumericName ?? "?")
    }

    private static let alphanumericKeys: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R",
        1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"
    ]

    // macOS virtual keys, matching Lang Switcher's F1–F20 mapping.
    private static let functionNumbers: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]
}

/// The original Wakecup representation used by old preferences and the automation wire format.
struct LegacyDisplayShortcut: Codable {
    private let keyCode: UInt32
    private let modifiers: UInt32

    private static let modifierFlags: [(legacy: UInt32, current: UInt32)] = [
        (1, DisplayShortcut.shift), (2, DisplayShortcut.control),
        (4, DisplayShortcut.option), (8, DisplayShortcut.command)
    ]

    init(_ shortcut: DisplayShortcut) {
        keyCode = shortcut.keyCode
        modifiers = Self.modifierFlags.reduce(0) { mask, flag in
            mask | (shortcut.modifiers & flag.current == 0 ? 0 : flag.legacy)
        }
    }

    var current: DisplayShortcut? {
        let supported = Self.modifierFlags.reduce(UInt32.zero) { $0 | $1.legacy }
        guard modifiers & ~supported == 0 else { return nil }
        let mask = Self.modifierFlags.reduce(UInt32.zero) { mask, flag in
            mask | (modifiers & flag.legacy == 0 ? 0 : flag.current)
        }
        let shortcut = DisplayShortcut(keyCode: keyCode, modifiers: mask)
        return shortcut.isValid ? shortcut : nil
    }
}
