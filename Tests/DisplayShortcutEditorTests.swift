import AppKit

// Synthetic key events go directly to the editor handler. No event monitor,
// native hotkey registration or power operation runs.
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
            for key in ["Backlight shortcut", "Shortcut", "display.shortcut.firstUse", "display.shortcut.invalid", "Click here to record", "Assign Anyway", "display.shortcut.systemConflict",
                        "display.shortcut.systemWarningTitle", "display.shortcut.commonWarningTitle", "display.shortcut.commonWarning",
                        "display.shortcut.typingWarningTitle", "display.shortcut.typingWarningText", "display.shortcut.typingWarningComposition",
                        "Copy", "Capture Entire Screen"] {
                try expect(translations[key] != nil && localized(key) == translations[key], "Editor must use the packaged \(language) translation: \(key)")
            }
        }
        let initial = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control)
        var allowed = true
        var reject = false
        var conflictChecks = 0
        var saved: [DisplayShortcut?] = []
        var finishes = 0
        let editor = DisplayShortcutEditor(currentShortcut: initial, canEdit: { allowed }, checkConflict: { _ in
            conflictChecks += 1
            return reject ? .system : nil
        }, save: { shortcut, _ in saved.append(shortcut) }, finish: { _ in finishes += 1 })
        defer { editor.window.orderOut(nil) }
        let window = editor.window
        window.contentView!.layoutSubtreeIfNeeded()
        try expect(!window.isVisible, "Editor tests must stay offscreen")
        try expect(abs(window.contentLayoutRect.width - 540) < 1, "The shortcut editor uses the shared 540-point width")
        try expect(editor.valueLabel.stringValue == initial.displayName, "Editor shows the current shortcut")
        try expect(editor.valueLabel.font?.isEqual(AppStyle.Font.shortcutValue) == true &&
                   editor.hintLabel.font?.isEqual(AppStyle.Font.supportingText) == true &&
                   editor.saveButton.font?.isEqual(AppStyle.Font.controlLabel) == true, "Editor uses shared text roles")
        try expect(conflictChecks == 1, "The editor must check its initial draft for advisory conflicts")
        try expect(window.level == .normal, "The editor leaves its window level to its settings sheet")

        let initialFrame = window.frame
        let initialCaptureFrame = window.convertToScreen(editor.captureBox.convert(editor.captureBox.bounds, to: nil))
        let initialButtonFrame = window.convertToScreen(editor.saveButton.convert(editor.saveButton.bounds, to: nil))
        try expect(abs(initialCaptureFrame.minY - initialButtonFrame.maxY - 12) < 1,
                   "Without feedback the buttons sit 12 points below the capture field")
        try snapshot(editor, language: language, state: "current")
        window.makeFirstResponder(editor.cancelButton)
        let outside = event(key: 0, flags: [.command], window: window)
        try expect(editor.handleKeyDown(outside) === outside && editor.draft == initial && conflictChecks == 1,
                   "Keys over ordinary controls must retain native handling")
        try expect(window.makeFirstResponder(editor.captureBox), "Capture must accept focus")
        try expect(editor.captureBox.borderWidth == 2, "Focused recording control must be highlighted")
        func changeFlags(_ flags: NSEvent.ModifierFlags, key: UInt16 = 55, in target: NSWindow? = nil) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: (target ?? window).windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
            editor.captureBox.flagsChanged(with: event)
        }
        changeFlags([.shift], key: 56)
        try expect(editor.hintLabel.stringValue == localized("Press F1–F20."),
                   "With only Shift held, the hint must point to F-keys")
        changeFlags([.command])
        try expect(editor.valueLabel.stringValue == "⌘" && editor.draft == initial && !editor.saveButton.isEnabled,
                   "Holding Command must preview it without recording or allowing the previous draft to be saved")
        changeFlags([.command, .shift], key: 56)
        try expect(editor.valueLabel.stringValue == "⇧⌘" && conflictChecks == 1 && saved.isEmpty,
                   "Additional held modifiers must appear live without checking for saved-shortcut conflicts")
        try expect(editor.hintLabel.stringValue == localized("Press a letter, number or F1–F20."), "The next step must explain which keys can complete the chord")
        try snapshot(editor, language: language, state: "held-modifiers")
        changeFlags([.command], key: 56)
        try expect(editor.valueLabel.stringValue == "⌘", "Releasing one modifier must update the preview")
        changeFlags([])
        try expect(editor.valueLabel.stringValue == initial.displayName && editor.draft == initial && editor.saveButton.isEnabled,
                   "Releasing modifiers without completing a chord must preserve the previous draft")
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
                   "Shift alone with a letter must not replace the saved draft")
        try expect(!editor.feedback.label.stringValue.isEmpty && saved.isEmpty, "Invalid input shows feedback without saving")
        let invalidFrame = window.frame
        let invalidFeedback = editor.feedback.label.stringValue
        changeFlags([.command])
        try expect(window.frame == invalidFrame && editor.feedback.label.stringValue == invalidFeedback
                   && editor.valueLabel.stringValue == "⌘" && !editor.saveButton.isEnabled,
                   "Previewing a modifier only updates the capture field while an error remains visible")
        changeFlags([])
        try expect(!editor.saveButton.isEnabled, "A modifier preview alone must not clear a capture error")
        for unsupported in [event(key: 0, window: window),
                            event(key: 18, flags: [.shift], window: window),
                            event(key: 120, window: window), event(key: 55, flags: [.command], window: window)] {
            _ = editor.handleKeyDown(unsupported)
            try expect(editor.draft == initial && !editor.saveButton.isEnabled && conflictChecks == 1,
                       "Bare keys, Shift with a digit and modifier-only input cannot reach conflict detection")
        }
        reject = true
        _ = editor.handleKeyDown(event(key: 96, flags: [.command], window: window))
        let blocked = DisplayShortcut(keyCode: 96, modifiers: DisplayShortcut.command)
        try expect(editor.draft == blocked && !editor.saveButton.isEnabled && saved.isEmpty
            && editor.feedback.label.stringValue == localized("display.shortcut.systemConflict"),
            "A confirmed system conflict shows the recorded chord and blocks saving")
        let banner = try expectBanner(editor, tinted: .systemRed)
        window.contentView!.layoutSubtreeIfNeeded()
        let growth = window.frame.height - initialFrame.height
        let captureFrame = window.convertToScreen(editor.captureBox.convert(editor.captureBox.bounds, to: nil))
        let buttonFrame = window.convertToScreen(editor.saveButton.convert(editor.saveButton.bounds, to: nil))
        try expect(growth > 0 && captureFrame == initialCaptureFrame && window.frame.maxY == initialFrame.maxY
                   && abs(buttonFrame.maxY + growth - initialButtonFrame.maxY) < 1
                   && window.firstResponder === editor.captureBox,
                   "Feedback expands the window downwards and keeps capture position and focus")
        try snapshot(editor, language: language, state: "conflict")
        reject = false
        _ = editor.handleKeyDown(event(key: 18, flags: [.option], window: window))
        try expect(editor.draft?.displayName == "⌥1" && editor.saveButton.isEnabled,
                   "A modifier and a physical digit can be recorded")
        changeFlags([.command, .shift], key: 56)
        _ = editor.handleKeyDown(event(key: 0, flags: [.command, .shift], window: window))
        let replacement = DisplayShortcut(keyCode: 0, modifiers: DisplayShortcut.command | DisplayShortcut.shift)
        try expect(editor.draft == replacement && editor.valueLabel.stringValue == replacement.displayName && editor.saveButton.isEnabled,
                   "A valid focused chord becomes the visible draft")
        try expect(banner.isHidden && editor.feedback.label.stringValue.isEmpty && saved.isEmpty
                   && window.frame == initialFrame,
                   "Recording a valid chord restores the compact frame and stages the change until Save")
        changeFlags([.command], key: 56)
        try expect(editor.valueLabel.stringValue == replacement.displayName && editor.saveButton.isEnabled,
                   "Releasing modifiers after a letter must not overwrite the completed chord")
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
        let firstUse = DisplayShortcutEditor(currentShortcut: nil, canEdit: { true }, checkConflict: { _ in nil },
            save: { _, _ in }, requiresShortcut: true)
        defer { firstUse.window.orderOut(nil) }
        try expect(!firstUse.saveButton.isEnabled, "First-use setup must require the user to choose a shortcut")
        try snapshot(firstUse, language: language, state: "first-use")
        firstUse.savePressed()
        try expect(!firstUse.didFinish && !firstUse.savedSuccessfully, "An empty first-use editor cannot accept setup")
        firstUse.window.makeFirstResponder(firstUse.captureBox)
        try expect(firstUse.valueLabel.stringValue == localized("Hold a modifier"), "An empty focused recorder must describe the first step")
        try expect(firstUse.hintLabel.stringValue == localized("Letters and digits need Control, Option, or Command."),
                   "An empty recorder must explain the modifier requirement for letters and digits")
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
        let clearing = DisplayShortcutEditor(currentShortcut: initial, canEdit: { true }, checkConflict: { _ in nil }, save: { shortcut, _ in clearSaves.append(shortcut) })
        defer { clearing.window.orderOut(nil) }
        clearing.clearPressed()
        try expect(clearing.draft == nil && clearSaves.isEmpty, "Clear stages removal without changing the model")
        clearing.savePressed()
        try expect(clearSaves.count == 1 && clearSaves[0] == nil, "Saving a cleared draft removes the shortcut")
        let cancelling = DisplayShortcutEditor(currentShortcut: initial, canEdit: { true }, checkConflict: { _ in nil },
            save: { _, _ in throw WakecupError(message: "Cancel unexpectedly saved") })
        defer { cancelling.window.orderOut(nil) }
        cancelling.window.makeFirstResponder(cancelling.cancelButton)
        try expect(cancelling.handleKeyDown(event(key: 53, window: cancelling.window)) == nil && cancelling.didFinish,
                   "Escape cancels inside the editor even when recording is unfocused")
        try expect(!editor.window.isVisible && !clearing.window.isVisible && !cancelling.window.isVisible,
                   "All fixtures remain offscreen throughout the test")
        try checkWindowFocus(original: initial)
        try checkConflictConfirmation(language: language, original: initial)
        try checkTypingWarning()
        try checkVisibleFeedback()
        try checkConflictAppearingOnSave()
        try checkRegistrationCanBeRetried(original: initial)
        print("PASS: isolated shortcut editor focus, navigation, recording, validation, Save/Cancel/Clear and shared \(language) layout")
    }
    @MainActor private static func checkWindowFocus(original: DisplayShortcut) throws {
        var changes: [Bool] = []
        let editor = DisplayShortcutEditor(currentShortcut: original, canEdit: { true }, checkConflict: { _ in nil },
            save: { _, _ in throw WakecupError(message: "Focus changes unexpectedly saved the shortcut") },
            editingFocusChanged: { changes.append($0) })
        let window = editor.window
        let becameKey = Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        let resignedKey = Notification(name: NSWindow.didResignKeyNotification, object: window)
        editor.windowDidBecomeKey(becameKey)
        editor.windowDidBecomeKey(becameKey)
        window.makeFirstResponder(editor.captureBox)
        _ = editor.handleKeyDown(event(key: 122, flags: [.control], window: window))
        let draft = editor.draft
        try expect(draft != nil && draft != original, "The test must start with an unsaved shortcut")
        let modifier = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.option],
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        editor.captureBox.flagsChanged(with: modifier)
        try expect(editor.valueLabel.stringValue == "⌥", "The held modifier must be visible before switching windows")

        editor.windowDidResignKey(resignedKey)
        try expect(changes == [true, false] && editor.draft == draft
                   && editor.valueLabel.stringValue == draft?.displayName && editor.saveButton.isEnabled,
                   "Resigning key must clear held modifiers and preserve the unsaved shortcut")
        editor.windowDidBecomeKey(becameKey)
        window.makeFirstResponder(editor.cancelButton)
        try expect(changes == [true, false, true], "Tabbing between controls must keep the editor active")
        editor.cancelPressed()
        editor.windowDidResignKey(resignedKey)
        try expect(changes == [true, false, true, false], "Closing must release editing focus exactly once")
    }

    @MainActor private static func checkVisibleFeedback() throws {
        guard let screen = NSScreen.main else { throw CocoaError(.featureUnsupported) }
        let visibleFrame = screen.visibleFrame
        let editor = DisplayShortcutEditor(currentShortcut: nil, canEdit: { true },
            checkConflict: { _ in .typing(layout: "ABC", effect: .insertsText("™")) }, save: { _, _ in })
        let window = editor.window
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.setFrameOrigin(NSPoint(x: visibleFrame.midX - window.frame.width / 2, y: visibleFrame.minY + 8))
        window.makeFirstResponder(editor.captureBox)
        try expect(window.isVisible, "Feedback must be tested in a visible panel")
        let compactFrame = window.frame
        _ = editor.handleKeyDown(event(key: 19, flags: [.option], window: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.24))
        let button = window.convertToScreen(editor.saveButton.convert(editor.saveButton.bounds, to: nil))
        try expect(window.frame.height > compactFrame.height && visibleFrame.contains(button)
                   && editor.saveButton.isEnabled && window.firstResponder === editor.captureBox,
                   "Expanding a typing warning at the bottom of the screen must keep its action visible")
    }

    @MainActor private static func checkTypingWarning() throws {
        let longLayout = "Malayalam – Transliteration (Extended Latin and Malayalam)"
        let shortcut = DisplayShortcut(keyCode: 19, modifiers: DisplayShortcut.option)
        let cases: [(String, DisplayShortcutConflict.TypingEffect, String)] = [
            ("ABC", .insertsText("™"), localizedFormat("display.shortcut.typingWarningText", "ABC", "™")),
            ("ABC", .startsComposition, localizedFormat("display.shortcut.typingWarningComposition", "ABC")),
            (longLayout, .startsComposition, localizedFormat("display.shortcut.typingWarningComposition", longLayout))
        ]
        for (layout, effect, detail) in cases {
            var saved: DisplayShortcut?
            let editor = DisplayShortcutEditor(currentShortcut: nil, canEdit: { true },
                checkConflict: { _ in .typing(layout: layout, effect: effect) }, save: { shortcut, _ in saved = shortcut })
            let window = editor.window
            defer { window.orderOut(nil) }
            window.makeFirstResponder(editor.captureBox)
            _ = editor.handleKeyDown(event(key: UInt16(shortcut.keyCode), flags: [.option], window: window))
            try expect(editor.feedback.label.stringValue == localized("display.shortcut.typingWarningTitle") + "\n" + detail,
                       "Typing warnings must describe the effect in the active layout")
            _ = try expectBanner(editor, tinted: .systemOrange)
            window.contentView!.layoutSubtreeIfNeeded()
            if layout == longLayout {
                let label = editor.feedback.label
                let text = label.attributedStringValue
                let detailRange = (text.string as NSString).range(of: detail)
                let width = label.bounds.width - 4
                let wrapped = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading])
                try expect(text.attributedSubstring(from: detailRange).size().width > width && wrapped.height > 40,
                           "The long warning fixture must need three lines")
                try expect(label.bounds.height + 1 >= wrapped.height,
                           "The long warning must lay out all three lines without clipping")
            }
            try expect(editor.saveButton.isEnabled && editor.saveButton.title == localized("Assign Anyway")
                       && editor.saveButton.keyEquivalent.isEmpty,
                       "A typing warning requires the explicit assignment button")
            _ = editor.handleKeyDown(event(key: 36, window: window))
            try expect(saved == nil && !editor.didFinish, "Return must not accept a typing warning")
            editor.savePressed()
            try expect(saved == shortcut && editor.didFinish, "Explicit confirmation accepts the warning")
        }
    }

    @MainActor private static func checkConflictConfirmation(language: String, original: DisplayShortcut) throws {
        let warned = DisplayShortcut(keyCode: 8, modifiers: DisplayShortcut.command)
        var committed = original
        var conflict: DisplayShortcutConflict? = .commonCommand("Copy")
        var registrationFails = true
        var attempts = 0
        var completions = 0
        let editor = DisplayShortcutEditor(currentShortcut: original, canEdit: { true },
            checkConflict: { $0 == warned ? conflict : nil },
            save: { value, reviewed in
                let current = value == warned ? conflict : nil
                guard current == reviewed else { throw DisplayShortcutReviewRequired(conflict: current) }
                attempts += 1
                if registrationFails { throw DisplayHotKeyError.conflict }
                committed = value!
            }, finish: { _ in completions += 1 })
        defer { editor.window.orderOut(nil) }
        let window = editor.window
        window.makeFirstResponder(editor.captureBox)
        _ = editor.handleKeyDown(event(key: UInt16(warned.keyCode), flags: [.command], window: window))
        try expect(editor.draft == warned && editor.feedback.label.stringValue.contains(localized("Copy"))
            && editor.saveButton.isEnabled && editor.saveButton.title == localized("Assign Anyway")
            && editor.saveButton.keyEquivalent.isEmpty && attempts == 0,
            "A common command must be shown inline and require an explicit assignment")
        _ = try expectBanner(editor, tinted: .systemOrange)
        try expect(editor.feedback.label.stringValue.split(separator: "\n").count == 2,
                   "The advisory displays a heading and separate command detail")
        try snapshot(editor, language: language, state: "warning")
        _ = editor.handleKeyDown(event(key: 36, window: window))
        try expect(attempts == 0 && !editor.didFinish, "Return must not confirm an advisory conflict")

        conflict = .documentedSystemCommand("Capture Entire Screen")
        editor.savePressed()
        try expect(attempts == 0 && editor.feedback.label.stringValue.contains(localized("Capture Entire Screen"))
            && editor.saveButton.title == localized("Assign Anyway") && editor.saveButton.keyEquivalent.isEmpty,
            "A changed warning must be shown before accepting a fresh confirmation")
        editor.savePressed()
        try expect(attempts == 1 && committed == original && editor.draft == warned && !editor.didFinish
            && editor.feedback.label.stringValue == localized("display.shortcut.conflict")
            && !editor.saveButton.isEnabled && editor.saveButton.title == localized("Save"),
            "A confirmed registration conflict blocks the rejected draft and preserves the old assignment")
        editor.savePressed()
        let modifier = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.command],
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        editor.captureBox.flagsChanged(with: modifier)
        window.makeFirstResponder(editor.cancelButton)
        try expect(attempts == 1 && !editor.saveButton.isEnabled,
                   "Retry or a modifier preview alone cannot accept a rejected shortcut")
        window.makeFirstResponder(editor.captureBox)
        _ = try expectBanner(editor, tinted: .systemRed)
        try snapshot(editor, language: language, state: "registration-error")
        registrationFails = false
        let safe = DisplayShortcut(keyCode: 97, modifiers: DisplayShortcut.control | DisplayShortcut.option)
        _ = editor.handleKeyDown(event(key: UInt16(safe.keyCode), flags: [.control, .option], window: window))
        try expect(editor.feedback.label.stringValue.isEmpty && editor.saveButton.title == localized("Save")
            && editor.saveButton.keyEquivalent == "\r", "A safe replacement must clear the warning and restore default Save")
        _ = editor.handleKeyDown(event(key: 36, window: window, isRepeat: true))
        try expect(attempts == 1, "An autorepeated Return must never save a shortcut")
        _ = editor.handleKeyDown(event(key: 36, window: window))
        editor.savePressed()
        try expect(attempts == 2 && committed == safe && completions == 1,
                   "Default Save must commit a safe shortcut exactly once")
    }

    @MainActor private static func checkConflictAppearingOnSave() throws {
        let initial = DisplayShortcut(keyCode: 8, modifiers: DisplayShortcut.command)
        var conflict: DisplayShortcutConflict? = .commonCommand("Copy")
        var saved = false
        let editor = DisplayShortcutEditor(currentShortcut: initial, canEdit: { true },
            checkConflict: { _ in conflict }, save: { _, reviewed in
                guard conflict == reviewed else { throw DisplayShortcutReviewRequired(conflict: conflict) }
                saved = true
            })
        defer { editor.window.orderOut(nil) }
        try expect(editor.saveButton.title == localized("Assign Anyway") && editor.saveButton.keyEquivalent.isEmpty,
                   "The current shortcut must show an advisory conflict when the editor opens")
        conflict = .system
        editor.savePressed()
        try expect(!saved && !editor.saveButton.isEnabled
            && editor.feedback.label.stringValue == localized("display.shortcut.systemConflict"),
            "A system conflict appearing before Save must block registration even after a warning was confirmed")
    }

    @MainActor private static func checkRegistrationCanBeRetried(original: DisplayShortcut) throws {
        var attempts = 0
        let editor = DisplayShortcutEditor(currentShortcut: original, canEdit: { true },
            checkConflict: { _ in nil }, save: { _, _ in
                attempts += 1
                if attempts == 1 { throw DisplayHotKeyError.unavailable }
            })
        defer { editor.window.orderOut(nil) }
        editor.window.makeFirstResponder(editor.cancelButton)
        editor.savePressed()
        try expect(attempts == 1 && editor.saveButton.isEnabled && !editor.didFinish,
                   "A transient registration failure must allow a deliberate retry")
        let repeatReturn = event(key: 36, window: editor.window, isRepeat: true)
        try expect(editor.handleKeyDown(repeatReturn) == nil && attempts == 1,
                   "Holding Return must not retry registration when focus is on another control")
        editor.savePressed()
        try expect(attempts == 2 && editor.savedSuccessfully, "Registration can succeed on an explicit retry")
    }

    @MainActor @discardableResult private static func expectBanner(
        _ editor: DisplayShortcutEditor, tinted color: NSColor
    ) throws -> NSBox {
        var ancestor = editor.feedback.label.superview
        while let view = ancestor, !(view is NSBox) { ancestor = view.superview }
        guard let banner = ancestor as? NSBox else {
            throw WakecupError(message: "Feedback must be inside its own inline banner")
        }
        let icon = banner.contentView?.subviews.compactMap { $0 as? NSImageView }.first
        try expect(!banner.isHidden && banner.fillColor == color.withAlphaComponent(0.10)
            && icon?.contentTintColor == color && icon?.image != nil,
            "A visible feedback banner needs a symbol and background for its severity")
        try expect(editor.feedback.label.toolTip == editor.feedback.label.stringValue,
                   "The complete feedback must be available in the tooltip")
        return banner
    }

    @MainActor private static func snapshot(_ editor: DisplayShortcutEditor, language: String, state: String) throws {
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
    private static func event(key: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: key)!
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
}
