import AppKit

// The only recorder is this focusable local control. Native buttons retain
// their ordinary key handling and no global keyboard observation is installed.
final class DisplayShortcutCaptureBox: NSBox {
    var focusDidChange: (() -> Void)?
    var modifiersDidChange: ((NSEvent.ModifierFlags) -> Void)?
    private(set) var hasKeyboardFocus = false
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasKeyboardFocus = true; focusDidChange?() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { hasKeyboardFocus = false; focusDidChange?() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if window?.firstResponder === self { modifiersDidChange?(event.modifierFlags) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func flagsChanged(with event: NSEvent) {
        guard event.window === window, window?.firstResponder === self else {
            super.flagsChanged(with: event); return
        }
        modifiersDidChange?(event.modifierFlags)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }
}

@MainActor final class DisplayShortcutEditor: NSObject, NSWindowDelegate {
    let window: NSPanel
    let captureBox = DisplayShortcutCaptureBox()
    let valueLabel = NSTextField(wrappingLabelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let feedback = ShortcutFeedbackLayout()
    let saveButton = NSButton(title: localized("Save"), target: nil, action: nil)
    let cancelButton = NSButton(title: localized("Cancel"), target: nil, action: nil)
    let clearButton = NSButton(title: localized("Clear"), target: nil, action: nil)
    private(set) var draft: DisplayShortcut?
    private(set) var didFinish = false
    private(set) var savedSuccessfully = false
    private let requiresShortcut: Bool
    private let canEdit: () -> Bool
    private let checkConflict: @MainActor (DisplayShortcut) -> DisplayShortcutConflict?
    private let save: (DisplayShortcut?, DisplayShortcutConflict?) throws -> Void
    private let editingFocusChanged: (Bool) -> Void
    private let finish: (Bool) -> Void
    private var hasEditingFocus = false
    private var eventMonitor: Any?
    private var heldModifiers: UInt32 = 0
    private var previewModifiers: UInt32 = 0
    private var captureError: String?
    private var displayedConflict: DisplayShortcutConflict?
    private var draftIsValid = true
    private var registrationConflict = false

    init(currentShortcut: DisplayShortcut?, canEdit: @escaping () -> Bool,
         checkConflict: @escaping @MainActor (DisplayShortcut) -> DisplayShortcutConflict?,
         save: @escaping (DisplayShortcut?, DisplayShortcutConflict?) throws -> Void, requiresShortcut: Bool = false,
         editingFocusChanged: @escaping (Bool) -> Void = { _ in },
         finish: @escaping (Bool) -> Void = { _ in }) {
        self.requiresShortcut = requiresShortcut
        self.draft = currentShortcut
        self.canEdit = canEdit
        self.checkConflict = checkConflict
        self.displayedConflict = currentShortcut.flatMap { checkConflict($0) }
        self.save = save
        self.editingFocusChanged = editingFocusChanged
        self.finish = finish
        let width = AppStyle.Layout.shortcutEditorWidth
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 310),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = localized("Backlight shortcut")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        let title = NSTextField(labelWithString: localized("Backlight shortcut"))
        title.font = AppStyle.Font.windowTitle
        let shortcutTitle = NSTextField(labelWithString: localized("Shortcut"))
        shortcutTitle.font = AppStyle.Font.emphasizedBody
        shortcutTitle.textColor = .secondaryLabelColor

        captureBox.boxType = .custom
        captureBox.titlePosition = .noTitle
        captureBox.fillColor = .controlBackgroundColor
        captureBox.cornerRadius = 9
        captureBox.contentViewMargins = .zero
        captureBox.focusDidChange = { [weak self] in self?.resetModifierPreview() }
        captureBox.modifiersDidChange = { [weak self] in self?.modifiersChanged($0) }
        captureBox.setAccessibilityLabel(localized("Backlight shortcut"))
        captureBox.identifier = NSUserInterfaceItemIdentifier("WakecupDisplayShortcutCapture")
        valueLabel.isSelectable = false
        valueLabel.lineBreakMode = .byWordWrapping
        valueLabel.preferredMaxLayoutWidth = width - 2 * AppStyle.Layout.windowInset - 24
        valueLabel.alignment = .center
        hintLabel.font = AppStyle.Font.supportingText
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        let captureContent = NSStackView(views: [valueLabel, hintLabel])
        captureContent.orientation = .vertical
        captureContent.alignment = .centerX
        captureContent.spacing = 5
        captureContent.translatesAutoresizingMaskIntoConstraints = false
        captureBox.contentView!.addSubview(captureContent)
        feedback.label.identifier = NSUserInterfaceItemIdentifier("WakecupDisplayShortcutError")
        for button in [clearButton, cancelButton, saveButton] {
            AppStyle.configureCompactButton(button)
            button.target = self
        }
        clearButton.action = #selector(clearPressed)
        cancelButton.action = #selector(cancelPressed)
        saveButton.action = #selector(savePressed)
        cancelButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clearButton, spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView(views: [title, shortcutTitle, captureBox, feedback.slot, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(5, after: shortcutTitle)
        stack.setCustomSpacing(0, after: captureBox)
        stack.setCustomSpacing(12, after: feedback.slot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: AppStyle.Layout.windowInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -AppStyle.Layout.windowInset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: AppStyle.Layout.windowTopInset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            captureBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captureBox.heightAnchor.constraint(equalToConstant: 66),
            captureContent.centerXAnchor.constraint(equalTo: captureBox.contentView!.centerXAnchor),
            captureContent.centerYAnchor.constraint(equalTo: captureBox.contentView!.centerYAnchor),
            captureContent.leadingAnchor.constraint(greaterThanOrEqualTo: captureBox.contentView!.leadingAnchor, constant: 12),
            captureContent.trailingAnchor.constraint(lessThanOrEqualTo: captureBox.contentView!.trailingAnchor, constant: -12),
            feedback.slot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = captureBox
        window.autorecalculatesKeyViewLoop = false
        captureBox.nextKeyView = clearButton
        clearButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = captureBox
        refresh()
        content.layoutSubtreeIfNeeded()
    }

    static func present(model: SessionModel, owner: NSWindow?, requiresShortcut: Bool,
                        completion: @escaping (Bool) -> Void) -> DisplayShortcutEditor {
        let editor = DisplayShortcutEditor(currentShortcut: model.displayShortcut,
            canEdit: { model.canChangeDisplayShortcut },
            checkConflict: { model.displayShortcutConflict(for: $0) },
            save: { _ = try model.setDisplayShortcut($0, reviewedConflict: $1) }, requiresShortcut: requiresShortcut,
            editingFocusChanged: { focused in
                if focused { model.beginDisplayShortcutEditing() }
                else { model.endDisplayShortcutEditing() }
            }, finish: completion)
        editor.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak editor] event in
            guard let editor, editor.hasEditingFocus else { return event }
            return editor.handleKeyDown(event)
        }
        if let owner {
            owner.beginSheet(editor.window) { response in
                editor.endPresentation(saved: response == .OK && editor.savedSuccessfully)
            }
        } else {
            editor.window.hidesOnDeactivate = false
            editor.window.center()
            editor.showWindow()
        }
        editor.window.makeFirstResponder(editor.captureBox)
        return editor
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !didFinish else { return }
        setEditingFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        setEditingFocus(false)
    }

    private func setEditingFocus(_ focused: Bool) {
        guard hasEditingFocus != focused else { return }
        hasEditingFocus = focused
        editingFocusChanged(focused)
        if !didFinish { resetModifierPreview() }
    }

    private func resetModifierPreview() {
        heldModifiers = 0
        previewModifiers = 0
        refresh()
    }

    // Kept separate from monitor installation so offscreen tests never capture
    // real keyboard input or register a system shortcut.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !didFinish, event.window === window else { return event }
        if event.keyCode == 53 { cancelPressed(); return nil }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 36, event.isARepeat, flags.isEmpty { return nil }
        guard window.firstResponder === captureBox else { return event }
        if event.keyCode == 48 { return event }
        if flags.isEmpty && [49, 123, 124, 125, 126].contains(event.keyCode) { return event }
        if event.keyCode == 36, flags.isEmpty {
            if saveButton.isEnabled, saveButton.keyEquivalent == "\r" { savePressed() }
            return nil
        }
        guard canEdit() else { showError(localized("display.shortcut.locked")); return nil }
        guard !event.isARepeat else { return nil }
        let modifiers = Self.shortcutModifiers(flags)
        heldModifiers = modifiers
        let candidate = DisplayShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard candidate.isValid else {
            draftIsValid = false
            showError(localized("display.shortcut.invalid"))
            return nil
        }
        draft = candidate
        displayedConflict = checkConflict(candidate)
        registrationConflict = false
        previewModifiers = 0
        draftIsValid = true
        captureError = nil
        refresh()
        return nil
    }

    @objc func clearPressed() {
        guard !didFinish else { return }
        guard canEdit() else { showError(localized("display.shortcut.locked")); return }
        draft = nil
        displayedConflict = nil
        registrationConflict = false
        heldModifiers = 0; previewModifiers = 0; captureError = nil; draftIsValid = true
        refresh()
    }
    @objc func savePressed() {
        guard !didFinish else { return }
        guard canEdit() else { showError(localized("display.shortcut.locked")); return }
        refresh()
        guard saveButton.isEnabled else { return }
        do {
            try save(draft, displayedConflict)
            savedSuccessfully = true
            complete()
        } catch let review as DisplayShortcutReviewRequired {
            displayedConflict = review.conflict
            captureError = nil
            refresh()
        } catch DisplayHotKeyError.conflict {
            registrationConflict = true
            captureError = nil
            refresh()
        } catch {
            showError(localized(error.localizedDescription))
        }
    }
    @objc func cancelPressed() { complete() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { complete(); return false }

    private func refresh() {
        let systemConflict = displayedConflict == .system
        let warning: (title: String, detail: String)?
        switch draftIsValid && !registrationConflict ? displayedConflict : nil {
        case .documentedSystemCommand(let command):
            warning = (localized("display.shortcut.systemWarningTitle"), localized(command))
        case .commonCommand(let command):
            warning = (localized("display.shortcut.commonWarningTitle"),
                       localizedFormat("display.shortcut.commonWarning", localized(command)))
        case .typing(let layout, let effect):
            let detail = switch effect {
            case .insertsText(let text):
                localizedFormat("display.shortcut.typingWarningText", layout, text)
            case .startsComposition:
                localizedFormat("display.shortcut.typingWarningComposition", layout)
            }
            warning = (localized("display.shortcut.typingWarningTitle"), detail)
        default:
            warning = nil
        }
        saveButton.isEnabled = !didFinish && canEdit() && previewModifiers == 0 && draftIsValid
            && !systemConflict && !registrationConflict && (!requiresShortcut || draft != nil)
        saveButton.title = localized(warning == nil ? "Save" : "Assign Anyway")
        saveButton.keyEquivalent = warning == nil ? "\r" : ""
        clearButton.isEnabled = !didFinish && canEdit() && draft != nil
        if let captureError {
            showFeedback(captureError)
        } else if registrationConflict {
            showFeedback(localized("display.shortcut.conflict"))
        } else if systemConflict {
            showFeedback(localized("display.shortcut.systemConflict"))
        } else if let warning {
            showFeedback(warning.title, detail: warning.detail, style: .warning)
        } else if requiresShortcut {
            showFeedback(localized("display.shortcut.firstUse"), style: .information)
        } else {
            feedback.hide()
        }
        refreshCapture()
    }

    private func showFeedback(_ title: String, detail: String? = nil, style: ShortcutFeedbackLayout.Style = .error) {
        feedback.show(title, detail: detail, style: style)
    }

    private func refreshCapture() {
        let focused = captureBox.hasKeyboardFocus
        captureBox.borderColor = focused ? .controlAccentColor : .separatorColor
        captureBox.borderWidth = focused ? 2 : 1
        let previewing = focused && previewModifiers != 0
        valueLabel.stringValue = previewing ? DisplayShortcut.modifierSymbols(for: previewModifiers)
            : draft?.displayName ?? localized(focused ? "Hold a modifier" : "Not configured")
        valueLabel.font = draft != nil || previewing ? AppStyle.Font.shortcutValue : AppStyle.Font.body
        let nextKey = previewModifiers == DisplayShortcut.shift ? "Press F1–F20." : "Press a letter, number or F1–F20."
        let hint = if !focused {
            "Click here to record"
        } else if previewing {
            nextKey
        } else if draft == nil {
            "Letters and digits need Control, Option, or Command."
        } else {
            "Hold a modifier, then press a key."
        }
        hintLabel.stringValue = localized(hint)
        captureBox.setAccessibilityValue(valueLabel.stringValue)
        captureBox.setAccessibilityHelp(hintLabel.stringValue)
    }
    private func showError(_ text: String) { captureError = text; refresh() }

    // Only the focused local control supplies flags; no keyboard access or
    // global observer is needed for this transient recording preview.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard !didFinish, canEdit(), window.firstResponder === captureBox else { return }
        let active = Self.shortcutModifiers(flags)
        let pressed = active & ~heldModifiers != 0
        heldModifiers = active
        if active == 0 { previewModifiers = 0 }
        else if pressed || previewModifiers != 0 {
            previewModifiers = active
        }
        refresh()
    }

    private static func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.shift) { modifiers |= DisplayShortcut.shift }
        if flags.contains(.control) { modifiers |= DisplayShortcut.control }
        if flags.contains(.option) { modifiers |= DisplayShortcut.option }
        if flags.contains(.command) { modifiers |= DisplayShortcut.command }
        return modifiers
    }
    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        if let owner = window.sheetParent {
            owner.endSheet(window, returnCode: savedSuccessfully ? .OK : .cancel)
        } else {
            endPresentation(saved: savedSuccessfully)
        }
    }

    private func endPresentation(saved: Bool) {
        didFinish = true
        setEditingFocus(false)
        removeMonitor()
        window.orderOut(nil)
        finish(saved)
    }

    private func removeMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }
}
