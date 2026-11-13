import Foundation
import Darwin

private var interrupted: Int32 = 0

func runGuard(at url: URL, context: ManagedGuardContext) -> Int32 {
    guard geteuid() == 0 else { print("Нужны права администратора."); return 1 }
    interrupted = 0
    var files: SessionFiles?
    defer { withExtendedLifetime(files) {} }
    var retainedLease: GuardLease?
    var mayWriteStatus = false
    var status = SessionStatus(phase: "preparing")
    do {
        let opened = try SessionFiles(url: url, expectedOwner: context.ownerUID)
        try context.validate(files: opened)
        if !context.restoreOnly, try !opened.tryLockGuardianAccess() {
            throw WakecupError(message: "Another guardian or recovery operation owns the sleep setting. Try again after it stops.")
        }
        files = opened
        let configuration = context.configuration
        let lease = try GuardLease()
        retainedLease = lease
        let bootID = try systemBootID()
        if context.restoreOnly {
            let operations = RecoveryOperations(now: continuousNow, bootID: bootID,
                readStatus: { try opened.read("status.json", as: SessionStatus.self) },
                writeStatus: { try opened.write($0, to: "status.json") },
                tryAcquireLease: lease.tryAcquire, readOwner: lease.readOwner,
                claimLease: { try lease.claim(session: opened.identity, bootID: bootID, recovering: true) },
                process: recoveryProcess, signal: signalRecoveryProcess, children: recoveryChildren,
                wait: { Thread.sleep(forTimeInterval: $0) }, restoreSleep: {
                    let result = try lease.runCommand("/usr/bin/pmset", ["disablesleep", "0"])
                    guard result.status == 0, try !readDisabled(using: lease.runCommand) else {
                        throw WakecupError(message: "Не удалось восстановить сон.")
                    }
                }, readSleepDisabled: readDisabled,
                guardianProbe: { GuardianStatusSocket.probe(pid: $0) })
            _ = try recoverSession(opened.identity, using: operations)
            return 0
        }
        guard try lease.tryAcquire() else {
            throw WakecupError(message: "Another guardian or recovery operation owns the sleep setting. Try again after it stops.")
        }
        // Do not overwrite a previous session's trusted ownership record while
        // its process/command can still write, or its global change remains.
        if let previousOwner = try lease.readOwner(), previousOwner.bootID == bootID,
           previousOwner.process.matches(try recoveryProcess(previousOwner.process.pid)?.identity) {
            throw WakecupError(message: "Another guardian or recovery operation owns the sleep setting. Try again after it stops.")
        }
        guard try !lease.hasLiveCommands(), try !readDisabled() else {
            throw WakecupError(message: "Сон уже отключён другой настройкой. Сеанс не запущен.")
        }
        let previousStatus = try opened.read("status.json", as: SessionStatus.self)
        guard !previousStatus.ownsSleepChange || previousStatus.sleepRestored else {
            throw WakecupError(message: "Automatic recovery could not establish exclusive ownership. Try recovery again; if it still fails, use the manual recovery guide.")
        }
        try lease.claim(session: opened.identity, bootID: bootID, recovering: false)
        mayWriteStatus = true
        status.bootID = bootID
        status.helperPID = getpid()
        status.helperIdentity = processIdentity(getpid())
        status.phaseChangedAt = continuousNow()
        guard status.helperIdentity != nil else {
            throw WakecupError(message: "Не удалось установить идентичность процессов сеанса.")
        }
        var monitor = try SessionMonitor(configuration: configuration, now: continuousNow())
        let control = try opened.read("control.json", as: SessionControl.self)
        let initialReason = monitor.step(now: continuousNow(), control: control, power: readPowerState(),
                                         ownerAlive: configuration.parentIdentity?.matches(processIdentity(configuration.parentPID)) == true)
        _ = status.update(from: monitor)
        if let initialReason { throw WakecupError(message: initialReason) }
        guard lidClosed() != nil else { throw WakecupError(message: "Датчик крышки недоступен.") }
        let statusSocket = try GuardianStatusSocket.system(owner: opened.owner)
        defer { withExtendedLifetime(statusSocket) {} }
        signal(SIGTERM) { _ in interrupted = 1 }
        signal(SIGINT) { _ in interrupted = 1 }
        signal(SIGHUP) { _ in interrupted = 1 }
        try temporaryDisable(read: { try readDisabled(using: lease.runCommand) }, write: { disabled in
            if disabled {
                try lease.armSleepChange()
                status.phase = "arming"
                status.ownsSleepChange = true
                status.sleepRestored = false
                status.phaseChangedAt = continuousNow()
                try opened.write(status, to: "status.json")
            }
            let result = try lease.runCommand("/usr/bin/pmset", ["disablesleep", disabled ? "1" : "0"])
            guard result.status == 0 else { throw WakecupError(message: "Не удалось изменить режим сна.") }
        }, body: {
            let start = continuousNow()
            // Preserve an explicit deadline across authorization and sleep
            // changes. Only an untouched relative timer starts at this point.
            // Keep any preflight revision (including rejection).
            if configuration.absoluteDeadline == nil, monitor.settingsRevision == 0 || monitor.settingsError != nil {
                monitor.deadline = configuration.duration.map { start + $0 }
            }
            status.phase = "active"
            status.phaseChangedAt = start
            _ = status.update(from: monitor)
            try opened.write(status, to: "status.json")
            while true {
                let control = try opened.read("control.json", as: SessionControl.self)
                let reason = monitor.step(now: continuousNow(), control: control, power: readPowerState(),
                                          ownerAlive: configuration.parentIdentity?.matches(processIdentity(configuration.parentPID)) == true, interrupted: interrupted != 0)
                let settingsChanged = status.update(from: monitor)
                if let reason {
                    status.reason = reason
                    break
                }
                if settingsChanged {
                    try opened.write(status, to: "status.json")
                }
                statusSocket.answerWaitingProbes()
                Thread.sleep(forTimeInterval: 0.5)
            }
            status.phase = "restoring"
            status.phaseChangedAt = continuousNow()
            try opened.write(status, to: "status.json")
        })
        status.phase = "stopped"
        status.sleepRestored = true
        try opened.write(status, to: "status.json")
        return 0
    } catch {
        status.phase = "failed"
        status.reason = error.localizedDescription
        if mayWriteStatus {
            if status.ownsSleepChange, let lease = retainedLease {
                status.sleepRestored = (try? lease.hasLiveCommands()) == false
                    && (try? readDisabled(using: lease.runCommand)) == false
            }
            try? files?.write(status, to: "status.json")
        }
        print(error.localizedDescription)
        return 1
    }
}

func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
