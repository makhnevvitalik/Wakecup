import AppKit
import Combine

/// Presents helper actions on the settings window and keeps informational windows independent.
final class HelperPresentation {
    private let activate: () -> Void
    private let settingsOwner: () -> NSWindow?
    private let presentSettings: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private var explanation: HelperSettingsDialog?
    private var returnFromExplanation: (() -> Void)?
    private let failure = ModelessAlert()
    private var helperObservation: AnyCancellable?
    private var failureRecovery: (target: HelperStatus.State, initial: HelperStatus.State)?

    init(activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         settingsOwner: @escaping () -> NSWindow?,
         presentSettings: @escaping (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = HelperSettingsDialog.present) {
        self.activate = activate
        self.settingsOwner = settingsOwner
        self.presentSettings = presentSettings
    }

    var interaction: HelperInteraction {
        HelperInteraction(activate: activate, present: present)
    }

    func observeRecovery(of model: SessionModel) {
        helperObservation = model.helperStatuses.sink { [weak self] status in
            guard let self, let recovery = self.failureRecovery, !status.working, !status.checking else { return }
            let operationSucceeded = status.installationError == nil && (status.state == .ready || status.state == .missing)
            let stateRecovered = status.state == recovery.target && status.state != recovery.initial
            guard operationSucceeded || stateRecovered else { return }
            self.failure.close()
            self.failureRecovery = nil
        }
    }

    func present(_ request: HelperInteraction.Request) {
        let alert = Self.makeAlert(for: request)
        switch request {
        case .settings(let snapshot, let completion):
            guard let owner = settingsOwner() else { completion(.close); return }
            presentSettings(alert, owner) { response in
                if response == .alertFirstButtonReturn { completion(.primary) }
                else if snapshot.status.installed && response == .alertSecondButtonReturn { completion(.remove) }
                else { completion(.close) }
            }
        case .confirmRemoval(let completion):
            guard let owner = settingsOwner() else { completion(.cancel); return }
            alert.beginSheetModal(for: owner) { response in
                completion(response == .alertFirstButtonReturn ? .confirm : .cancel)
            }
        case let .explanation(returningTo):
            if let returningTo { returnFromExplanation = returningTo }
            if explanation?.window.isVisible != true {
                let dialog = HelperSettingsDialog(alert: alert, informational: true) { [weak self] _ in
                    let returnToSource = self?.returnFromExplanation
                    self?.returnFromExplanation = nil
                    returnToSource?()
                }
                dialog.window.center()
                explanation = dialog
            }
            if let window = explanation?.window {
                AppStyle.showWithoutInitialControlFocus(window)
            }
        case .failure(_, let status, let remove):
            failureRecovery = (remove ? .missing : .ready, status.state)
            failure.show(alert, makeKey: false)
        }
    }

    static func makeAlert(for request: HelperInteraction.Request) -> NSAlert {
        let alert = NSAlert()
        switch request {
        case .settings(let snapshot, _):
            let status = snapshot.status
            alert.messageText = localized("Wakecup helper")
            alert.informativeText = localized("helper.explanation")
            if status.state == .unavailable, !status.detail.isEmpty {
                alert.informativeText += "\n\n" + SessionMessage(reason: status.detail).text(using: localized)
            }
            let needsInstallation = status.state != .ready
            let primaryTitle = !status.installed ? "Install helper" : needsInstallation ? "Update helper"
                : status.selected ? "Switch to password prompts" : "Use helper"
            alert.addButton(withTitle: localized(primaryTitle))
                .isEnabled = !needsInstallation || snapshot.allowInstallationChanges
            if status.installed { alert.addButton(withTitle: localized("Remove")).isEnabled = snapshot.allowInstallationChanges }
            alert.addButton(withTitle: localized("Close")).keyEquivalent = "\u{1b}"
            let mode = NSTextField(wrappingLabelWithString: localized(status.usesHelper
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
            alert.addButton(withTitle: localized("Close")).keyEquivalent = "\u{1b}"
        case .confirmRemoval:
            alert.messageText = localized("Remove Wakecup helper?")
            alert.informativeText = localized("helper.remove.explanation")
            alert.addButton(withTitle: localized("Remove helper"))
            alert.addButton(withTitle: localized("Cancel"))
        case .failure(let message, let status, _):
            alert.alertStyle = .warning
            alert.messageText = localized("Could not change the Wakecup helper")
            alert.informativeText = localized(status.usesHelper && !status.checking ? "helper.failure.previous" : "helper.failure.explanation")
                + "\n\n" + SessionMessage(reason: message).text(using: localized)
            alert.addButton(withTitle: localized("OK"))
        }
        return alert
    }
}
