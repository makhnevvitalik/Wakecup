import Foundation

@main
struct CoreTests {
    static func main() throws {
        var count = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { failures.append(label) }
        }
        func config(_ duration: Double? = 120, mode: PowerMode = .battery, threshold: Int = 20) -> SessionConfiguration {
            SessionConfiguration(id: UUID().uuidString, parentPID: 123, duration: duration,
                                 powerMode: mode, threshold: threshold, closedLid: true, keepDisplayOn: false)
        }
        let battery = PowerState(onAC: false, percent: 80)
        let ac = PowerState(onAC: true, percent: 80)
        let identity = ProcessIdentity(pid: 123, startedAtMicroseconds: 100)
        expect(identity.matches(ProcessIdentity(pid: 123, startedAtMicroseconds: 100)), "same process identity accepted")
        expect(!identity.matches(ProcessIdentity(pid: 123, startedAtMicroseconds: 200)), "reused PID is not the previous helper")
        expect(!identity.matches(nil), "missing process is not the previous helper")
        let active = SessionStatus(phase: "active", phaseChangedAt: 100)
        expect(active.hasRecentActivity(at: 105), "a recent phase change gives the first socket probe time to answer")
        expect(!active.hasRecentActivity(at: 112), "a phase change expires at the response timeout")
        expect(!active.hasRecentActivity(at: 50), "a phase change from a future monotonic time is rejected")
        expect(!active.hasRecentActivity(at: .infinity), "invalid current time is rejected")
        let longRunning = 35.0 * 24 * 60 * 60
        expect(active.hasRecentActivity(at: longRunning, lastSocketResponse: longRunning - 4),
               "a fresh socket reply keeps a long-running session healthy without touching its saved state")
        expect(!active.hasRecentActivity(at: longRunning, lastSocketResponse: longRunning - 12),
               "a socket reply expires at the response timeout")
        let maximumThreshold = try? SessionMonitor(configuration: config(mode: .battery, threshold: 90), now: 100)
        expect(maximumThreshold?.effectiveThreshold == 90, "Guardian accepts the 90-percent cutoff")
        var updatedThreshold = try SessionMonitor(configuration: config(mode: .ac), now: 100)
        let newThreshold = SessionLiveUpdate(revision: 1, powerMode: .ac, threshold: 90, deadline: 220)
        expect(updatedThreshold.step(now: 101, control: SessionControl(update: newThreshold), power: ac, ownerAlive: true) == nil
            && updatedThreshold.effectiveThreshold == 90 && updatedThreshold.settingsError == nil, "Guardian accepts a live 90-percent cutoff")
        let maximumTimer = try? SessionMonitor(configuration: config(3_596_400), now: 100)
        expect(maximumTimer?.deadline == 3_596_500, "Guardian accepts a 999-hour timer")
        expect(powerStopReason(ac, mode: .battery, threshold: 20) == nil, "allow battery profile also allows charging")
        for threshold in [10, 20, 50, 90] {
            expect(powerStopReason(PowerState(onAC: false, percent: threshold + 1), mode: .battery, threshold: threshold) == nil, "above threshold \(threshold)")
            expect(powerStopReason(PowerState(onAC: false, percent: threshold), mode: .battery, threshold: threshold) != nil, "at threshold \(threshold)")
            expect(powerStopReason(PowerState(onAC: false, percent: threshold - 1), mode: .battery, threshold: threshold) != nil, "below threshold \(threshold)")
        }
        expect(powerStopReason(nil, mode: .battery, threshold: 20) != nil, "missing power snapshot stops session")
        expect(powerStopReason(PowerState(onAC: false, percent: nil), mode: .battery, threshold: 20) != nil, "unknown battery stops session")
        expect(powerStopReason(PowerState(onAC: false, percent: 101), mode: .battery, threshold: 20) != nil, "invalid percentage stops session")
        expect(powerStopReason(battery, mode: .ac, threshold: 20) != nil, "mains-only stops on disconnect")
        for invalid in [9, 91] {
            expect(powerStopReason(ac, mode: .battery, threshold: invalid) != nil, "invalid threshold \(invalid) rejected")
        }
        var timed = try SessionMonitor(configuration: config(2), now: 100)
        expect(timed.deadline == 102, "timer starts after authorization at actual start")
        expect(timed.step(now: 101.99, control: SessionControl(), power: battery, ownerAlive: true) == nil, "does not stop early")
        expect(timed.step(now: 102, control: SessionControl(), power: battery, ownerAlive: true) == "время истекло", "auto-stop exactly at deadline")
        var resumed = try SessionMonitor(configuration: config(2), now: 100)
        expect(resumed.step(now: 500, control: SessionControl(), power: battery, ownerAlive: true) != nil, "past deadline after sleep stops immediately")
        var infinite = try SessionMonitor(configuration: config(nil), now: 100)
        expect(infinite.deadline == nil, "infinite session has no deadline")
        expect(infinite.step(now: 100000, control: SessionControl(), power: battery, ownerAlive: true) == nil, "infinite session does not time out")
        expect(infinite.step(now: 100001, control: SessionControl(stop: true), power: battery, ownerAlive: true) != nil, "infinite session can stop manually")
        var safety = try SessionMonitor(configuration: config(nil), now: 100)
        expect(safety.step(now: 101, control: SessionControl(), power: battery, ownerAlive: false) != nil, "owner death stops even infinite session")
        expect(safety.step(now: 101, control: SessionControl(), power: battery, ownerAlive: true, interrupted: true) != nil, "termination signal stops session")
        expect(safety.step(now: 101, control: SessionControl(), power: PowerState(onAC: false, percent: 20), ownerAlive: true) != nil, "battery threshold stops infinite session")
        var malformed = try SessionMonitor(configuration: config(), now: 100)
        expect(malformed.step(now: .nan, control: SessionControl(), power: battery, ownerAlive: true) != nil,
               "an invalid clock reading stops the session")
        for duration in [-1.0, 0, Double.infinity, Double.nan, 3_596_401] {
            var rejected = false
            do { _ = try SessionMonitor(configuration: config(duration), now: 100) } catch { rejected = true }
            expect(rejected, "invalid duration \(duration) rejected")
        }

