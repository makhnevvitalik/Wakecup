import Foundation
import Darwin

private final class RecoveryFixture {
    let session = SessionDirectoryIdentity(device: 1, inode: 2)
    let helper = ProcessIdentity(pid: 300, startedAtMicroseconds: 100)
    let child = ProcessIdentity(pid: 301, startedAtMicroseconds: 101)
    var now = 120.0
    var status: SessionStatus
    var owner: GuardLeaseOwner?
    var processes: [Int32: RecoveryProcess] = [:]
    var acquired = false
    var leaseAvailable = false
    var events: [String] = []
    var signalError = false
    var commandError = false
    var writeError = false
    var disabled = true
    var keepChildAlive = false
    var childrenErrorPID: Int32?
    var onWait: (() -> Void)?
    var onAcquire: (() -> Void)?
    var onChildren: (() -> Void)?
    var probe: GuardianStatusSocket.Reply = .timedOut

    init() {
        status = SessionStatus(phase: "active", helperPID: helper.pid, helperIdentity: helper,
            phaseChangedAt: 100, ownsSleepChange: true, sleepRestored: false)
        owner = GuardLeaseOwner(session: session, process: helper, bootID: "boot", recovering: false, ownsSleepChange: true)
        processes[helper.pid] = RecoveryProcess(identity: helper, parentPID: 10, executable: "/Wakecup",
            stopped: true, effectiveUID: 0)
        processes[child.pid] = RecoveryProcess(identity: child, parentPID: helper.pid, executable: "/usr/bin/pmset",
            stopped: false, effectiveUID: 0)
    }

    var operations: RecoveryOperations {
        RecoveryOperations(now: { self.now }, bootID: "boot", readStatus: { self.status },
            writeStatus: {
                if self.writeError { throw WakecupError(message: "status write refused") }
                self.status = $0; self.events.append("saved")
            },
            tryAcquireLease: {
                self.onAcquire?()
                if self.leaseAvailable { self.acquired = true; self.events.append("locked"); return true }
                return false
            }, readOwner: { self.owner }, claimLease: { self.events.append("claimed") },
            process: { self.processes[$0] }, signal: { identity, signal in
                guard !self.signalError else { throw WakecupError(message: "signal refused") }
                guard identity.matches(self.processes[identity.pid]?.identity) else {
                    throw WakecupError(message: "identity changed")
                }
                self.events.append("signal:\(identity.pid):\(signal)")
                if signal == SIGSTOP, let process = self.processes[identity.pid] {
                    self.processes[identity.pid] = RecoveryProcess(identity: identity, parentPID: process.parentPID,
                        executable: process.executable, stopped: true, effectiveUID: 0)
                }
                if signal == SIGKILL, !(identity.pid == self.child.pid && self.keepChildAlive) {
                    self.processes[identity.pid] = nil
                    if identity.pid == self.helper.pid { self.leaseAvailable = true }
                }
            }, children: { pid in
                if self.childrenErrorPID == pid { throw WakecupError(message: "child enumeration refused") }
                self.onChildren?()
                return self.processes.values.filter { $0.parentPID == pid }
            }, wait: { delay in self.now += delay; self.onWait?() }, restoreSleep: {
                guard self.acquired, !self.helper.matches(self.processes[self.helper.pid]?.identity),
                      !self.child.matches(self.processes[self.child.pid]?.identity) else {
                    throw WakecupError(message: "restore before exclusive ownership")
                }
                self.events.append("pmset0")
                if self.commandError { throw WakecupError(message: "restore command timed out") }
                self.disabled = false
            }, readSleepDisabled: { self.disabled }, guardianProbe: { _ in self.probe })
    }
}

