import Foundation

/// Connects the helper settings actions to their dialogs.
struct HelperInteraction {
    struct Snapshot {
        let state: PrivilegedHelperController.State
        let selected: Bool
        let usesHelper: Bool
        let detail: String
        let allowInstallationChanges: Bool
    }
    enum Request {
        case settings(Snapshot)
        case explanation
        case confirmRemoval
        case failure(message: String, usesHelper: Bool, checking: Bool, remove: Bool,
                     state: PrivilegedHelperController.State)
    }
    enum Response { case primary, remove, close, confirm, cancel }

    var dismissPanel: () -> Void = {}
    var canChangeInstallation: () -> Bool = { true }
    var canSelectMode: () -> Bool = { true }
    let activate: () -> Void
    let present: (Request, @escaping (Response) -> Void) -> Void

    init(activate: @escaping () -> Void = {},
         present: @escaping (Request, @escaping (Response) -> Void) -> Void = { _, complete in complete(.cancel) }) {
        self.activate = activate
        self.present = present
    }

    func showSettings(for helper: PrivilegedHelperController, allowInstallationChanges: Bool = true) {
        guard !helper.working, canSelectMode() else { return }
        helper.refresh()
        let snapshot = Snapshot(state: helper.state, selected: helper.selected, usesHelper: helper.usesHelper,
            detail: helper.detail, allowInstallationChanges: allowInstallationChanges && canChangeInstallation())
        present(.settings(snapshot)) { [weak helper] response in
            guard let helper, !helper.working, self.canSelectMode() else { return }
            switch response {
            case .primary:
                helper.refresh()
                guard helper.state == snapshot.state else { return }
                if helper.state == .ready {
                    guard helper.selected == snapshot.selected else { return }
                    helper.select(!snapshot.selected)
                } else if snapshot.allowInstallationChanges {
                    self.install(helper, remove: false)
                }
            case .remove where snapshot.state != .missing && snapshot.allowInstallationChanges:
                self.changeInstallation(for: helper, remove: true)
            default: break
            }
        }
    }

    func showExplanation() {
        dismissPanel()
        activate()
        present(.explanation) { _ in }
    }

    func changeInstallation(for helper: PrivilegedHelperController, remove: Bool) {
        guard !helper.working, canChangeInstallation() else { return }
        helper.refresh()
        if remove {
            guard helper.installed else { return }
            present(.confirmRemoval) { [weak helper] response in
                guard response == .confirm, let helper, !helper.working, self.canChangeInstallation() else { return }
                helper.refresh()
                guard helper.installed else { return }
                self.install(helper, remove: true)
            }
        } else if helper.installed {
            install(helper, remove: false)
        } else {
            showSettings(for: helper)
        }
    }

    private func install(_ helper: PrivilegedHelperController, remove: Bool) {
        guard !helper.working, canChangeInstallation() else { return }
        dismissPanel()
        activate()
        _ = helper.requestInstallation(remove: remove) { [weak helper] message in
            guard let helper else { return }
            present(.failure(message: message, usesHelper: helper.usesHelper, checking: helper.checking,
                remove: remove, state: helper.state)) { _ in }
        }
    }
}
