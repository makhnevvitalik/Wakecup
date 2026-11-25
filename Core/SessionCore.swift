import Foundation

struct WakecupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProcessIdentity: Codable, Equatable {
    let pid: Int32
    let startedAtMicroseconds: UInt64

    func matches(_ other: ProcessIdentity?) -> Bool {
        other?.pid == pid && other?.startedAtMicroseconds == startedAtMicroseconds
    }
}

enum SessionDurationLimits {
    // Separate from the calendar selection window: the guardian validates elapsed time.
    static let maximumSeconds: TimeInterval = 999 * 60 * 60
}

enum ThermalStopLevel: String, Codable {
    case serious, critical

    func reached(by state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .critical: return true
        case .serious: return self == .serious
        default: return false
        }
    }
}

struct SessionConfiguration: Codable, Equatable {
    let id: String
    let parentPID: Int32
    let duration: TimeInterval?
    let powerMode: PowerMode
    let threshold: Int
    let closedLid: Bool
    let keepDisplayOn: Bool
    var parentIdentity: ProcessIdentity? = nil
    var absoluteDeadline: TimeInterval? = nil
    var thermalStopLevel: ThermalStopLevel? = nil
}

struct SessionLiveUpdate: Codable, Equatable {
    let revision: UInt64
    let powerMode: PowerMode
    let threshold: Int
    let deadline: TimeInterval?
}

struct SessionControl: Codable {
    var stop = false
    var update: SessionLiveUpdate? = nil
    var thermalStopLevel: ThermalStopLevel? = nil
    var thermalStopRequested: Bool? = nil
}

enum GuardianPhase: String, Codable {
    case preparing, arming, active, restoring, stopped, failed, unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    var isTerminal: Bool { self == .stopped || self == .failed }
    var expectsHeartbeat: Bool { self == .arming || self == .active || self == .restoring }
}

enum SessionStopCode: String, Codable {
    case requested, ownerExited, interrupted, invalidParameters, expired, powerRestriction, thermal, recovered, startupCancelled, unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }
}

struct SessionTermination: LocalizedError {
    let code: SessionStopCode
    let text: String
    var errorDescription: String? { text }

    static let requested = Self(code: .requested, text: "остановлено")
    static let ownerExited = Self(code: .ownerExited, text: "приложение закрыто")
    static let interrupted = Self(code: .interrupted, text: "защитный процесс завершён")
    static let invalidParameters = Self(code: .invalidParameters, text: "Некорректные параметры сеанса.")
    static let expired = Self(code: .expired, text: "время истекло")
    static let thermal = Self(code: .thermal, text: "Wakecup stopped because the Mac is too hot.")
    static let recovered = Self(code: .recovered, text: "сон восстановлен после прерванного сеанса")
    static let startupCancelled = Self(code: .startupCancelled, text: "запуск отменён")

    // Old guardians only persisted the reason text. Keep accepting those records.
    static func legacyCode(for text: String) -> SessionStopCode? {
        [requested, ownerExited, interrupted, invalidParameters, expired, thermal, recovered, startupCancelled]
            .first { $0.text == text }?.code
    }
}

struct SessionStatus: Codable {
    var phase: GuardianPhase
    var helperPID: Int32 = 0
    var helperIdentity: ProcessIdentity?
    // Monotonic time of the last phase change saved for recovery.
    var phaseChangedAt: TimeInterval?
    var deadline: TimeInterval?
    var reason = ""
    // Optional for existing records. Keep the old text for readers of older versions.
    var stopCode: SessionStopCode? = nil
    var ownsSleepChange = false
    var sleepRestored = true
    var bootID: String? = nil
    var settingsRevision: UInt64? = nil
    var settingsError: String? = nil
    var powerMode: PowerMode? = nil
    var threshold: Int? = nil

    var reasonCode: SessionStopCode? {
        stopCode ?? SessionTermination.legacyCode(for: reason)
    }

    var isPristine: Bool {
        phase == .preparing && helperPID == 0 && !ownsSleepChange && sleepRestored
    }

    mutating func setTermination(_ termination: SessionTermination) {
        stopCode = termination.code
        reason = termination.text
    }

