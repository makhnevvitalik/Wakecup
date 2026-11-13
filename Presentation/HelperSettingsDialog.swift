import AppKit

// An explicit layout keeps permission choices in one row, independent of
// NSAlert's automatic decision to stack buttons vertically.
final class HelperSettingsDialog: NSObject, NSWindowDelegate {
    let window: NSPanel
    let buttons: [NSButton]
    let modeLabel: NSTextField
    private let completion: (NSApplication.ModalResponse) -> Void

    init(alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.completion = completion
        let width = AppStyle.HelperDialogLayout.width
        let inset = AppStyle.Layout.windowInset
        let textWidth = width - 2 * inset
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = alert.messageText
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.collectionBehavior = [.moveToActiveSpace]

        let icon = NSImageView(image: alert.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: AppStyle.HelperDialogLayout.iconSize),
            icon.heightAnchor.constraint(equalToConstant: AppStyle.HelperDialogLayout.iconSize)
        ])
        let title = NSTextField(labelWithString: alert.messageText)
        title.font = AppStyle.Font.appName
        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = AppStyle.HelperDialogLayout.spacing

        let explanation = Self.label(alert.informativeText, font: AppStyle.Font.body, width: textWidth)
        modeLabel = Self.label((alert.accessoryView as? NSTextField)?.stringValue ?? "",
            font: AppStyle.Font.supportingText, width: textWidth)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.identifier = NSUserInterfaceItemIdentifier("WakecupHelperPermissionMode")

        buttons = alert.buttons.enumerated().map { index, original in
            let button = NSButton(title: original.title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.font = AppStyle.Font.controlLabel
            button.isEnabled = original.isEnabled
            button.keyEquivalent = index == 0 ? "\r" : original.keyEquivalent
            button.tag = index
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer] + buttons.reversed().map { $0 as NSView })
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = AppStyle.HelperDialogLayout.buttonSpacing

        // Diagnostics can be much longer than the normal explanation. Keep
        // the action row visible instead of allowing the panel offscreen.
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let reservedHeight = header.fittingSize.height + modeLabel.fittingSize.height
            + actions.fittingSize.height + 3 * AppStyle.HelperDialogLayout.spacing
            + AppStyle.Layout.windowTopInset + 3 * inset + chromeHeight
        let maximumTextHeight = max(40, min(AppStyle.HelperDialogLayout.maximumTextHeight, screenHeight - reservedHeight))
        var body: NSView = explanation
        if explanation.fittingSize.height > maximumTextHeight {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: textWidth, height: maximumTextHeight))
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            explanation.setFrameSize(explanation.fittingSize)
            scroll.documentView = explanation
            scroll.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: maximumTextHeight).isActive = true
            let top = explanation.isFlipped ? 0 : explanation.frame.height - maximumTextHeight
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            body = scroll
        }
        let stack = NSStackView(views: [header, body, modeLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AppStyle.HelperDialogLayout.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: AppStyle.Layout.windowTopInset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        super.init()
        window.delegate = self
        for button in buttons { button.target = self; button.action = #selector(selectAction(_:)) }
        content.layoutSubtreeIfNeeded()
    }

    static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let dialog = HelperSettingsDialog(alert: alert) { NSApp.stopModal(withCode: $0) }
        dialog.window.center()
        dialog.window.makeKeyAndOrderFront(nil)
        dialog.window.makeFirstResponder(nil)
        let response = NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return response
    }

    @objc private func selectAction(_ sender: NSButton) {
        completion(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        completion(.cancel)
        return true
    }

    private static func label(_ text: String, font: NSFont, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
            width: width, height: .greatestFiniteMagnitude)).height ?? font.pointSize
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.heightAnchor.constraint(equalToConstant: ceil(height)).isActive = true
        return field
    }
}
