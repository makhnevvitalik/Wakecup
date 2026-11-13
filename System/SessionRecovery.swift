import Foundation
import Darwin

struct SessionDirectoryIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
}

// This record is read only from the root-owned global lease, never from UI JSON.
struct GuardLeaseOwner: Codable {
    let session: SessionDirectoryIdentity
    let process: ProcessIdentity
    let bootID: String
    let recovering: Bool
    var ownsSleepChange = false
    var commands: [ProcessIdentity] = []
}

struct RecoveryProcess {
    let identity: ProcessIdentity
    let parentPID: Int32
    let executable: String
    let stopped: Bool
    let effectiveUID: UInt32
}

struct RecoveryOperations {
    let now: () -> TimeInterval
    let bootID: String
    let readStatus: () throws -> SessionStatus
    let writeStatus: (SessionStatus) throws -> Void
    let tryAcquireLease: () throws -> Bool
    let readOwner: () throws -> GuardLeaseOwner?
    let claimLease: () throws -> Void
    let process: (Int32) throws -> RecoveryProcess?
    let signal: (ProcessIdentity, Int32) throws -> Void
    let children: (Int32) throws -> [RecoveryProcess]
    let wait: (TimeInterval) -> Void
    let restoreSleep: () throws -> Void
    let readSleepDisabled: () throws -> Bool
    let guardianProbe: (Int32) -> GuardianStatusSocket.Reply
}

