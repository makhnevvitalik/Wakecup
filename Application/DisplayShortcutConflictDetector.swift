// SPDX-FileCopyrightText: 2026 Vitalik Makhnev
// SPDX-License-Identifier: MIT AND LicenseRef-Commons-Clause-1.0

import Carbon
import Foundation

// Adapted from Language Switcher Plus's TextShortcutConflictDetector.
enum DisplayShortcutConflict: Equatable {
    enum TypingEffect: Equatable {
        case insertsText(String)
        case startsComposition
    }

    case system
    case documentedSystemCommand(String)
    case commonCommand(String)
    case typing(layout: String, effect: TypingEffect)
}

struct DisplayShortcutReviewRequired: LocalizedError {
    let conflict: DisplayShortcutConflict?

    var errorDescription: String? {
        conflict == .system
            ? "This shortcut is already used by macOS."
            : "Open the Wakecup shortcut editor to review and confirm this shortcut."
    }
}

enum DisplayShortcutConflictDetector {
    @MainActor
    static func conflict(for shortcut: DisplayShortcut) -> DisplayShortcutConflict? {
        guard shortcut.isValid else { return nil }
        let entries = DisplaySymbolicHotKeys.snapshot() ?? []
        let activeSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let layout = layoutData(from: activeSource)
        let fallback = layout == nil
            ? layoutData(from: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()) : nil
        return conflict(for: shortcut, entries: entries, layoutData: layout,
                        fallbackLayoutData: fallback, layoutName: layoutName(from: activeSource),
                        enabledTypingLayouts: enabledKeyboardLayouts)
    }

    static func conflict(for shortcut: DisplayShortcut, entries: [[String: Any]],
                         layoutData: Data? = nil, fallbackLayoutData: Data? = nil,
                         layoutName: String? = nil,
                         enabledTypingLayouts: () -> [(name: String, data: Data)] = { [] }) -> DisplayShortcutConflict? {
        guard shortcut.isValid else { return nil }
        let systemMatch = DisplaySymbolicHotKeys.match(for: shortcut, entries: entries)
        if systemMatch == .enabled { return .system }

        if systemMatch == .unlisted {
            // Screenshots, accessibility and navigation defaults use physical keys.
            let physicalName = shortcut.functionNumber.map { "f\($0)" } ?? shortcut.alphanumericName?.lowercased()
            if let physicalName, let title = systemDefaults[shortcut.modifiers]?[physicalName] {
                return .documentedSystemCommand(title)
            }
        }
        let keys = commandKeys(for: shortcut, layout: layoutData ?? fallbackLayoutData)
        if systemMatch == .unlisted,
           let title = keys.lazy.compactMap({ systemCharacterCommands[$0.modifiers]?[$0.symbol] }).first {
            return .documentedSystemCommand(title)
        }
        if let title = keys.lazy.compactMap({ applicationCommands[$0.modifiers]?[$0.symbol] }).first {
            return .commonCommand(title)
        }
        guard shortcut.modifiers == option || shortcut.modifiers == (option | shift),
              shortcut.alphanumericName != nil, let keyCode = UInt16(exactly: shortcut.keyCode) else { return nil }
        let modifiers = shortcut.carbonModifiers
        if let layoutData, let layoutName,
           let warning = typingConflict(layoutName: layoutName, layoutData: layoutData,
                                        keyCode: keyCode, modifiers: modifiers) {
            return warning
        }
        return enabledTypingLayouts().lazy.compactMap { layout in
            typingConflict(layoutName: layout.name, layoutData: layout.data, keyCode: keyCode, modifiers: modifiers)
        }.first
    }

    static func enabledKeyboardLayouts() -> [(name: String, data: Data)] {
        let properties: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(properties as CFDictionary, false) else { return [] }
        let sources = list.takeRetainedValue() as NSArray
        return (sources as? [TISInputSource] ?? []).compactMap { source in
            guard let name = layoutName(from: source), let data = layoutData(from: source) else { return nil }
            return (name, data)
        }
    }

