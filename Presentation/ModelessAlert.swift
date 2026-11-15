import AppKit

/// Keeps one ordinary window for an informational alert, independently of any settings window or sheet.
final class ModelessAlert: NSObject {
    private var alert: NSAlert?
    var window: NSWindow? { alert?.window }

    func show(_ content: NSAlert, makeKey: Bool = true) {
        if content.buttons.isEmpty { content.addButton(withTitle: localized("OK")) }
        if let alert, alert.window.isVisible {
            alert.messageText = content.messageText
            alert.informativeText = content.informativeText
            if let button = content.buttons.first { alert.buttons.first?.title = button.title }
            alert.layout()
        } else {
            alert = content
            content.layout()
            content.window.level = .normal
            content.window.isReleasedWhenClosed = false
            (content.window as? NSPanel)?.hidesOnDeactivate = false
            content.window.center()
        }
        guard let alert else { return }
        for button in alert.buttons {
            button.target = self
            button.action = #selector(dismiss)
        }
        if makeKey { alert.window.makeKeyAndOrderFront(nil) }
        else { alert.window.orderFront(nil) }
    }

    @objc private func dismiss() { close() }

    func close() {
        window?.close()
        alert = nil
    }
}