        // Live settings use one atomic revisioned payload. These checks catch
        // reapplication, partial rejection and extending a timer after expiry.
        func update(_ revision: UInt64, _ deadline: Double? = 500,
                    mode: PowerMode = .battery, threshold: Int = 25) -> SessionControl {
            SessionControl(update: SessionLiveUpdate(revision: revision, powerMode: mode,
                                                    threshold: threshold, deadline: deadline))
        }
        var live = try SessionMonitor(configuration: config(), now: 100)
        expect(live.settingsRevision == 0 && live.settingsError == nil, "live settings begin without a processed update")
        expect(live.effectivePowerMode == .battery && live.effectiveThreshold == 20, "initial effective settings match configuration")
        expect(live.step(now: 110, control: update(1), power: battery, ownerAlive: true) == nil, "valid live settings accepted")
        expect(live.deadline == 500 && live.effectiveThreshold == 25 && live.settingsRevision == 1,
               "valid update replaces remaining deadline and acknowledges its revision")
        expect(live.step(now: 111, control: update(1, 900, mode: .ac, threshold: 30), power: battery, ownerAlive: true) == nil,
               "same revision with an altered payload is ignored")
        expect(live.deadline == 500 && live.effectiveThreshold == 25 && live.effectivePowerMode == .battery,
               "same revision cannot reapply settings")
        _ = live.step(now: 112, control: update(0, 900), power: battery, ownerAlive: true)
        expect(live.deadline == 500 && live.settingsRevision == 1, "older revisions cannot overwrite newer settings")
        expect(live.step(now: 113, control: update(2, 150, threshold: 30), power: battery, ownerAlive: true) == nil,
               "remaining duration can be shortened")
        expect(live.deadline == 150 && live.settingsRevision == 2, "shortened absolute deadline becomes effective")
        expect(live.step(now: 114, control: update(3, nil), power: battery, ownerAlive: true) == nil && live.deadline == nil,
               "finite timer can become infinite")
        expect(live.step(now: 115, control: update(4, 130), power: battery, ownerAlive: true) == nil && live.deadline == 130,
               "infinite timer can become finite")
        expect(live.step(now: 130, control: update(5, 500), power: battery, ownerAlive: true) == "время истекло",
               "new settings cannot revive an expired deadline")
        expect(live.deadline == 130 && live.settingsRevision == 4, "expired session does not acknowledge or apply revival")

