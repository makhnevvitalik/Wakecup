import AppKit

/// Owns all helper dialog content, native controls and modal response mapping.
struct HelperPresentation {
    let activate: () -> Void
    let presentAlert: (NSAlert) -> NSApplication.ModalResponse
    let presentSettings: (NSAlert) -> NSApplication.ModalResponse

    static let system = HelperPresentation(
        activate: { NSApp.activate(ignoringOtherApps: true) },
        presentAlert: { $0.runModal() },
        presentSettings: HelperSettingsDialog.present)

    var interaction: HelperInteraction {
        HelperInteraction(activate: activate, present: present)
    }

    func present(_ request: HelperInteraction.Request) -> HelperInteraction.Response {
        let alert = Self.makeAlert(for: request)
        switch request {
        case .settings(let snapshot):
            let response = presentSettings(alert)
            if response == .alertFirstButtonReturn { return .primary }
            if snapshot.state != .missing && response == .alertSecondButtonReturn { return .remove }
            return .close
        case .confirmRemoval:
            return presentAlert(alert) == .alertFirstButtonReturn ? .confirm : .cancel
        case .explanation, .failure:
            _ = presentAlert(alert)
            return .close
        }
    }

    static func makeAlert(for request: HelperInteraction.Request) -> NSAlert {
        let alert = NSAlert()
        switch request {
        case .settings(let snapshot):
            alert.messageText = localized("Wakecup helper")
            alert.informativeText = localized("helper.explanation")
            if snapshot.state == .unavailable, !snapshot.detail.isEmpty {
                alert.informativeText += "\n\n" + SessionMessage(reason: snapshot.detail).text(using: localized)
            }
            let installed = snapshot.state != .missing
            let needsInstallation = snapshot.state != .ready
            let primaryTitle = !installed ? "Install helper" : needsInstallation ? "Update helper"
                : snapshot.selected ? "Switch to password prompts" : "Use helper"
            alert.addButton(withTitle: localized(primaryTitle))
                .isEnabled = !needsInstallation || snapshot.allowInstallationChanges
            if installed { alert.addButton(withTitle: localized("Remove")).isEnabled = snapshot.allowInstallationChanges }
            alert.addButton(withTitle: localized("Close")).keyEquivalent = "\u{1b}"
            let mode = NSTextField(wrappingLabelWithString: localized(snapshot.usesHelper
                ? "Current mode: closed-lid operation without a password."
                : "Current mode: a password is required each time closed-lid mode is enabled."))
            mode.font = AppStyle.Font.body
            mode.textColor = .secondaryLabelColor
            mode.isSelectable = false
            mode.identifier = NSUserInterfaceItemIdentifier("WakecupHelperPermissionMode")
            alert.accessoryView = mode
        case .explanation:
            alert.messageText = localized("Why install a helper?")
            alert.informativeText = localized("helper.explanation")
            alert.addButton(withTitle: localized("Close"))
        case .confirmRemoval:
            alert.messageText = localized("Remove Wakecup helper?")
            alert.informativeText = localized("helper.remove.explanation")
            alert.addButton(withTitle: localized("Remove helper"))
            alert.addButton(withTitle: localized("Cancel"))
        case .failure(let message, let usesHelper, let checking):
            alert.alertStyle = .warning
            alert.messageText = localized("Could not change the Wakecup helper")
            alert.informativeText = localized(usesHelper && !checking ? "helper.failure.previous" : "helper.failure.explanation")
                + "\n\n" + SessionMessage(reason: message).text(using: localized)
            alert.addButton(withTitle: localized("OK"))
        }
        return alert
    }
}
