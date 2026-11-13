import AppKit
import SwiftUI

// Only offscreen native controls are edited. No assertions, authorizations,
// helper registrations or changes to the real app's preferences are possible.
@main struct DurationInputTests {
    @MainActor static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        NSTimeZone.default = TimeZone(identifier: "Asia/Yekaterinburg")!
        let suite = "WakecupEndTimeInput-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = Date(timeIntervalSince1970: 1_794_309_600)
        var operations = SessionOperations(now: { 1_000 }, readPower: { .init(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { _ in throw WakecupError(message: "Unexpected session start") },
            guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
            usesInstalledHelper: { false }, startHelper: { _, _, _ in },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}), scheduleTicks: { _ in {} })
        operations.wallNow = { base }
        let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) },
            requestInformation: { _ in }, interaction: .inert)
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        let host = NSHostingController(rootView: StopTimeCard(model: model).frame(width: 360))
        let window = WakecupPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.orderOut(nil) }
        settle()
        let field = descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "WakecupEndTime" }!
        let day = descendants(host.view).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "WakecupEndDay" }!
        model.selectEndTimePreset(0); settle()
        try expect(field.stringValue.isEmpty && day.title == localized("Indefinitely") && field.isEnabled, "Infinity must have a named menu choice and leave time editable")
        field.selectText(nil)
        let editor = window.fieldEditor(false, for: field) as! NSTextView
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)!
        let alternateKeyPosition = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 12)!
        try expect(window.performKeyEquivalent(with: alternateKeyPosition),
                   "Editing must follow the layout's A key rather than a fixed physical key position")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try expect(window.performKeyEquivalent(with: selectAll), "Command-A must reach the native editor in an accessory panel")
        editor.insertText("1", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle()
        try expect(editor.string == "1" && !model.durationInputIsValid, "A partial time must remain editable and cannot accidentally start infinity")
        for character in ["8", "3", "0"] {
            editor.insertText(character, replacementRange: editor.selectedRange()); settle()
        }
        try expect(editor.string == "18:30" && model.selectedEndDate == Date(timeIntervalSince1970: 1_794_317_400)
                   && model.durationInputIsValid, "Typing from infinity must select the exact time without normalization between keystrokes")
        window.makeFirstResponder(nil); settle()
        try expect(field.stringValue == "18:30", "Committed time must remain visible")
        field.selectText(nil)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        try expect(window.performKeyEquivalent(with: selectAll) && editor.selectedRange() == NSRange(location: 0, length: 5),
                   "Command-A must select the complete time for replacement")
        window.makeFirstResponder(nil); settle()
        day.item(at: 2)?.state = .on // A stale checkmark left by the native menu.
        day.selectItem(at: 1); day.sendAction(day.action, to: day.target); settle()
        try expect(day.itemArray.map(\.state) == [.off, .on, .off, .off],
                   "Changing the day must clear any old checkmarks")
        day.selectItem(at: day.numberOfItems - 1); day.sendAction(day.action, to: day.target)
        try expect(day.indexOfSelectedItem == 1 && day.itemArray.map(\.state) == [.off, .on, .off, .off],
                   "Opening the calendar must keep the selected day checked until a date is chosen")
        settle()
        try expect(model.selectedEndDate == Date(timeIntervalSince1970: 1_794_403_800), "Tomorrow must preserve the entered time on the next calendar day")
        field.selectText(nil)
        let activeEditor = window.fieldEditor(false, for: field) as! NSTextView
        activeEditor.insertText("0930", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count)); settle()
        try expect(activeEditor.string == "09:30" && activeEditor.selectedRange().location == 5, "Pasting four digits must add a colon and preserve the caret")
        activeEditor.insertText("18:30", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count)); settle()
        for invalid in ["-1:00", "abc", "123456", "24:00", "23:60"] {
            activeEditor.insertText(invalid, replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count)); settle()
            try expect(activeEditor.string == "18:30", "Malformed characters and excessive digits must be rejected by the native editor")
        }
        activeEditor.setSelectedRange(NSRange(location: 3, length: 2))
        activeEditor.insertText("45", replacementRange: activeEditor.selectedRange()); settle()
        try expect(activeEditor.string == "18:45" && model.durationInputIsValid, "Replacing selected minutes must preserve hours")
        activeEditor.setSelectedRange(NSRange(location: 3, length: 0)); activeEditor.deleteBackward(nil); settle()
        try expect(activeEditor.string == "1845", "Deleting the colon must not trap the caret")
        activeEditor.insertText(":", replacementRange: activeEditor.selectedRange()); settle()
        try expect(activeEditor.string == "18:45", "The separator must remain freely editable")
        activeEditor.insertText("1", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count)); settle()
        try expect(!model.durationInputIsValid && field.textColor == .labelColor, "Incomplete input must block starting without turning red during typing")
        activeEditor.insertText("18:", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count)); settle()
        let blankPoint = NSPoint(x: 4, y: 4)
        try expect(field.currentEditor() === activeEditor && !field.convert(field.bounds, to: nil).contains(blankPoint),
                   "The blank click must start outside the focused time field")
        let blankClick = NSEvent.mouseEvent(with: .leftMouseDown, location: blankPoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(blankClick); settle()
        try expect(field.currentEditor() == nil && !model.durationInputIsValid && field.textColor == .systemRed,
                   "Clicking outside an unfinished time must end editing and show validation")
        window.makeFirstResponder(nil)
        model.selectEndTimePreset(180); settle()
        try expect(field.stringValue == "19:20" && model.durationInputIsValid, "A quick preset must replace invalid input and fill the concrete endpoint")
        let stepper = descendants(host.view).compactMap { $0 as? NSStepper }.first!
        stepper.integerValue += 1
        stepper.sendAction(stepper.action, to: stepper.target); settle()
        try expect(model.selectedEndDate == base.addingTimeInterval(10_860), "The native stepper must add one minute to the selected time")
        let withSeconds = base.addingTimeInterval(10_823)
        model.selectEndDate(withSeconds); settle()
        field.selectText(nil); window.makeFirstResponder(nil); settle()
        try expect(model.selectedEndDate == withSeconds, "Merely focusing and leaving a field must not round the endpoint or change the selection")
        model.selectEndDate(base.addingTimeInterval(3 * 86400)); settle()
        guard day.item(withTitle: localized("Indefinitely")) != nil else {
            throw WakecupError(message: "The day menu must offer an explicit indefinite option")
        }
        day.selectItem(withTitle: localized("Indefinitely")); day.sendAction(day.action, to: day.target); settle()
        try expect(model.selectedEndDate == nil && field.stringValue.isEmpty && day.title == localized("Indefinitely"),
                   "Choosing Indefinitely must clear the endpoint and display its explicit name")
        field.selectText(nil)
        let emptyEditor = window.fieldEditor(false, for: field) as! NSTextView
        emptyEditor.insertText("0", replacementRange: NSRange(location: 0, length: emptyEditor.string.utf16.count)); settle()
        emptyEditor.selectAll(nil); emptyEditor.deleteBackward(nil); window.makeFirstResponder(nil); settle()
        try expect(model.durationInputIsValid && model.selectedEndDate == nil && field.stringValue.isEmpty,
                   "Clearing a partial edit in indefinite mode must leave indefinite mode usable")
        field.selectText(nil)
        let boundaryEditor = window.fieldEditor(false, for: field) as! NSTextView
        for (digits, formatted) in [("0000", "00:00"), ("2359", "23:59")] {
            boundaryEditor.insertText(digits, replacementRange: NSRange(location: 0, length: boundaryEditor.string.utf16.count)); settle()
            try expect(boundaryEditor.string == formatted, "The full 24-hour clock must be supported")
        }
        window.makeFirstResponder(nil)
        print("PASS: native time mask, insertion/paste/deletion/caret, clock bounds, deferred feedback, day changes and infinity")
    }
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WakecupError(message: message) }
    }
}