        var invalidLive = try SessionMonitor(configuration: config(), now: 100)
        expect(invalidLive.step(now: 110, control: update(1, 600, mode: .ac, threshold: 91), power: battery, ownerAlive: true) == nil,
               "invalid live update does not stop a safe session")
        expect(invalidLive.settingsRevision == 1 && invalidLive.settingsError != nil, "rejected revision is acknowledged with an error")
        expect(invalidLive.deadline == 220 && invalidLive.effectiveThreshold == 20 && invalidLive.effectivePowerMode == .battery,
               "invalid threshold rejects the whole update atomically")
        let rejection = invalidLive.settingsError
        _ = invalidLive.step(now: 111, control: update(1, 600, threshold: 30), power: battery, ownerAlive: true)
        expect(invalidLive.deadline == 220 && invalidLive.settingsError == rejection, "corrected payload with rejected revision is not retried")
        for (index, invalidDeadline) in [0.0, -1, Double.infinity, -Double.infinity, Double.nan, 3_596_511].enumerated() {
            expect(invalidLive.step(now: 110, control: update(UInt64(index + 2), invalidDeadline, threshold: 30), power: battery, ownerAlive: true) == nil,
                   "invalid live deadline leaves safe session running: \(invalidDeadline)")
            expect(invalidLive.deadline == 220 && invalidLive.effectiveThreshold == 20 && invalidLive.settingsError != nil,
                   "invalid live deadline retains previously effective settings: \(invalidDeadline)")
        }
        _ = invalidLive.step(now: 111, control: update(9, 400), power: battery, ownerAlive: true)
        expect(invalidLive.settingsRevision == 9 && invalidLive.settingsError == nil && invalidLive.deadline == 400,
               "a valid later revision clears the rejected update error")
        var exactMaximum = try SessionMonitor(configuration: config(), now: 100)
        _ = exactMaximum.step(now: 110, control: update(1, 3_596_510), power: battery, ownerAlive: true)
        expect(exactMaximum.deadline == 3_596_510 && exactMaximum.settingsError == nil, "maximum remaining live duration is accepted inclusively")

