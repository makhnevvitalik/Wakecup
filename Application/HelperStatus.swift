struct HelperStatus: Equatable {
    enum State: String { case missing, ready, updateRequired, unavailable }

    let state: State
    let selected: Bool
    let working: Bool
    let checking: Bool
    let detail: String
    let installationError: String?
    let updateRequired: Bool

    var installed: Bool { state != .missing }
    var usesHelper: Bool { selected && state == .ready }
}