// A successful return means that no old writer can subsequently run pmset 1.
// Every wait is bounded; failure leaves the session recoverable and does not
// authorize changing a global flag owned by another session.
func recoverSession(_ session: SessionDirectoryIdentity, using op: RecoveryOperations) throws -> SessionStatus {
    let manual = "Automatic recovery could not establish exclusive ownership. Try recovery again; if it still fails, use the manual recovery guide."
    func rejected() -> WakecupError { WakecupError(message: manual) }
    func owner() throws -> GuardLeaseOwner {
        guard let value = try op.readOwner(), value.session == session,
              value.bootID == op.bootID else { throw rejected() }
        return value
    }
    func sameOwner(_ expected: GuardLeaseOwner) throws -> GuardLeaseOwner {
        let current = try owner()
        guard expected.process.matches(current.process), expected.recovering == current.recovering else { throw rejected() }
        return current
    }
    func live(_ identity: ProcessIdentity) throws -> RecoveryProcess? {
        guard let process = try op.process(identity.pid), identity.matches(process.identity) else { return nil }
        return process
    }
    func signal(_ identity: ProcessIdentity, _ value: Int32) throws {
        guard let process = try live(identity) else { return }
        guard process.effectiveUID == 0 else { throw rejected() }
        try op.signal(identity, value)
    }
    func awaitGone(_ identity: ProcessIdentity, attempts: Int = 40) throws {
        for _ in 0..<attempts {
            if try live(identity) == nil { return }
            op.wait(0.05)
        }
        guard try live(identity) == nil else { throw rejected() }
    }
    func stopCommand(_ identity: ProcessIdentity) throws {
        guard let process = try live(identity) else { return }
        guard process.executable == "/usr/bin/pmset", process.effectiveUID == 0 else { throw rejected() }
        // A recorded orphan is frozen too: it must not fork a writer between
        // the descendant check and its own termination.
        try signal(identity, SIGSTOP)
        defer { if !process.stopped { try? signal(identity, SIGCONT) } }
        for _ in 0..<10 {
            if try live(identity)?.stopped != false { break }
            op.wait(0.05)
        }
        if let current = try live(identity) {
            guard current.stopped, try op.children(identity.pid).isEmpty else { throw rejected() }
            try signal(identity, SIGKILL)
            try awaitGone(identity)
        }
    }
    func restoreWithLease(_ expected: GuardLeaseOwner) throws -> SessionStatus {
        let currentOwner = try sameOwner(expected)
        guard currentOwner.ownsSleepChange else { throw rejected() }
        // A free lock with a live recorded owner is not proof that it stopped
        // writing. Do not guess or kill a process outside the takeover path.
        guard try live(currentOwner.process) == nil else { throw rejected() }
        for command in currentOwner.commands { try stopCommand(command) }
        var status = try op.readStatus()
        if status.sleepRestored { return status }
        guard status.ownsSleepChange else { throw rejected() }
        try op.claimLease()
        try op.restoreSleep()
        status.phase = "stopped"
        status.reason = "сон восстановлен после прерванного сеанса"
        status.sleepRestored = true
        status.helperPID = 0
        status.helperIdentity = nil
        try op.writeStatus(status)
        return status
    }
    func staleStatus(_ expected: GuardLeaseOwner) throws {
        let status = try op.readStatus()
        guard status.ownsSleepChange, !status.sleepRestored,
              status.helperPID == expected.process.pid,
              status.helperIdentity?.matches(expected.process) == true,
              let phaseChangedAt = status.phaseChangedAt, phaseChangedAt.isFinite,
              op.now() >= phaseChangedAt, op.now() - phaseChangedAt >= SessionStatus.responseTimeout else { throw rejected() }
    }

    func requireUnresponsiveGuardian(_ expected: GuardLeaseOwner) throws {
        guard op.guardianProbe(expected.process.pid) == .timedOut else { throw rejected() }
    }

    let initial = try op.readStatus()
    guard initial.ownsSleepChange, !initial.sleepRestored else {
        throw WakecupError(message: "Нет прерванного сеанса для восстановления.")
    }
    if try op.tryAcquireLease() {
        if let current = try op.readOwner(), current.session == session, current.bootID == op.bootID, current.ownsSleepChange {
            return try restoreWithLease(current)
        }
        // A legacy/rebooted session cannot authorize a write or a kill. Once
        // the flag is already off (including manual recovery), it can safely
        // be acknowledged, provided no recorded writer can turn it back on.
        if let current = try op.readOwner(), current.bootID == op.bootID {
            guard try live(current.process) == nil else { throw rejected() }
            for command in current.commands {
                guard try live(command) == nil else { throw rejected() }
            }
        }
        if let identity = initial.helperIdentity {
            guard try live(identity) == nil else { throw rejected() }
        } else if try op.process(initial.helperPID) != nil { throw rejected() }
        guard try !op.readSleepDisabled() else { throw rejected() }
        var status = initial
        status.phase = "stopped"
        status.reason = "сон восстановлен после прерванного сеанса"
        status.sleepRestored = true
        status.helperPID = 0
        status.helperIdentity = nil
        try op.writeStatus(status)
        return status
    }
    let expected = try owner()
    guard !expected.recovering, expected.ownsSleepChange else { throw rejected() }
    try staleStatus(expected)
    guard try live(expected.process) != nil else { throw rejected() }
    _ = try sameOwner(expected)
    // Give a temporarily blocked guardian the chance to restore normally. A
    // fresh guardian never enters this path and receives no signal at all.
    try staleStatus(expected)
    try requireUnresponsiveGuardian(expected)
    try signal(expected.process, SIGTERM)
    try signal(expected.process, SIGCONT)
    for _ in 0..<120 {
        if try op.tryAcquireLease() { return try restoreWithLease(expected) }
        _ = try sameOwner(expected)
        try staleStatus(expected)
        op.wait(0.05)
    }

    _ = try sameOwner(expected)
    try staleStatus(expected)
    try requireUnresponsiveGuardian(expected)
    var helperFrozen = false
    var childrenFrozen: [ProcessIdentity] = []
    var childrenToResume: [ProcessIdentity] = []
    defer {
        // On refusal, return still-live processes to the state in which they
        // can finish their own bounded cleanup. Never signal a reused PID.
        // A START_SUSPENDED child may not have been registered yet. Only its
        // parent may resume it after committing the command identity.
        childrenToResume.forEach { try? signal($0, SIGCONT) }
        if helperFrozen { try? signal(expected.process, SIGCONT) }
    }
    try signal(expected.process, SIGSTOP)
    helperFrozen = true
    for _ in 0..<10 {
        if try live(expected.process)?.stopped == true { break }
        op.wait(0.05)
    }
    guard try live(expected.process)?.stopped == true else { throw rejected() }
    _ = try sameOwner(expected)
    try staleStatus(expected)
    // The helper is frozen before enumeration, closing the spawn/registration
    // race. Only its identified direct pmset children can be taken over.
    let children = try op.children(expected.process.pid)
    for child in children {
        guard child.parentPID == expected.process.pid, child.effectiveUID == 0,
              child.executable == "/usr/bin/pmset" else { throw rejected() }
        try signal(child.identity, SIGSTOP)
        childrenFrozen.append(child.identity)
        if !child.stopped { childrenToResume.append(child.identity) }
        for _ in 0..<10 {
            if try live(child.identity)?.stopped != false { break }
            op.wait(0.05)
        }
        if let current = try live(child.identity) {
            guard current.stopped, try op.children(child.identity.pid).isEmpty else { throw rejected() }
        }
    }
    _ = try sameOwner(expected)
    try staleStatus(expected)
    // Kill/reap commands before their parent so that an enabling command can
    // never wake after pmset 0. No process-group signals are used.
    for child in childrenFrozen { try stopCommand(child) }
    for child in try sameOwner(expected).commands { try stopCommand(child) }
    try signal(expected.process, SIGKILL)
    try awaitGone(expected.process)
    helperFrozen = false
    for _ in 0..<20 {
        if try op.tryAcquireLease() { return try restoreWithLease(expected) }
        _ = try sameOwner(expected)
        op.wait(0.05)
    }
    throw rejected()
}
