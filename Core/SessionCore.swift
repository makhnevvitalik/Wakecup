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
}

struct SessionStatus: Codable {
    var phase: String
    var helperPID: Int32 = 0
    var helperIdentity: ProcessIdentity?
    // Monotonic time of the last phase change saved for recovery.
    var phaseChangedAt: TimeInterval?
    var deadline: TimeInterval?
    var reason = ""
    var ownsSleepChange = false
    var sleepRestored = true
    var bootID: String? = nil
    var settingsRevision: UInt64? = nil
    var settingsError: String? = nil
    var powerMode: PowerMode? = nil
    var threshold: Int? = nil

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
        deadline = configuration.absoluteDeadline ?? configuration.duration.map { now + $0 }
    }

    mutating func step(now: TimeInterval, control: SessionControl, power: PowerState?, ownerAlive: Bool, interrupted: Bool = false) -> String? {
        if control.stop { return "остановлено" }
        if !ownerAlive { return "приложение закрыто" }
        if interrupted { return "защитный процесс завершён" }
        guard now.isFinite else { return "Некорректные параметры сеанса." }
        if let deadline, now >= deadline { return "время истекло" }
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
        if let deadline, now >= deadline { return "время истекло" }
        if let reason = powerStopReason(power, mode: effectivePowerMode, threshold: effectiveThreshold) { return reason }
        return nil
    }
}