    // Return whether the new settings need to be published.
    mutating func update(from monitor: SessionMonitor) -> Bool {
        let changed = settingsRevision != monitor.settingsRevision || settingsError != monitor.settingsError
            || powerMode != monitor.effectivePowerMode || threshold != monitor.effectiveThreshold
            || deadline != monitor.deadline
        settingsRevision = monitor.settingsRevision
        settingsError = monitor.settingsError
        powerMode = monitor.effectivePowerMode
        threshold = monitor.effectiveThreshold
        deadline = monitor.deadline
        return changed
    }

    static let responseTimeout: TimeInterval = 12

    func hasRecentActivity(at now: TimeInterval, lastSocketResponse: TimeInterval? = nil) -> Bool {
        let latest = max(lastSocketResponse ?? -.infinity, phaseChangedAt ?? -.infinity)
        return now.isFinite && latest.isFinite && now >= latest && now - latest < Self.responseTimeout
    }
}

struct SessionMonitor {
    var deadline: TimeInterval?
    private(set) var settingsRevision: UInt64 = 0
    private(set) var settingsError: String?
    private(set) var effectivePowerMode: PowerMode
    private(set) var effectiveThreshold: Int
    private let thermalStopLevel: ThermalStopLevel

    init(configuration: SessionConfiguration, now: TimeInterval) throws {
        guard UUID(uuidString: configuration.id) != nil, configuration.parentPID > 1,
              BatteryThreshold.range.contains(configuration.threshold), now.isFinite else {
            throw WakecupError(message: "Некорректные параметры сеанса.")
        }
        if let duration = configuration.duration {
            guard duration.isFinite, (1...SessionDurationLimits.maximumSeconds).contains(duration) else {
                throw WakecupError(message: "Длительность должна быть от 1 секунды до 999 часов.")
            }
        }
        if let absoluteDeadline = configuration.absoluteDeadline {
            guard absoluteDeadline.isFinite, absoluteDeadline > 0 else {
                throw WakecupError(message: "Некорректные параметры сеанса.")
            }
        }
        effectivePowerMode = configuration.powerMode
        effectiveThreshold = configuration.threshold
        thermalStopLevel = configuration.thermalStopLevel ?? .critical
        deadline = configuration.absoluteDeadline ?? configuration.duration.map { now + $0 }
    }

    func thermalTermination(control: SessionControl, thermalState: ProcessInfo.ThermalState) -> SessionTermination? {
        let stopLevel = control.thermalStopLevel ?? thermalStopLevel
        if control.thermalStopRequested == true || stopLevel.reached(by: thermalState) { return .thermal }
        return nil
    }

    mutating func step(now: TimeInterval, control: SessionControl, power: PowerState?, ownerAlive: Bool,
                       interrupted: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) -> SessionTermination? {
        if let thermal = thermalTermination(control: control, thermalState: thermalState) { return thermal }
        if control.stop { return .requested }
        if !ownerAlive { return .ownerExited }
        if interrupted { return .interrupted }
        guard now.isFinite else { return .invalidParameters }
        if let deadline, now >= deadline { return .expired }
        if let update = control.update, update.revision > settingsRevision {
            // A revision acknowledges processing, including a rejected payload.
            // Repeating or altering that payload cannot apply it a second time.
            settingsRevision = update.revision
            if !BatteryThreshold.range.contains(update.threshold) {
                settingsError = PowerRestriction.invalidThreshold.reason
            } else if let proposedDeadline = update.deadline,
                      !proposedDeadline.isFinite || proposedDeadline <= 0 || proposedDeadline > now + SessionDurationLimits.maximumSeconds {
                settingsError = "Длительность должна быть от 1 секунды до 999 часов."
            } else {
                deadline = update.deadline
                effectivePowerMode = update.powerMode
                effectiveThreshold = update.threshold
                settingsError = nil
            }
        }
        if let deadline, now >= deadline { return .expired }
        if let restriction = powerRestriction(power, mode: effectivePowerMode, threshold: effectiveThreshold) {
            return SessionTermination(code: .powerRestriction, text: restriction.reason)
        }
        return nil
    }
}
