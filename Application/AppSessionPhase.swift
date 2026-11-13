// UI lifecycle is separate from the guardian's serialized IPC status.
enum AppSessionPhase: String {
    case idle, authorizing, active, stopping, failed

    var isBusy: Bool {
        switch self {
        case .authorizing, .active, .stopping: return true
        case .idle, .failed: return false
        }
    }

    var showsProgress: Bool { self == .authorizing || self == .stopping }
}