    private static func typingConflict(
        layoutName: String, layoutData: Data, keyCode: UInt16, modifiers: UInt32
    ) -> DisplayShortcutConflict? {
        guard let translation = translate(layoutData, keyCode: keyCode, modifiers: modifiers) else { return nil }
        if translation.isDeadKey { return .typing(layout: layoutName, effect: .startsComposition) }
        guard translation.text.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return .typing(layout: layoutName, effect: .insertsText(translation.text))
    }

    private static func commandKeys(for shortcut: DisplayShortcut, layout: Data?) -> [(modifiers: UInt32, symbol: String)] {
        guard let name = shortcut.alphanumericName, let keyCode = UInt16(exactly: shortcut.keyCode) else { return [] }
        guard let layout else { return [(shortcut.modifiers, name.lowercased())] }

        // Command can switch the layout's key map. Option and Control are
        // represented separately in menu key equivalents.
        let commandState = shortcut.modifiers & command != 0 ? UInt32(cmdKey) : 0
        let base = output(layout, keyCode: keyCode, modifiers: commandState)
        var keys: [(UInt32, String)] = []
        if shortcut.modifiers & shift != 0 {
            let shiftState = UInt32(shiftKey)
            var shifted = output(layout, keyCode: keyCode, modifiers: commandState | shiftState)
            // Some layouts ignore Shift in their Command map for punctuation.
            if commandState != 0, shifted == base, output(layout, keyCode: keyCode, modifiers: 0) == base {
                shifted = output(layout, keyCode: keyCode, modifiers: shiftState)
            }
            if let shifted, shifted != base, shifted.utf8.count == 1, let character = shifted.first,
               character.isPunctuation || character.isSymbol || character.isNumber {
                // A symbol such as '?' or an AZERTY digit already implies Shift.
                keys.append((shortcut.modifiers & ~shift, shifted))
            }
        }
        if let base, base.utf8.count == 1 { keys.append((shortcut.modifiers, base.lowercased())) }
        return keys
    }

    private static func layoutData(from source: TISInputSource?) -> Data? {
        guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return withExtendedLifetime(source) { Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data }
    }

    private static func layoutName(from source: TISInputSource?) -> String? {
        guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return withExtendedLifetime(source) { Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String }
    }

    private static func output(_ layout: Data, keyCode: UInt16, modifiers: UInt32) -> String? {
        guard let translation = translate(layout, keyCode: keyCode, modifiers: modifiers),
              !translation.isDeadKey, !translation.text.isEmpty else { return nil }
        return translation.text
    }

