import AppKit
import Combine

/// Presents helper actions on the settings window and keeps informational windows independent.
final class HelperPresentation {
    private let activate: () -> Void
    private let settingsOwner: () -> NSWindow?
    private let presentSettings: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let explanation = ModelessAlert()
    private let failure = ModelessAlert()
    private var helperObservation: AnyCancellable?
    private var failureRecovery: (target: PrivilegedHelperController.State, initial: PrivilegedHelperController.State)?

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

    func observeRecovery(of helper: PrivilegedHelperController) {
        helperObservation = helper.objectWillChange.sink { [weak self, weak helper] _ in
            DispatchQueue.main.async {
                guard let self, let helper, let recovery = self.failureRecovery,
                      !helper.working, !helper.checking else { return }
                let operationSucceeded = helper.installationError == nil && (helper.state == .ready || helper.state == .missing)
                let stateRecovered = helper.state == recovery.target && helper.state != recovery.initial
                guard operationSucceeded || stateRecovered else { return }
                self.failure.close()
                self.failureRecovery = nil
            }
        }
    }

    func present(_ request: HelperInteraction.Request, completion: @escaping (HelperInteraction.Response) -> Void) {
        let alert = Self.makeAlert(for: request)
        switch request {
        case .settings(let snapshot):
            guard let owner = settingsOwner() else { completion(.close); return }
            presentSettings(alert, owner) { response in
                if response == .alertFirstButtonReturn { completion(.primary) }
                else if snapshot.state != .missing && response == .alertSecondButtonReturn { completion(.remove) }
                else { completion(.close) }
            }
        case .confirmRemoval:
            guard let owner = settingsOwner() else { completion(.cancel); return }
            alert.beginSheetModal(for: owner) { response in
                completion(response == .alertFirstButtonReturn ? .confirm : .cancel)
            }
        case .explanation:
            explanation.show(alert)
            completion(.close)
        case .failure(_, _, _, let remove, let state):
            failureRecovery = (remove ? .missing : .ready, state)
            failure.show(alert, makeKey: false)
            completion(.close)
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
        case .failure(let message, let usesHelper, let checking, _, _):
            alert.alertStyle = .warning
            alert.messageText = localized("Could not change the Wakecup helper")
            alert.informativeText = localized(usesHelper && !checking ? "helper.failure.previous" : "helper.failure.explanation")
                + "\n\n" + SessionMessage(reason: message).text(using: localized)
            alert.addButton(withTitle: localized("OK"))
        }
        return alert
    }
}
