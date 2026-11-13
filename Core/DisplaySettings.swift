import Foundation

enum DisplayMode: String {
    case mayTurnOff
    case keepOn
    case backlightOff

    var keepsDisplayOn: Bool { self != .mayTurnOff }
}

/// A modified F1–F20 key. Its name and meaning are independent of text layout.
struct DisplayShortcut: Codable, Equatable {
    static let shift: UInt32 = 1
    static let control: UInt32 = 2
    static let option: UInt32 = 4
    static let command: UInt32 = 8

    let keyCode: UInt32
    let modifiers: UInt32

    var isValid: Bool {
        let supported = Self.shift | Self.control | Self.option | Self.command
        return modifiers != 0 && modifiers & ~supported == 0 && functionNumber != nil
    }

    var modifierSymbols: String { Self.modifierSymbols(for: modifiers) }

    static func modifierSymbols(for modifiers: UInt32) -> String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }

    var functionNumber: Int? { Self.functionNumbers[keyCode] }
    var displayName: String { modifierSymbols + (functionNumber.map { "F\($0)" } ?? "?") }

    // macOS virtual keys, matching Lang Switcher's F1–F20 mapping.
    private static let functionNumbers: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]
}
