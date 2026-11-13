import Foundation

enum HelperInstallationState { case missing, ready, updateRequired, unavailable }

/// Application requests express intent; only the composition root supplies live UI.
struct HelperInteraction {
    struct Snapshot {
        let state: HelperInstallationState
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

    let activate: () -> Void
    let present: (Request) -> Response

    init(activate: @escaping () -> Void = {}, present: @escaping (Request) -> Response = { _ in .cancel }) {
        self.activate = activate
        self.present = present
    }

    static let inert = HelperInteraction()
}