@main
struct RecoveryTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw WakecupError(message: "FAIL: " + label) }
        }
        func refuses(_ fixture: RecoveryFixture, _ label: String) throws {
            var rejected = false
            do { _ = try recoverSession(fixture.session, using: fixture.operations) } catch { rejected = true }
            try expect(rejected && !fixture.events.contains("pmset0"), label)
        }

        let stale = RecoveryFixture()
        let recovered = try recoverSession(stale.session, using: stale.operations)
        try expect(recovered.sleepRestored && recovered.phase == "stopped", "stale live helper is recovered")
        try expect(stale.events.firstIndex(of: "signal:301:\(SIGKILL)")! < stale.events.firstIndex(of: "pmset0")!, "old pmset cannot run after restoration")
        try expect(stale.events.firstIndex(of: "signal:300:\(SIGKILL)")! < stale.events.firstIndex(of: "pmset0")!, "helper is dead before restoration")

        let unarmed = RecoveryFixture()
        unarmed.owner?.ownsSleepChange = false
        try refuses(unarmed, "unarmed trusted record cannot authorize takeover based on user JSON")
        try expect(!unarmed.events.contains(where: { $0.hasPrefix("signal:") }), "unarmed helper is untouched")

        let unarmedDead = RecoveryFixture()
        unarmedDead.owner?.ownsSleepChange = false
        unarmedDead.processes.removeAll()
        unarmedDead.leaseAvailable = true
        try refuses(unarmedDead, "unarmed record cannot authorize resetting an enabled global flag")

        let healthy = RecoveryFixture()
        healthy.status.phaseChangedAt = 119
        try refuses(healthy, "fresh helper is refused")
        try expect(!healthy.events.contains(where: { $0.hasPrefix("signal:") }), "healthy helper receives no signals")

        for reply in [GuardianStatusSocket.Reply.responsive, .unavailable] {
            let fixture = RecoveryFixture()
            fixture.probe = reply
            try refuses(fixture, "a responsive or unverified endpoint cannot authorize takeover")
            try expect(fixture.events.isEmpty, "no signal was sent")
        }

        let resumed = RecoveryFixture()
        resumed.onWait = { resumed.probe = .responsive }
        try refuses(resumed, "a guardian that resumes answering is not taken over")
        try expect(!resumed.events.contains("signal:300:\(SIGKILL)"), "resumed helper is not killed")

        let reused = RecoveryFixture()
        reused.processes[300] = RecoveryProcess(identity: ProcessIdentity(pid: 300, startedAtMicroseconds: 999),
            parentPID: 10, executable: "/unrelated", stopped: false, effectiveUID: 0)
        try refuses(reused, "PID reuse cannot authorize a kill")
        try expect(!reused.events.contains(where: { $0.hasPrefix("signal:") }), "reused helper PID receives no signals")

        let legacy = RecoveryFixture()
        legacy.owner = nil
        try refuses(legacy, "untrusted legacy status cannot authorize takeover")

        let reboot = RecoveryFixture()
        reboot.owner = GuardLeaseOwner(session: reboot.session, process: reboot.helper, bootID: "oldboot", recovering: false, ownsSleepChange: true)
        try refuses(reboot, "old boot cannot authorize takeover")

        let otherSession = RecoveryFixture()
        otherSession.owner = GuardLeaseOwner(session: SessionDirectoryIdentity(device: 1, inode: 3), process: otherSession.helper,
            bootID: "boot", recovering: false, ownsSleepChange: true)
        try refuses(otherSession, "another session owns global flag")

        let raced = RecoveryFixture()
        raced.onWait = {
            raced.owner = GuardLeaseOwner(session: SessionDirectoryIdentity(device: 2, inode: 99), process: raced.helper,
                bootID: "boot", recovering: false, ownsSleepChange: true)
            raced.leaseAvailable = true
        }
        try refuses(raced, "lease transferred to a new helper cannot be restored by old session")

        let unknownChild = RecoveryFixture()
        unknownChild.processes[302] = RecoveryProcess(identity: ProcessIdentity(pid: 302, startedAtMicroseconds: 102),
            parentPID: unknownChild.helper.pid, executable: "/unrelated", stopped: false, effectiveUID: 0)
        try refuses(unknownChild, "unknown descendants are not killed")
        try expect(!unknownChild.events.contains("signal:302:\(SIGKILL)"), "unknown child remains untouched")

        let unregisteredStopped = RecoveryFixture()
        unregisteredStopped.processes[unregisteredStopped.child.pid] = RecoveryProcess(identity: unregisteredStopped.child,
            parentPID: unregisteredStopped.helper.pid, executable: "/usr/bin/pmset", stopped: true, effectiveUID: 0)
        unregisteredStopped.childrenErrorPID = unregisteredStopped.child.pid
        try refuses(unregisteredStopped, "unregistered suspended command refusal leaves global flag untouched")
        try expect(!unregisteredStopped.events.contains("signal:301:\(SIGCONT)"),
            "refusal never resumes a command that was suspended before durable registration")

        let stoppedOrphan = RecoveryFixture()
        stoppedOrphan.processes[stoppedOrphan.helper.pid] = nil
        stoppedOrphan.owner?.commands = [stoppedOrphan.child]
        stoppedOrphan.processes[stoppedOrphan.child.pid] = RecoveryProcess(identity: stoppedOrphan.child,
            parentPID: 1, executable: "/usr/bin/pmset", stopped: true, effectiveUID: 0)
        stoppedOrphan.childrenErrorPID = stoppedOrphan.child.pid
        stoppedOrphan.leaseAvailable = true
        try refuses(stoppedOrphan, "suspended orphan refusal leaves global flag untouched")
        try expect(!stoppedOrphan.events.contains("signal:301:\(SIGCONT)"), "refusal preserves an orphan's original suspended state")

        let unkillable = RecoveryFixture()
        unkillable.keepChildAlive = true
        try refuses(unkillable, "unkillable command blocks restoration")
        try expect(unkillable.now < 140, "takeover failure has a bounded deadline")

        let denied = RecoveryFixture()
        denied.signalError = true
        try refuses(denied, "signal errors block restoration")

        let failedRestore = RecoveryFixture()
        failedRestore.commandError = true
        var failed = false
        do { _ = try recoverSession(failedRestore.session, using: failedRestore.operations) } catch { failed = true }
        try expect(failed && !failedRestore.status.sleepRestored, "command failure never reports successful restore")

        let dead = RecoveryFixture()
        dead.processes.removeAll()
        dead.leaseAvailable = true
        _ = try recoverSession(dead.session, using: dead.operations)
        try expect(dead.status.sleepRestored && dead.events.contains("pmset0"), "dead helper recovery retains global ownership")

        let orphan = RecoveryFixture()
        orphan.processes[orphan.helper.pid] = nil
        orphan.owner?.commands = [orphan.child]
        orphan.processes[orphan.child.pid] = RecoveryProcess(identity: orphan.child, parentPID: 1, executable: "/usr/bin/pmset",
            stopped: true, effectiveUID: 0)
        orphan.leaseAvailable = true
        _ = try recoverSession(orphan.session, using: orphan.operations)
        try expect(orphan.events.contains("signal:301:\(SIGKILL)") && orphan.status.sleepRestored, "trusted orphan pmset is stopped before recovery")


        let orphanWithChild = RecoveryFixture()
        orphanWithChild.processes[orphanWithChild.helper.pid] = nil
        orphanWithChild.owner?.commands = [orphanWithChild.child]
        orphanWithChild.processes[orphanWithChild.child.pid] = RecoveryProcess(identity: orphanWithChild.child, parentPID: 1,
            executable: "/usr/bin/pmset", stopped: false, effectiveUID: 0)
        orphanWithChild.processes[302] = RecoveryProcess(identity: ProcessIdentity(pid: 302, startedAtMicroseconds: 999),
            parentPID: orphanWithChild.child.pid, executable: "/unrelated", stopped: false, effectiveUID: 0)
        orphanWithChild.leaseAvailable = true
        try refuses(orphanWithChild, "orphan with unknown descendants cannot authorize restoration")
        try expect(!orphanWithChild.events.contains("signal:302:\(SIGKILL)"), "orphan descendants are never killed")

        let exactThreshold = RecoveryFixture()
        exactThreshold.now = 112
        _ = try recoverSession(exactThreshold.session, using: exactThreshold.operations)
        try expect(exactThreshold.status.sleepRestored, "twelve-second stale threshold matches GUI")
        for phaseChangedAt in [119.99, Double.nan, Double.infinity, 121] {
            let invalid = RecoveryFixture()
            invalid.status.phaseChangedAt = phaseChangedAt
            try refuses(invalid, "recent or invalid phase timestamp cannot authorize takeover")
        }
        let missingPhaseChange = RecoveryFixture()
        missingPhaseChange.status.phaseChangedAt = nil
        try refuses(missingPhaseChange, "missing phase timestamp cannot authorize takeover")

        let activeRecovery = RecoveryFixture()
        activeRecovery.owner = GuardLeaseOwner(session: activeRecovery.session, process: activeRecovery.helper,
            bootID: "boot", recovering: true, ownsSleepChange: true)
        try refuses(activeRecovery, "concurrent recovery is never killed")
        try expect(!activeRecovery.events.contains(where: { $0.hasPrefix("signal:") }), "concurrent recovery receives no signals")

        let snapshotRace = RecoveryFixture()
        snapshotRace.onChildren = {
            snapshotRace.owner = GuardLeaseOwner(session: SessionDirectoryIdentity(device: 9, inode: 9),
                process: snapshotRace.helper, bootID: "boot", recovering: false, ownsSleepChange: true)
        }
        try refuses(snapshotRace, "changed lease after snapshot blocks destructive takeover")
        try expect(!snapshotRace.events.contains(where: { $0.hasSuffix(":\(SIGKILL)") }), "changed lease prevents helper and child kill")

        let reusedChild = RecoveryFixture()
        reusedChild.onChildren = {
            reusedChild.processes[301] = RecoveryProcess(identity: ProcessIdentity(pid: 301, startedAtMicroseconds: 999),
                parentPID: 1, executable: "/unrelated", stopped: false, effectiveUID: 0)
        }
        _ = try recoverSession(reusedChild.session, using: reusedChild.operations)
        try expect(reusedChild.status.sleepRestored && reusedChild.processes[301]?.executable == "/unrelated",
            "reused child PID stays untouched while actual old writers are gone")
        try expect(!reusedChild.events.contains("signal:301:\(SIGKILL)"), "reused command PID is never killed")

        let failedWrite = RecoveryFixture()
        failedWrite.writeError = true
        var writeRejected = false
        do { _ = try recoverSession(failedWrite.session, using: failedWrite.operations) } catch { writeRejected = true }
        try expect(writeRejected && !failedWrite.status.sleepRestored, "failed status write cannot report recovery success")

        let legacyOff = RecoveryFixture()
        legacyOff.owner = nil
        legacyOff.processes.removeAll()
        legacyOff.leaseAvailable = true
        legacyOff.disabled = false
        _ = try recoverSession(legacyOff.session, using: legacyOff.operations)
        try expect(legacyOff.status.sleepRestored && !legacyOff.events.contains("pmset0"), "manual legacy recovery is acknowledged without writing global flag")

        let legacyOn = RecoveryFixture()
        legacyOn.owner = nil
        legacyOn.processes.removeAll()
        legacyOn.leaseAvailable = true
        try refuses(legacyOn, "unowned enabled flag is never overwritten")

        let rebootOff = RecoveryFixture()
        rebootOff.owner = GuardLeaseOwner(session: rebootOff.session, process: rebootOff.helper, bootID: "oldboot", recovering: false, ownsSleepChange: true)
        rebootOff.processes.removeAll()
        rebootOff.leaseAvailable = true
        rebootOff.disabled = false
        _ = try recoverSession(rebootOff.session, using: rebootOff.operations)
        try expect(rebootOff.status.sleepRestored && !rebootOff.events.contains("pmset0"), "reboot clears stale ownership without mutating an already restored flag")

        let liveLegacyOff = RecoveryFixture()
        liveLegacyOff.owner = nil
        liveLegacyOff.disabled = false
        liveLegacyOff.leaseAvailable = true
        try refuses(liveLegacyOff, "legacy helper that may write later blocks even read-only acknowledgement")

        let differentWriterOff = RecoveryFixture()
        differentWriterOff.owner = GuardLeaseOwner(session: SessionDirectoryIdentity(device: 9, inode: 9),
            process: differentWriterOff.helper, bootID: "boot", recovering: false, ownsSleepChange: true)
        differentWriterOff.disabled = false
        differentWriterOff.leaseAvailable = true
        try refuses(differentWriterOff, "another live writer blocks stale-session acknowledgement")

        // Real subprocess checks use only children created by this test, never
        // pmset, sudo, a running guardian or a user's application session.
        let output = try command("/bin/sh", ["-c", "printf 'hello'; printf 'world' >&2"])
        try expect(output.status == 0 && output.text == "helloworld", "command captures stdout and stderr")
        var childIdentity: ProcessIdentity?
        var suspendedBeforeRegistration = false
        var directChildObserved = false
        let before = ProcessInfo.processInfo.systemUptime
        var timedOut = false
        do {
            _ = try command("/bin/sleep", ["10"], timeout: 0.15, onLaunch: { identity in
                childIdentity = identity
                let child = try recoveryProcess(identity.pid)
                suspendedBeforeRegistration = child?.stopped == true && child?.executable == "/bin/sleep"
                directChildObserved = try recoveryChildren(getpid()).contains { $0.identity.matches(identity) }
            })
        } catch { timedOut = true }
        try expect(timedOut && ProcessInfo.processInfo.systemUptime - before < 2, "command timeout is bounded")
        try expect(suspendedBeforeRegistration && directChildObserved, "child is suspended and enumerable before command registration")
        try expect(childIdentity != nil && !childIdentity!.matches(processIdentity(childIdentity!.pid)), "timed-out direct command is killed and reaped")

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("wakecup-command-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        var rejectedIdentity: ProcessIdentity?
        var cleanedUp = false
        do {
            _ = try command("/bin/sh", ["-c", "printf 'executed' > " + shellQuote(marker.path)], onLaunch: { identity in
                rejectedIdentity = identity
                throw WakecupError(message: "durable command registration refused")
            }, onExit: { _ in cleanedUp = true })
        } catch { }
        try expect(rejectedIdentity != nil && cleanedUp && !FileManager.default.fileExists(atPath: marker.path),
            "failed registration never executes command payload")
        try expect(!rejectedIdentity!.matches(processIdentity(rejectedIdentity!.pid)), "unregistered suspended command is reaped")

        var stoppedIdentity: ProcessIdentity?
        var stoppedTimedOut = false
        do {
            _ = try command("/bin/sh", ["-c", "kill -STOP $$"], timeout: 0.15, onLaunch: { stoppedIdentity = $0 })
        } catch { stoppedTimedOut = true }
        try expect(stoppedTimedOut && stoppedIdentity != nil && !stoppedIdentity!.matches(processIdentity(stoppedIdentity!.pid)),
            "SIGSTOP during command execution cannot block timeout cleanup")

        let large = try command("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null"], timeout: 2)
        try expect(large.status == 0 && large.text.utf8.count == 65_536, "command drains full pipes while capping captured output")
        print("Recovery checks: \(checks), failures: 0")
    }
}