    private static func translate(_ layout: Data, keyCode: UInt16, modifiers: UInt32) -> (text: String, isDeadKey: Bool)? {
        layout.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<UCKeyboardLayout>.size, let base = bytes.baseAddress else { return nil }
            let keyLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(keyLayout, keyCode, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xff,
                UInt32(LMGetKbdType()), 0, &deadKey, characters.count, &length, &characters)
            guard status == noErr else { return nil }
            return (String(utf16CodeUnits: characters, count: length), deadKey != 0)
        }
    }

    private static let command = DisplayShortcut.command
    private static let shift = DisplayShortcut.shift
    private static let control = DisplayShortcut.control
    private static let option = DisplayShortcut.option

    // Keyboard combinations listed directly in Apple Support article 102650.
    // Symbols are included because some layouts place them on assignable physical keys.
    private static let applicationCommands: [UInt32: [String: String]] = [
        command: [
            "1": "Finder Icon View", "2": "Finder List View", "3": "Finder Column View", "4": "Finder Gallery View",
            "a": "Select All", "b": "Bold", "c": "Copy", "d": "Duplicate Files or Go to Desktop",
            "e": "Eject Disk", "f": "Find", "g": "Find Next", "h": "Hide App", "i": "Italic or Show File Info",
            "j": "Show Finder View Options", "k": "Insert Link or Connect to Server", "m": "Minimize Window",
            "n": "New Window or Document", "o": "Open", "p": "Print", "q": "Quit App", "r": "Refresh or Show Original",
            "s": "Save", "t": "New Tab, Fonts or Finder Tab Bar", "u": "Underline", "v": "Paste",
            "w": "Close Window", "x": "Cut", "y": "Quick Look", "z": "Undo",
            ",": "Open App Settings", "/": "Toggle Finder Status Bar", "[": "Previous Finder Folder",
            "]": "Next Finder Folder", ";": "Find Misspelled Words", ":": "Spelling and Grammar",
            "{": "Align Left", "}": "Align Right", "|": "Align Center",
            "=": "Increase Size", "+": "Increase Size", "?": "Open Help"
        ],
        command | shift: [
            "c": "Open Computer in Finder", "d": "Open Desktop", "f": "Open Recents",
            "g": "Find Previous or Go to Folder", "h": "Open Home Folder", "i": "Open iCloud Drive",
            "k": "Open Network", "n": "New Folder", "o": "Open Documents",
            "p": "Page Setup or Finder Preview", "r": "Open AirDrop", "s": "Save As or Duplicate",
            "t": "Toggle Finder Tab Bar", "u": "Open Utilities", "z": "Redo", "-": "Decrease Size"
        ],
        command | option: [
            "c": "Copy Style", "f": "Focus Search", "h": "Hide Other Apps", "i": "Toggle Inspector",
            "l": "Open Downloads", "m": "Minimize All Windows", "n": "New Smart Folder",
            "p": "Toggle Finder Path Bar", "s": "Toggle Finder Sidebar", "t": "Toggle Toolbar",
            "v": "Paste Style or Move Files", "w": "Close All Windows", "y": "Quick Look Slideshow"
        ],
        command | option | shift: ["v": "Paste and Match Style"],
        command | control: [
            "a": "Create Finder Alias", "d": "Look Up Word", "f": "Toggle Full Screen",
            "n": "New Folder With Selection", "t": "Add to Finder Sidebar"
        ],
        command | control | shift: ["t": "Add Finder Item to Dock"],
        control: [
            "a": "Move to Beginning of Line or Paragraph", "b": "Move One Character Backward",
            "d": "Delete Forward", "e": "Move to End of Line or Paragraph", "f": "Move One Character Forward",
            "h": "Delete Backward", "k": "Cut Selection or Text to End of Paragraph",
            "l": "Center Cursor or Selection in View", "n": "Move Down One Line", "o": "Insert Line After Cursor",
            "p": "Move Up One Line", "t": "Transpose Characters", "y": "Paste Text Cut With Control-K"
        ]
    ]

    private static let systemDefaults: [UInt32: [String: String]] = [
        command | shift: [
            "3": "Capture Entire Screen", "4": "Capture Screen Area",
            "5": "Open Screenshot Controls", "6": "Ask Siri About Screen Area"
        ],
        command | option: ["f5": "Open Accessibility Shortcuts"],
        command | control | option: ["8": "Invert Display Colors"],
        control: [
            "f2": "Focus Menu Bar", "f3": "Focus Dock", "f4": "Focus Window", "f5": "Focus Window Toolbar",
            "f6": "Focus Floating Window", "f7": "Toggle Full Keyboard Focus", "f8": "Focus Status Menus"
        ],
        control | shift: ["f6": "Focus Previous Panel"]
    ]

    private static let systemCharacterCommands: [UInt32: [String: String]] = [
        command: ["`": "Next App Window"],
        command | shift: ["q": "Log Out", "`": "Previous App Window"],
        command | control: ["q": "Lock Screen"],
        command | option: ["d": "Toggle Dock", "`": "Focus Window Drawer"],
        command | option | shift: ["q": "Log Out Without Confirmation"],
        command | control | option: [",": "Reduce Display Contrast", ".": "Increase Display Contrast"]
    ]
}
