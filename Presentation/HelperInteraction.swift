import Foundation

/// Connects the helper settings actions to their dialogs.
struct HelperInteraction {
    struct Snapshot {
        let status: HelperStatus
        let allowInstallationChanges: Bool
    }
    enum Request {
        case settings(Snapshot, respond: (Response) -> Void)
        case explanation(returningTo: (() -> Void)?)
        case confirmRemoval(respond: (Response) -> Void)
        case failure(message: String, status: HelperStatus, remove: Bool)
    }
    enum Response { case primary, remove, close, confirm, cancel }

    var dismissPanel: () -> Void = {}
    var leaveForExplanation: () -> (() -> Void)? = { nil }
    let activate: () -> Void
    let present: (Request) -> Void

    init(activate: @escaping () -> Void = {}, present: @escaping (Request) -> Void = { _ in }) {
        self.activate = activate
        self.present = present
    }

    func showSettings(for model: SessionModel) {
        guard let status = model.prepareHelperSettings() else { return }
        showSettings(for: model, status: status)
    }

    private func showSettings(for model: SessionModel, status: HelperStatus) {
        let snapshot = Snapshot(status: status, allowInstallationChanges: model.canChangeHelper)
        present(.settings(snapshot, respond: { [weak model] response in
            guard let model else { return }
            switch response {
            case .primary:
                model.applyHelperSettings(expected: status, allowInstallationChanges: snapshot.allowInstallationChanges,
                    beforeAuthorization: self.beginAuthorization, onFailure: self.failureHandler(for: model, remove: false))
            case .remove where status.installed && snapshot.allowInstallationChanges:
                self.changeInstallation(for: model, remove: true)
            default: break
            }
        }))
    }

    func showExplanation() {
        let returnToSource = leaveForExplanation()
        activate()
        present(.explanation(returningTo: returnToSource))
    }

    func changeInstallation(for model: SessionModel, remove: Bool) {
        if remove {
            guard model.prepareHelperRemoval() else { return }
            present(.confirmRemoval(respond: { [weak model] response in
                guard response == .confirm, let model else { return }
                model.changeHelperInstallation(.remove, beforeAuthorization: self.beginAuthorization,
                    onFailure: self.failureHandler(for: model, remove: true))
            }))
        } else if let status = model.updateHelperOrPrepareSetup(beforeAuthorization: beginAuthorization,
                         onFailure: failureHandler(for: model, remove: false)) {
            showSettings(for: model, status: status)
        }
    }

    private func beginAuthorization() {
        dismissPanel()
        activate()
    }

    private func failureHandler(for model: SessionModel, remove: Bool) -> (String) -> Void {
        { [weak model] message in
            guard let status = model?.helperStatus else { return }
            present(.failure(message: message, status: status, remove: remove))
        }
    }
}
