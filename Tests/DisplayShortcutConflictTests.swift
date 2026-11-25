// SPDX-FileCopyrightText: 2026 Vitalik Makhnev
// SPDX-License-Identifier: MIT AND LicenseRef-Commons-Clause-1.0

import Carbon
import Foundation

@main
struct DisplayShortcutConflictTests {
    static func main() throws {
        let command = DisplayShortcut.command
        let shift = DisplayShortcut.shift
        let control = DisplayShortcut.control
        let option = DisplayShortcut.option
        var count = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TestFailure(message: label) }
            count += 1
        }
        func conflict(_ key: Int, _ modifiers: UInt32, entries: [[String: Any]] = [],
                      layout: Data? = nil, fallback: Data? = nil, layoutName: String? = nil) -> DisplayShortcutConflict? {
            DisplayShortcutConflictDetector.conflict(for: shortcut(key, modifiers), entries: entries,
                layoutData: layout, fallbackLayoutData: fallback, layoutName: layoutName)
        }

        let copy = [entry(kVK_ANSI_C, cmdKey, enabled: true)]
        let disabledCopy = [entry(kVK_ANSI_C, cmdKey, enabled: false)]
        try expect(conflict(kVK_ANSI_C, command, entries: copy) == .system,
                   "An enabled symbolic chord takes precedence over Copy")
        try expect(conflict(kVK_ANSI_C, command, entries: disabledCopy + copy) == .system,
                   "Any enabled entry takes precedence over duplicate disabled entries")
        try expect(conflict(kVK_ANSI_C, command, entries: disabledCopy) == .commonCommand("Copy"),
                   "A disabled system entry does not suppress an application warning")
        try expect(conflict(kVK_ANSI_C, command, entries: [entry(kVK_ANSI_C, cmdKey | shiftKey, enabled: true)])
                   == .commonCommand("Copy"), "System matches require the whole modifier mask")
        let screenshot = [entry(kVK_ANSI_3, cmdKey | shiftKey, enabled: false)]
        try expect(conflict(kVK_ANSI_3, command | shift, entries: screenshot) == nil,
                   "Do not warn about a documented system default explicitly disabled in macOS")
        try expect(conflict(kVK_ANSI_3, command | shift) == .documentedSystemCommand("Capture Entire Screen"),
                   "Warn about a documented physical default without a matching system entry")
        try expect(conflict(kVK_F2, control) == .documentedSystemCommand("Focus Menu Bar"),
                   "Documented function shortcuts use their physical F-key")
        try expect(conflict(kVK_ANSI_Q, command | control) == .documentedSystemCommand("Lock Screen"),
                   "Documented character commands are checked before common application commands")
        try expect(conflict(kVK_ANSI_T, command | control | shift) == .commonCommand("Add Finder Item to Dock"),
                   "Finder commands preserve their exact modifier combination")
        try expect(conflict(kVK_ANSI_V, command | option | shift) == .commonCommand("Paste and Match Style"),
                   "Application warnings include multi-modifier editing commands")
        try expect(conflict(kVK_F11, 0) == nil && conflict(kVK_ANSI_C, shift) == nil,
                   "Only assignable Wakecup chords are classified")
        try expect(conflict(kVK_F20, command | option) == nil, "Unlisted assignable chords have no warning")
        try expect(registrationError(shortcut(kVK_ANSI_C, command), nil) == .unavailable,
                   "Registration still fails closed when the symbolic snapshot cannot be read")
        try expect(registrationError(shortcut(kVK_ANSI_C, command), copy) == .conflict,
                   "Registration rejects an enabled system chord")
        try expect(registrationError(shortcut(kVK_ANSI_C, command), disabledCopy) == nil,
                   "A disabled system chord remains available for exclusive registration")

        let dvorak = try keyboardLayout("Dvorak")
        try expect(conflict(kVK_ANSI_I, command, layout: dvorak) == .commonCommand("Copy"),
                   "The physical I key means Copy in Dvorak")
        try expect(conflict(kVK_ANSI_C, command, layout: dvorak) == .commonCommand("Show Finder View Options"),
                   "Common commands use Dvorak characters even though input labels remain US physical keys")
        try expect(conflict(kVK_ANSI_C, command, entries: copy, layout: dvorak) == .system,
                   "A live symbolic command still matches the physical key under Dvorak")
        try expect(conflict(kVK_ANSI_Z, command | shift, layout: dvorak) == .commonCommand("Spelling and Grammar"),
                   "Shift can be implicit in a translated punctuation key equivalent")
        try expect(conflict(kVK_ANSI_3, command | shift, layout: dvorak) == .documentedSystemCommand("Capture Entire Screen"),
                   "Physical screenshot defaults are independent of character translation")
        let french = try keyboardLayout("French")
        let us = try keyboardLayout("US")
        try expect(conflict(kVK_ANSI_2, command, layout: french, fallback: us) == nil,
                   "Do not replace an accented character with a US key from the fallback layout")
        try expect(conflict(kVK_ANSI_2, command, fallback: us) == .commonCommand("Finder List View"),
                   "An ASCII-capable keyboard layout is used when the active layout has no data")
        try expect(conflict(kVK_ANSI_2, command | shift, layout: french) == .commonCommand("Finder List View"),
                   "Shift can be implicit in translated digits on AZERTY")
        let russian = try keyboardLayout("Russian")
        try expect(conflict(kVK_ANSI_C, command, layout: russian) == .commonCommand("Copy"),
                   "The keyboard layout's Command mapping is used for non-Latin input")
        let abc = try keyboardLayout("ABC")
        try expect(conflict(kVK_ANSI_2, option, layout: abc, layoutName: "ABC")
                   == .typing(layout: "ABC", effect: .insertsText("™")),
                   "Option+2 must warn about intercepting the typed character in ABC")
        try expect(conflict(kVK_ANSI_E, option, layout: abc, layoutName: "ABC")
                   == .typing(layout: "ABC", effect: .startsComposition),
                   "Option+E must warn about intercepting dead-key composition in ABC")
        try expect(conflict(kVK_ANSI_2, option | shift, layout: abc, layoutName: "ABC")
                   == .typing(layout: "ABC", effect: .insertsText("€")),
                   "Option+Shift must use the shifted character from the active layout")
        try expect(conflict(kVK_ANSI_E, option, entries: [entry(kVK_ANSI_E, optionKey, enabled: true)],
                            layout: abc, layoutName: "ABC") == .system,
                   "An enabled system shortcut takes priority over a typing warning")
        try expect(conflict(kVK_ANSI_2, option | command, layout: abc, layoutName: "ABC") == nil,
                   "Adding Command changes the shortcut from ordinary input")
        try expect(conflict(kVK_ANSI_2, option, fallback: abc) == nil,
                   "Don't predict typed output from a fallback layout")
        let optionE = shortcut(kVK_ANSI_E, option)
        try expect(DisplayShortcutConflictDetector.conflict(for: optionE, entries: [],
                    enabledTypingLayouts: { [("ABC", abc)] }) == .typing(layout: "ABC", effect: .startsComposition),
                   "Warn when another enabled layout uses the shortcut for typing")
        var checkedOtherLayouts = false
        let currentConflict = DisplayShortcutConflictDetector.conflict(for: optionE, entries: [],
            layoutData: abc, layoutName: "ABC", enabledTypingLayouts: {
                checkedOtherLayouts = true
                return []
            })
        try expect(currentConflict == .typing(layout: "ABC", effect: .startsComposition) && !checkedOtherLayouts,
                   "A known typing conflict in the current layout takes priority")
        let systemLayouts = try keyboardLayoutsByAvailability()
        let warningLayouts = Set(DisplayShortcutConflictDetector.enabledKeyboardLayouts().map {
            Layout(name: $0.name, data: $0.data)
        })
        try expect(warningLayouts == systemLayouts.enabled,
                   "The warning uses exactly the layouts macOS has enabled for selection")
        if !systemLayouts.disabled.isEmpty {
            try expect(warningLayouts.isDisjoint(with: systemLayouts.disabled),
                       "The warning excludes installed but disabled keyboard layouts")
        }
        print("Display shortcut conflict checks: \(count), failures: 0")
    }

    private struct Layout: Hashable {
        let name: String
        let data: Data
    }

    private static func keyboardLayoutsByAvailability() throws -> (enabled: Set<Layout>, disabled: Set<Layout>) {
        guard let list = TISCreateInputSourceList(nil, true),
              let sources = (list.takeRetainedValue() as NSArray) as? [TISInputSource] else {
            throw TestFailure(message: "Could not read installed keyboard layouts")
        }
        var enabled: Set<Layout> = []
        var disabled: Set<Layout> = []
        for source in sources {
            func property(_ key: CFString) -> AnyObject? {
                TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
            }
            guard property(kTISPropertyInputSourceCategory) as? String == kTISCategoryKeyboardInputSource as String,
                  property(kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                  let name = property(kTISPropertyLocalizedName) as? String,
                  let data = property(kTISPropertyUnicodeKeyLayoutData) as? Data else { continue }
            let layout = Layout(name: name, data: data)
            if property(kTISPropertyInputSourceIsEnabled) as? Bool == true {
                enabled.insert(layout)
            } else {
                disabled.insert(layout)
            }
        }
        return (enabled, disabled.subtracting(enabled))
    }

    private static func shortcut(_ key: Int, _ modifiers: UInt32) -> DisplayShortcut {
        DisplayShortcut(keyCode: UInt32(key), modifiers: modifiers)
    }

    private static func entry(_ key: Int, _ modifiers: Int, enabled: Bool) -> [String: Any] {
        [kHISymbolicHotKeyCode as String: key,
         kHISymbolicHotKeyModifiers as String: modifiers,
         kHISymbolicHotKeyEnabled as String: enabled]
    }

    private static func keyboardLayout(_ name: String) throws -> Data {
        let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID as String: "com.apple.keylayout.\(name)"] as CFDictionary, true
        ).takeRetainedValue() as NSArray
        guard let first = sources.firstObject else {
            throw TestFailure(message: "The system keyboard layout \(name) is missing")
        }
        let source = first as! TISInputSource
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw TestFailure(message: "The system keyboard layout \(name) has no layout data")
        }
        return withExtendedLifetime(source) { Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data }
    }

    private static func registrationError(_ shortcut: DisplayShortcut, _ entries: [[String: Any]]?) -> DisplayHotKeyError? {
        do { try DisplaySymbolicHotKeys.requireUnreserved(shortcut, entries: entries); return nil }
        catch { return error as? DisplayHotKeyError }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
