import AppKit

// Synthetic key events go directly to the offscreen handler. No local/global
// monitor, native hotkey registration, power operation or desktop window runs.
@main struct DisplayShortcutEditorTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        let language = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "en"
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent(language + ".lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            let translations = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            for key in ["Restore brightness", "Restore brightness shortcut", "display.shortcut.explanation", "display.shortcut.firstUse", "display.shortcut.invalid", "Click here to record"] {
                try expect(translations[key] != nil && localized(key) == translations[key], "Editor must use the packaged \(language) translation: \(key)")
            }
        }
        let initial = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control)
        var allowed = true
        var reject = false
        var validations = 0
        var saved: [DisplayShortcut?] = []
        var finishes = 0
        let editor = DisplayShortcutEditor(currentShortcut: initial, canEdit: { allowed }, validate: { _ in
            validations += 1
            if reject { throw WakecupError(message: "display.shortcut.conflict") }
        }, save: { saved.append($0) }, finish: { finishes += 1 })
        defer { editor.window.orderOut(nil) }
        let window = editor.window
        window.contentView!.layoutSubtreeIfNeeded()
        try expect(!window.isVisible, "Editor tests must stay offscreen")
        try expect(abs(window.contentLayoutRect.width - AppStyle.HelperDialogLayout.width) < 1, "Editor uses shared dialog width")
        try expect(editor.valueLabel.stringValue == initial.displayName, "Editor shows the current shortcut")
        try expect(editor.valueLabel.font?.isEqual(AppStyle.Font.emphasizedBody) == true &&
                   editor.hintLabel.font?.isEqual(AppStyle.Font.supportingText) == true &&
                   editor.saveButton.font?.isEqual(AppStyle.Font.controlLabel) == true, "Editor uses shared text roles")
        try expect(validations == 0, "Constructing an offscreen editor must not validate a native registration")
        editor.prepareForPresentation(relativeTo: nil)
        try expect(window.level == .modalPanel,
                   "An editor uses the standard modal level when no owner exists")
        let menuOwner = NSPanel(contentRect: NSRect(x: 30, y: 30, width: 380, height: 500),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menuOwner.level = .popUpMenu
        editor.prepareForPresentation(relativeTo: menuOwner)
        try expect(window.level == .modalPanel,
                   "The hidden owner must not dictate the modal editor level")
        try expect(!window.isVisible && !menuOwner.isVisible,
                   "Window-order regression tests must remain offscreen")

        try snapshot(editor, language: language, state: "current")
        window.makeFirstResponder(editor.cancelButton)
        let outside = event(key: 0, flags: [.command], window: window)
        try expect(editor.handleKeyDown(outside) === outside && editor.draft == initial && validations == 0,
                   "Keys over ordinary controls must retain native handling")
        try expect(window.makeFirstResponder(editor.captureBox), "Capture must accept focus")
        try expect(editor.captureBox.borderWidth == 2, "Focused recording control must be highlighted")
        func changeFlags(_ flags: NSEvent.ModifierFlags, key: UInt16 = 55, in target: NSWindow? = nil) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: (target ?? window).windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
            editor.captureBox.flagsChanged(with: event)
        }
        changeFlags([.command])
        try expect(editor.valueLabel.stringValue == "⌘" && editor.draft == initial && !editor.saveButton.isEnabled,
                   "Holding Command must preview it without recording or allowing the previous draft to be saved")
        changeFlags([.command, .shift], key: 56)
        try expect(editor.valueLabel.stringValue == "⇧⌘" && validations == 0 && saved.isEmpty,
                   "Additional held modifiers must appear live without requesting native validation")
        try expect(editor.hintLabel.stringValue == localized("Press F1–F20."), "The next step must explain that an F-key is still needed")
        try snapshot(editor, language: language, state: "held-modifiers")
        changeFlags([.command], key: 56)
        try expect(editor.valueLabel.stringValue == "⌘", "Releasing one modifier must update the preview")
        changeFlags([])
        try expect(editor.valueLabel.stringValue == initial.displayName && editor.draft == initial && editor.saveButton.isEnabled,
                   "Releasing modifiers without an F-key must preserve the previous draft")
        changeFlags([.option], key: 58)
        window.makeFirstResponder(editor.cancelButton)
        try expect(editor.valueLabel.stringValue == initial.displayName && editor.saveButton.isEnabled,
                   "Losing capture focus must discard the transient preview")
        changeFlags([.control], key: 59)
        try expect(editor.valueLabel.stringValue == initial.displayName && editor.draft == initial,
                   "Modifier changes outside the capture field must be ignored")
        window.makeFirstResponder(editor.captureBox)
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { other.orderOut(nil) }
        changeFlags([.command], in: other)
        try expect(editor.valueLabel.stringValue == initial.displayName, "Other windows cannot change the preview")

        let tab = event(key: 48, window: window)
        try expect(editor.handleKeyDown(tab) === tab, "Tab must not record a shortcut")
        editor.captureBox.keyDown(with: tab)
        try expect(window.firstResponder !== editor.captureBox, "Tab must leave capture")
        try expect(editor.captureBox.borderWidth == 1, "Focus border must follow the actual recorder focus")
        window.makeFirstResponder(editor.captureBox)
        let previous = DisplayShortcutCaptureBox(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        window.contentView!.addSubview(previous)
        previous.nextKeyView = editor.captureBox
        let oldNext = editor.captureBox.nextKeyView
        editor.captureBox.nextKeyView = previous
        editor.captureBox.keyDown(with: event(key: 48, flags: [.shift], window: window))
        try expect(window.firstResponder === previous, "Shift+Tab must follow reverse key-view navigation")
        previous.removeFromSuperview()
        editor.captureBox.nextKeyView = oldNext
        window.makeFirstResponder(editor.captureBox)
        let foreign = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { foreign.orderOut(nil) }
        let foreignEvent = event(key: 0, flags: [.command], window: foreign)
        try expect(editor.handleKeyDown(foreignEvent) === foreignEvent && editor.draft == initial,
                   "Another window must never be captured")
        let invalid = event(key: 0, flags: [.shift], window: window)
        try expect(editor.handleKeyDown(invalid) == nil && editor.draft == initial && !editor.saveButton.isEnabled,
                   "A shortcut needs a modified F1–F20 key; invalid input must not replace the saved draft")
        try expect(!editor.errorLabel.stringValue.isEmpty && saved.isEmpty, "Invalid input shows feedback without saving")
        for unsupported in [event(key: 0, flags: [.command], window: window),
                            event(key: 120, window: window), event(key: 55, flags: [.command], window: window)] {
            _ = editor.handleKeyDown(unsupported)
            try expect(editor.draft == initial && !editor.saveButton.isEnabled && validations == 0,
                       "Letters, bare F keys and modifier-only input cannot reach registration")
        }
        reject = true
        _ = editor.handleKeyDown(event(key: 96, flags: [.command], window: window))
        try expect(editor.draft == initial && !editor.saveButton.isEnabled && saved.isEmpty,
                   "Native conflict validation leaves the prior shortcut untouched")
        try snapshot(editor, language: language, state: "conflict")
        reject = false
        changeFlags([.command, .shift], key: 56)
        _ = editor.handleKeyDown(event(key: 96, flags: [.command, .shift], window: window))
        let replacement = DisplayShortcut(keyCode: 96, modifiers: DisplayShortcut.command | DisplayShortcut.shift)
        try expect(editor.draft == replacement && editor.valueLabel.stringValue == replacement.displayName && editor.saveButton.isEnabled,
                   "A valid focused chord becomes the visible draft")
        try expect(editor.errorLabel.stringValue.isEmpty && saved.isEmpty, "Recording stages a change until Save")
        changeFlags([.command], key: 56)
        try expect(editor.valueLabel.stringValue == replacement.displayName && editor.saveButton.isEnabled,
                   "Releasing modifiers after an F-key must not overwrite the completed chord")
        changeFlags([])
        try expect(editor.valueLabel.stringValue == replacement.displayName && editor.draft == replacement,
                   "A completed chord must remain visible after all keys are released")

        try snapshot(editor, language: language, state: "recording")
        allowed = false
        editor.clearPressed(); editor.savePressed()
        try expect(editor.draft == replacement && saved.isEmpty, "Actual darkness must block edits and saving")
        allowed = true
        editor.savePressed()
        try expect(saved.count == 1 && saved[0] == replacement && finishes == 1, "Save commits exactly the valid draft")
        editor.cancelPressed()
        try expect(finishes == 1, "Finish must be idempotent")

        try expect(editor.savedSuccessfully, "Only a successful Save must report acceptance")
        let firstUse = DisplayShortcutEditor(currentShortcut: nil, canEdit: { true }, validate: { _ in },
            save: { _ in }, requiresShortcut: true)
        defer { firstUse.window.orderOut(nil) }
        try expect(!firstUse.saveButton.isEnabled, "First-use setup must require the user to choose a shortcut")
        try snapshot(firstUse, language: language, state: "first-use")
        firstUse.savePressed()
        try expect(!firstUse.didFinish && !firstUse.savedSuccessfully, "An empty first-use editor cannot accept setup")
        firstUse.window.makeFirstResponder(firstUse.captureBox)
        try expect(firstUse.valueLabel.stringValue == localized("Hold a modifier"), "An empty focused recorder must describe the first step")
        let firstUseFlags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.control],
            timestamp: 1, windowNumber: firstUse.window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        firstUse.captureBox.flagsChanged(with: firstUseFlags)
        try expect(firstUse.valueLabel.stringValue == "⌃" && firstUse.draft == nil && !firstUse.saveButton.isEnabled,
                   "The first modifier must remain a preview, never a modifier-only shortcut")
        _ = firstUse.handleKeyDown(event(key: 97, flags: [.control, .option], window: firstUse.window))
        try expect(firstUse.saveButton.isEnabled, "A valid chosen shortcut enables first-use Save")
        firstUse.clearPressed()
        try expect(!firstUse.saveButton.isEnabled, "Clearing first-use draft must disable Save again")
        firstUse.cancelPressed()
        try expect(firstUse.didFinish && !firstUse.savedSuccessfully, "Cancel cannot activate a waiting display mode")

        var clearSaves: [DisplayShortcut?] = []
        let clearing = DisplayShortcutEditor(currentShortcut: initial, canEdit: { true }, validate: { _ in }, save: { clearSaves.append($0) })
        defer { clearing.window.orderOut(nil) }
        clearing.clearPressed()
        try expect(clearing.draft == nil && clearSaves.isEmpty, "Clear stages removal without changing the model")
        clearing.savePressed()
        try expect(clearSaves.count == 1 && clearSaves[0] == nil, "Saving a cleared draft removes the shortcut")
        let cancelling = DisplayShortcutEditor(currentShortcut: initial, canEdit: { true }, validate: { _ in },
            save: { _ in throw WakecupError(message: "Cancel unexpectedly saved") })
        defer { cancelling.window.orderOut(nil) }
        cancelling.window.makeFirstResponder(cancelling.cancelButton)
        try expect(cancelling.handleKeyDown(event(key: 53, window: cancelling.window)) == nil && cancelling.didFinish,
                   "Escape cancels inside the editor even when recording is unfocused")
        try expect(!editor.window.isVisible && !clearing.window.isVisible && !cancelling.window.isVisible,
                   "All fixtures remain offscreen throughout the test")
        print("PASS: isolated shortcut editor focus, navigation, recording, validation, Save/Cancel/Clear and shared \(language) layout")
    }
    private static func snapshot(_ editor: DisplayShortcutEditor, language: String, state: String) throws {
        guard let view = editor.window.contentView else { throw WakecupError(message: "Missing editor content") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw WakecupError(message: "Could not render offscreen editor")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WakecupError(message: "Could not encode offscreen editor")
        }
        try png.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-shortcut-\(language)-\(state).png"))
    }
    private static func event(key: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
}
