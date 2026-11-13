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

final class DisplayShortcutEditor: NSObject, NSWindowDelegate {
    let window: NSPanel
    let captureBox = DisplayShortcutCaptureBox()
    let valueLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: localized("Save"), target: nil, action: nil)
    let cancelButton = NSButton(title: localized("Cancel"), target: nil, action: nil)
    let clearButton = NSButton(title: localized("Clear"), target: nil, action: nil)
    private(set) var draft: DisplayShortcut?
    private(set) var didFinish = false
    private(set) var savedSuccessfully = false
    private let currentShortcut: DisplayShortcut?
    private let currentLabel = NSTextField(labelWithString: "")
    private let requiresShortcut: Bool
    private let canEdit: () -> Bool
    private let validate: (DisplayShortcut) throws -> Void
    private let save: (DisplayShortcut?) throws -> Void
    private let finish: () -> Void
    private var eventMonitor: Any?
    private var heldModifiers: UInt32 = 0
    private var previewModifiers: UInt32 = 0
    private var captureError: String?
    private var draftIsValid = true

    init(currentShortcut: DisplayShortcut?, canEdit: @escaping () -> Bool,
         validate: @escaping (DisplayShortcut) throws -> Void,
         save: @escaping (DisplayShortcut?) throws -> Void, requiresShortcut: Bool = false,
         finish: @escaping () -> Void = {}) {
        self.currentShortcut = currentShortcut
        self.requiresShortcut = requiresShortcut
        self.draft = currentShortcut
        self.canEdit = canEdit
        self.validate = validate
        self.save = save
        self.finish = finish
        let width = AppStyle.HelperDialogLayout.width
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 310),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = localized("Restore brightness shortcut")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        let title = NSTextField(labelWithString: localized("Restore brightness"))
        title.font = AppStyle.Font.windowTitle
        let explanation = NSTextField(wrappingLabelWithString: localized(requiresShortcut ? "display.shortcut.firstUse" : "display.shortcut.explanation"))
        explanation.font = AppStyle.Font.body
        explanation.preferredMaxLayoutWidth = width - 2 * AppStyle.Layout.windowInset
        let current = currentLabel
        current.font = AppStyle.Font.supportingText
        current.textColor = .secondaryLabelColor
        current.lineBreakMode = .byTruncatingTail

        captureBox.boxType = .custom
        captureBox.titlePosition = .noTitle
        captureBox.fillColor = .controlBackgroundColor
        captureBox.cornerRadius = 9
        captureBox.focusDidChange = { [weak self] in
            guard let self else { return }
            self.heldModifiers = 0; self.previewModifiers = 0
            self.refresh()
        }
        captureBox.modifiersDidChange = { [weak self] in self?.modifiersChanged($0) }
        captureBox.setAccessibilityLabel(localized("Restore brightness shortcut"))
        captureBox.identifier = NSUserInterfaceItemIdentifier("WakecupDisplayShortcutCapture")
        valueLabel.font = AppStyle.Font.emphasizedBody
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
        errorLabel.font = AppStyle.Font.supportingText
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.preferredMaxLayoutWidth = width - 2 * AppStyle.Layout.windowInset
        errorLabel.identifier = NSUserInterfaceItemIdentifier("WakecupDisplayShortcutError")
        for button in [clearButton, cancelButton, saveButton] {
            button.bezelStyle = .rounded
            button.font = AppStyle.Font.controlLabel
            button.target = self
        }
        clearButton.action = #selector(clearPressed)
        cancelButton.action = #selector(cancelPressed)
        saveButton.action = #selector(savePressed)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [clearButton, spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView(views: [title, explanation, current, captureBox, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: AppStyle.Layout.windowInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -AppStyle.Layout.windowInset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: AppStyle.Layout.windowTopInset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -AppStyle.Layout.windowInset),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            current.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captureBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captureBox.heightAnchor.constraint(equalToConstant: 66),
            captureContent.centerXAnchor.constraint(equalTo: captureBox.contentView!.centerXAnchor),
            captureContent.centerYAnchor.constraint(equalTo: captureBox.contentView!.centerYAnchor),
            captureContent.leadingAnchor.constraint(greaterThanOrEqualTo: captureBox.contentView!.leadingAnchor, constant: 12),
            captureContent.trailingAnchor.constraint(lessThanOrEqualTo: captureBox.contentView!.trailingAnchor, constant: -12),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
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

    static func selectMode(_ mode: DisplayMode, model: SessionModel, configure: () -> Bool) {
        guard model.canEditSessionSettings else { return }
        if mode == .backlightOff && model.displayShortcut == nil {
            guard configure(), model.displayShortcut != nil else { return }
        }
        model.selectDisplayMode(mode)
    }

    @discardableResult static func present(model: SessionModel, owner: NSWindow?, requiresShortcut: Bool = false) -> Bool {
        guard model.canChangeDisplayShortcut, NSApp.modalWindow == nil else { return false }
        model.beginDisplayShortcutEditing()
        defer { model.endDisplayShortcutEditing() }
        let editor = DisplayShortcutEditor(currentShortcut: model.displayShortcut,
            canEdit: { model.canChangeDisplayShortcut }, validate: model.validateDisplayShortcut,
            save: model.setDisplayShortcut, requiresShortcut: requiresShortcut, finish: { NSApp.stopModal() })
        editor.prepareForPresentation(relativeTo: owner)
        editor.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak editor] event in
            guard let editor else { return event }
            return editor.handleKeyDown(event)
        }
        NSApp.activate()
        editor.window.makeKeyAndOrderFront(nil)
        editor.window.makeFirstResponder(editor.captureBox)
        NSApp.runModal(for: editor.window)
        editor.removeMonitor()
        editor.window.orderOut(nil)
        return editor.savedSuccessfully
    }

    func prepareForPresentation(relativeTo owner: NSWindow?) {
        refreshCapture()
        // The menu panel is hidden for the whole modal lifetime by its
        // controller. Use a standard modal level, independent of popup levels.
        window.level = .modalPanel
        if let owner {
            window.setFrameOrigin(NSPoint(x: owner.frame.midX - window.frame.width / 2,
                y: owner.frame.midY - window.frame.height / 2))
        } else { window.center() }
        window.setFrame(window.constrainFrameRect(window.frame, to: owner?.screen), display: false)
    }

    // Kept separate from monitor installation so offscreen tests never capture
    // real keyboard input or register a system shortcut.
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.keyCode == 53 { cancelPressed(); return nil }
        guard window.firstResponder === captureBox else { return event }
        if event.keyCode == 48 { return event }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if flags.isEmpty && [49, 123, 124, 125, 126].contains(event.keyCode) { return event }
        if event.keyCode == 36, flags.isEmpty {
            if saveButton.isEnabled { savePressed() }
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
        do {
            try validate(candidate)
            draft = candidate
            previewModifiers = 0
            draftIsValid = true
            captureError = nil
            refresh()
        } catch { draftIsValid = false; showError(localized(error.localizedDescription)) }
        return nil
    }

    @objc func clearPressed() {
        guard canEdit() else { showError(localized("display.shortcut.locked")); return }
        draft = nil
        heldModifiers = 0; previewModifiers = 0; captureError = nil; draftIsValid = true
        refresh()
    }
    @objc func savePressed() {
        guard !didFinish else { return }
        guard canEdit() else { showError(localized("display.shortcut.locked")); return }
        refresh()
        guard saveButton.isEnabled else { return }
        do {
            if let draft { try validate(draft) }
            try save(draft)
            savedSuccessfully = true
            complete()
        } catch { showError(localized(error.localizedDescription)) }
    }
    @objc func cancelPressed() { complete() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { complete(); return false }

    private func refresh() {
        saveButton.isEnabled = canEdit() && previewModifiers == 0 && draftIsValid && (!requiresShortcut || draft != nil)
        clearButton.isEnabled = canEdit() && draft != nil
        errorLabel.stringValue = captureError ?? ""
        refreshCapture()
    }

    private func refreshCapture() {
        currentLabel.stringValue = localizedFormat("Current shortcut: %@", currentShortcut?.displayName ?? localized("Not configured"))
        let focused = captureBox.hasKeyboardFocus
        captureBox.borderColor = focused ? .controlAccentColor : .separatorColor
        captureBox.borderWidth = focused ? 2 : 1
        let previewing = focused && previewModifiers != 0
        valueLabel.stringValue = previewing ? DisplayShortcut.modifierSymbols(for: previewModifiers)
            : draft?.displayName ?? localized(focused ? "Hold a modifier" : "Not configured")
        valueLabel.font = draft != nil || previewing ? AppStyle.Font.emphasizedBody : AppStyle.Font.body
        let hint = !focused ? "Click here to record" : previewing ? "Press F1–F20."
            : draft == nil ? "Then press F1–F20." : "Hold a modifier, then press F1–F20."
        hintLabel.stringValue = localized(hint)
        captureBox.setAccessibilityValue(valueLabel.stringValue)
        captureBox.setAccessibilityHelp(localized(previewing ? "Press F1–F20." : focused ? "Recording shortcut" : "Click here to record"))
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
            if pressed { captureError = nil; draftIsValid = true }
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
        removeMonitor()
        finish()
    }
    private func removeMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }
}
