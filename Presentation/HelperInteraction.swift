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
        case failure(message: String, usesHelper: Bool, checking: Bool)
    }
    enum Response { case primary, remove, close, confirm, cancel }

    var dismissPanel: () -> Void = {}
    let activate: () -> Void
    let present: (Request) -> Response

    init(activate: @escaping () -> Void = {}, present: @escaping (Request) -> Response = { _ in .cancel }) {
        self.activate = activate
        self.present = present
    }

    func showSettings(for helper: PrivilegedHelperController, allowInstallationChanges: Bool = true) {
        guard !helper.working else { return }
        helper.refresh()
        let snapshot = Snapshot(state: helper.state, selected: helper.selected, usesHelper: helper.usesHelper,
            detail: helper.detail, allowInstallationChanges: allowInstallationChanges)
        switch show(.settings(snapshot)) {
        case .primary:
            if snapshot.state == .ready { helper.select(!snapshot.selected) }
            else if allowInstallationChanges { install(helper, remove: false) }
        case .remove:
            if snapshot.state != .missing && allowInstallationChanges { changeInstallation(for: helper, remove: true) }
        default: break
        }
    }

    func showExplanation() { _ = show(.explanation) }

    func changeInstallation(for helper: PrivilegedHelperController, remove: Bool) {
        guard !helper.working else { return }
        helper.refresh()
        if remove {
            guard show(.confirmRemoval) == .confirm else { return }
            install(helper, remove: true)
        } else if helper.installed {
            install(helper, remove: false)
        } else {
            showSettings(for: helper)
        }
    }

    private func show(_ request: Request) -> Response {
        dismissPanel()
        activate()
        return present(request)
    }

    private func install(_ helper: PrivilegedHelperController, remove: Bool) {
        dismissPanel()
        activate()
        _ = helper.requestInstallation(remove: remove) { [weak helper] message in
            guard let helper else { return }
            _ = show(.failure(message: message, usesHelper: helper.usesHelper, checking: helper.checking))
        }
    }
}