        var changedPower = try SessionMonitor(configuration: config(), now: 100)
        expect(changedPower.step(now: 110, control: update(1, 300, mode: .ac), power: battery, ownerAlive: true) == "зарядка отключена",
               "new power policy is checked on the same step")
        expect(changedPower.settingsRevision == 1 && changedPower.effectivePowerMode == .ac && changedPower.deadline == 300,
               "terminal changed-policy step exposes the applied settings for acknowledgement")
        var changedThreshold = try SessionMonitor(configuration: config(), now: 100)
        expect(changedThreshold.step(now: 110, control: update(1, 300, threshold: 50),
                                    power: PowerState(onAC: false, percent: 40), ownerAlive: true) == "заряд достиг порога 50%",
               "new battery threshold is checked immediately")
        var expiredUpdate = try SessionMonitor(configuration: config(), now: 100)
        expect(expiredUpdate.step(now: 110, control: update(1, 109), power: battery, ownerAlive: true) == "время истекло",
               "valid already-elapsed replacement deadline stops immediately")
        expect(expiredUpdate.deadline == 109 && expiredUpdate.settingsRevision == 1, "elapsed replacement is acknowledged before terminal status")
        var relaxedPower = try SessionMonitor(configuration: config(mode: .ac), now: 100)
        expect(relaxedPower.step(now: 110, control: update(1), power: battery, ownerAlive: true) == nil,
               "allowing battery takes effect before the old power policy could stop the session")
        var stoppedUpdate = try SessionMonitor(configuration: config(), now: 100)
        var stopControl = update(1)
        stopControl.stop = true
        expect(stoppedUpdate.step(now: 110, control: stopControl, power: battery, ownerAlive: true) == "остановлено"
               && stoppedUpdate.settingsRevision == 0, "manual stop takes precedence over live settings")
        expect(stoppedUpdate.step(now: 110, control: update(1), power: battery, ownerAlive: false) == "приложение закрыто"
               && stoppedUpdate.settingsRevision == 0, "owner death takes precedence over live settings")
        expect(stoppedUpdate.step(now: 110, control: update(1), power: battery, ownerAlive: true, interrupted: true) == "защитный процесс завершён"
               && stoppedUpdate.settingsRevision == 0, "interruption takes precedence over live settings")

        var restartConfiguration = config(120)
        restartConfiguration.absoluteDeadline = 250
        let restarted = try SessionMonitor(configuration: restartConfiguration, now: 200)
        expect(restarted.deadline == 250, "restart retains exact absolute deadline instead of resetting the duration")
        var expiredRestart = try SessionMonitor(configuration: restartConfiguration, now: 260)
        expect(expiredRestart.step(now: 260, control: update(1, 500), power: battery, ownerAlive: true) == "время истекло",
               "expiry during authorization is detected on the first step before mutation")
        restartConfiguration.absoluteDeadline = 10_000_000
        expect(try SessionMonitor(configuration: restartConfiguration, now: 0).deadline == 10_000_000,
               "absolute uptime is not incorrectly bounded by maximum duration during helper validation")
        for invalidDeadline in [0.0, -1, Double.infinity, Double.nan] {
            restartConfiguration.absoluteDeadline = invalidDeadline
            var rejected = false
            do { _ = try SessionMonitor(configuration: restartConfiguration, now: 100) } catch { rejected = true }
            expect(rejected, "invalid restart deadline rejected: \(invalidDeadline)")
        }
        var published = SessionStatus(phase: "active")
        expect(published.update(from: changedPower), "terminal power-policy update requests immediate status publication")
        expect(published.settingsRevision == 1 && published.settingsError == nil && published.powerMode == .ac
               && published.threshold == 25 && published.deadline == 300,
               "terminal status reports acknowledged revision and effective settings")
        expect(!published.update(from: changedPower), "unchanged monitor does not require an additional status write")
        var rejectedUpdate = try SessionMonitor(configuration: config(), now: 100)
        _ = rejectedUpdate.step(now: 110, control: update(1, 500, threshold: 91), power: battery, ownerAlive: true)
        expect(published.update(from: rejectedUpdate), "a rejected revision requests immediate status publication")
        expect(published.settingsRevision == 1 && published.settingsError != nil && published.powerMode == .battery
               && published.threshold == 20 && published.deadline == 220,
               "rejected status reports the prior effective settings")
        expect(published.update(from: live), "deadline changes are published even when the last step expired")
        expect(published.settingsRevision == 4 && published.deadline == 130, "expired revival does not publish the rejected replacement")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encodedUpdate = try decoder.decode(SessionControl.self, from: encoder.encode(update(4, nil, mode: .ac, threshold: 40)))
        expect(encodedUpdate.update == SessionLiveUpdate(revision: 4, powerMode: .ac, threshold: 40, deadline: nil),
               "live settings round-trip finite revision and infinite deadline")

        print("Core checks: \(count), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
