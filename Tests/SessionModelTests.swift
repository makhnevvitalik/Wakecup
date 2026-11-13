import AppKit
import Foundation

@main struct SessionModelTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func run() throws {
        let suite = "WakecupModelTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let helper = isolatedHelper(defaults)
        guard !helper.selected, !helper.usesHelper else { throw WakecupError(message: "Helper installation must be opt-in") }
        helper.select(true)
        guard !helper.selected else { throw WakecupError(message: "An absent helper cannot be selected") }
        let quitting = try SessionTestEnvironment()
        let quittingModel = quitting.model()
        quittingModel.editClosedLid(false)
        quittingModel.start()
        var quitRequests = 0
        var cleanedUpAtExit = false
        quittingModel.quitRequested = { [weak quittingModel] in
            quitRequests += 1
            cleanedUpAtExit = !quitting.assertionsActive && quittingModel?.phase == .idle
        }
        quittingModel.quit()
        guard quitRequests == 1, cleanedUpAtExit else {
            throw WakecupError(message: "Quit must clean up the model and request application exit without terminating the test process")
        }
        let environment = try SessionTestEnvironment()
        let savedOptions = SessionModel(defaults: defaults, operations: environment.operations, helper: isolatedHelper(defaults))
        savedOptions.selectEndTimePreset(180)
        let reopened = SessionModel(defaults: defaults, operations: environment.operations, helper: isolatedHelper(defaults))
        try expect(try reopened.selectedDuration() == 10_800, "The current three-hour preset must persist")
        reopened.selectEndTimePreset(0)
        let unlimited = SessionModel(defaults: defaults, operations: environment.operations, helper: isolatedHelper(defaults))
        try expect(try unlimited.selectedDuration() == nil, "The current indefinite choice must persist")
        let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 60,
            powerMode: .battery, threshold: 10, closedLid: true, keepDisplayOn: false)
        let files = try SessionFiles.create(at: directory, configuration: config)
        var status = SessionStatus(phase: "active", helperPID: getpid(), phaseChangedAt: environment.time,
            ownsSleepChange: true, sleepRestored: false)
        try files.write(status, to: "status.json")
        defaults.set(directory.path, forKey: "lastSession")
        let model = SessionModel(defaults: defaults, operations: environment.operations, helper: isolatedHelper(defaults))
        guard model.phase == .stopping else { throw WakecupError(message: "Live previous helper was not asked to stop") }
        status.phaseChangedAt = environment.time - 20
        try files.write(status, to: "status.json")
        model.tick()
        guard model.phase == .failed, model.needsRecovery else {
            throw WakecupError(message: "Helper timeout did not require recovery")
        }
        guard model.canSelectHelperMode, !model.canChangeHelper else {
            throw WakecupError(message: "Recovery must allow selecting password mode while blocking helper installation/removal")
        }
        status.phase = "stopped"
        status.sleepRestored = true
        status.reason = "остановлено"
        try files.write(status, to: "status.json")
        model.tick()
        guard model.phase == .idle, !model.needsRecovery else {
            throw WakecupError(message: "Late helper restoration left recovery stuck")
        }
        print("PASS: helper timeout followed by late restoration clears recovery without authorization")
        try helperReadinessGate()
        try lifecycleTests()
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw WakecupError(message: message) }
}

// System effects are faked; the model still reads/writes the real private IPC files.
private final class SessionTestEnvironment {
    let suite = "WakecupLifecycleTest-" + UUID().uuidString
    let defaults: UserDefaults
    let root: URL
    var time: TimeInterval = 1_000
    private let wallStart = Date(timeIntervalSince1970: 1_794_309_600)
    var power: PowerState? = PowerState(onAC: true, percent: 80)
    var disabled = false
    var lidIsClosed: Bool? = false
    var guardianRunning = false
    var assertionStops = 0
    var assertionDisplays: [Bool] = []
    var assertionsActive = false
    var assertionFailure: Error?
    var installedHelper = false
    var helperRequests: [(path: String, restoreOnly: Bool)] = []
    var helperReplies: [(Result<Int32, Error>) -> Void] = []
    var authorizationRequests: [Bool] = []
    var authorizationReplies: [(CommandOutput) -> Void] = []
    var authorizationCancellations = 0
    var sessions: [SessionFiles] = []
    var authorizationLaunchError: WakecupError?

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    var operations: SessionOperations {
        var operations = SessionOperations(now: { self.time }, readPower: { self.power }, readSleepDisabled: { self.disabled },
            startAssertions: { display in
                if let error = self.assertionFailure { throw error }
                self.assertionDisplays.append(display)
                self.assertionsActive = true
            }, stopAssertions: { self.assertionsActive = false; self.assertionStops += 1 },
            createFiles: { config in
                let files = try SessionFiles.create(at: self.root.appendingPathComponent(config.id), configuration: config)
                self.sessions.append(files)
                return files
            }, guardianResponding: { status, now in status.hasRecentActivity(at: now) },
            authorization: { [self] _, restoreOnly in
                SessionAuthorization(run: { [weak self] completion in
                    if let error = self?.authorizationLaunchError { throw error }
                    self?.authorizationRequests.append(restoreOnly)
                    self?.authorizationReplies.append(completion)
                }, cancel: { [weak self] in self?.authorizationCancellations += 1 })
            }, usesInstalledHelper: { self.installedHelper },
            startHelper: { files, restoreOnly, completion in
                self.helperRequests.append((files.url.path, restoreOnly))
                self.helperReplies.append(completion)
            }, loginItem: LoginItemController(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} }, readLidClosed: { self.lidIsClosed },
            guardianIsRunning: { _ in self.guardianRunning })
        operations.wallNow = { self.wallStart.addingTimeInterval(self.time - 1_000) }
        return operations
    }

    func model() -> SessionModel { SessionModel(defaults: defaults, operations: operations, helper: isolatedHelper(defaults)) }

    func publish(_ phase: String, restored: Bool = false, phaseChangedAt: TimeInterval? = nil, deadline: TimeInterval? = 4_600) throws {
        try sessions.last!.write(SessionStatus(phase: phase, helperPID: 4242, phaseChangedAt: phaseChangedAt ?? time,
            deadline: deadline, reason: phase == "stopped" ? "остановлено" : "",
            ownsSleepChange: true, sleepRestored: restored, bootID: "test-boot"), to: "status.json")
    }

    func interruptedSession() throws {
        let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 60,
            powerMode: .battery, threshold: 20, closedLid: true, keepDisplayOn: false)
        let files = try operations.createFiles(config)
        try publish("active", phaseChangedAt: time - 20)
        defaults.set(files.url.path, forKey: "lastSession")
    }
}

private extension SessionModelTests {
    static func lifecycleTests() throws {
        try livePowerPolicyChanges()
        try liveDisplayChanges()
        try predictablePowerBlocks()
        try openLidStartExtendAndStop()
        try openLidTimeAndPowerLimits()
        try closedLidAuthorizationAndStop()
        try passwordCancellation()
        try authorizationLaunchFailure()
        try ambiguousAuthorizationFailure()
        try delayedArmingAfterAuthorization()
        try unreadableStartupStillTracksRecovery()
        try failedStopWriteCanBeRetried()
        try reopenWithMissingStatusCanBeRetried()
        try reopenWhileGuardianIsPreparing()
        try stopDuringAuthorizationAndIgnoreOldReply()
        try guardianStartupTimeout()
        try lostHelperReplySendsStop()
        try recoveryCompletionAndTimeout()
        try helperRecoveryFailureIsImmediate()
        try lateRecoveryReplyCannotFailNewAttempt()
        try passwordRecoveryAndFailedRestoration()
        try missingStatusTimeout()
        try startupSafetyFailures()
        try liveSettingsTests()
    }

    static func predictablePowerBlocks() throws {
        for closedLid in [true, false] {
            let environment = try SessionTestEnvironment()
            environment.power = PowerState(onAC: false, percent: 62)
            let model = environment.model()
            model.editClosedLid(closedLid)
            model.editAllowBattery(false)
            try expect(model.startPowerRestriction == .chargerRequired, "No charger must update button availability")
            model.start()
            try expect(model.phase == .idle && model.message == nil && environment.sessions.isEmpty,
                "No charger must block Start without adding an error card")
            try expect(environment.authorizationRequests.isEmpty && environment.helperRequests.isEmpty && !environment.assertionsActive,
                "Blocked Start must have no system side effects")
            model.editAllowBattery(true)
            try expect(model.startPowerRestriction == nil, "Allowing battery operation must immediately unblock Start")
            model.editThreshold(50)
            for charge in [49, 50] {
                environment.power = PowerState(onAC: false, percent: charge)
                model.tick()
                try expect(model.startPowerRestriction == .lowCharge(50), "Selected threshold must control button availability")
                model.start()
                try expect(model.phase == .idle && model.message == nil && environment.sessions.isEmpty,
                    "Charge at or below threshold must block Start without an error card")
            }
            model.editThreshold(20)
            try expect(model.startPowerRestriction == nil, "Lowering threshold must immediately unblock Start")
            model.editThreshold(50)
            environment.power = PowerState(onAC: true, percent: 10)
            model.start()
            try expect(model.phase == (closedLid ? .authorizing : .active) && environment.sessions.count == (closedLid ? 1 : 0),
                "Connecting power must permit Start even below the threshold")
            model.power = PowerState(onAC: false, percent: 1)
            try expect(model.startPowerRestriction == nil, "Power restrictions must not block Stop during startup or activity")
            model.stop()
        }
        print("PASS: charger and charge limits block Start without error cards; connecting power permits Start")
    }

    static func livePowerPolicyChanges() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.start()
        let deadline = model.deadline
        model.editAllowBattery(false)
        model.applySettingsDraft()
        try expect(model.phase == .active && model.deadline == deadline, "Changing power policy on AC must preserve the timer")
        environment.power = .init(onAC: false, percent: 80)
        model.tick()
        try expect(model.phase == .idle && !environment.assertionsActive, "Live AC-only policy must stop on unplug, rather than keep the old battery permission")
        print("PASS: live battery permission changes the running policy without resetting its timer")
    }

    static func liveDisplayChanges() throws {
        for closedLid in [false, true] {
            let environment = try SessionTestEnvironment()
            let model = environment.model()
            model.editClosedLid(closedLid)
            model.selectEndTimePreset(180)
            model.start()
            if closedLid { try environment.publish("active"); model.tick() }
            try expect(model.phase == .active, "Display-change fixture must be active")
            let deadline = model.deadline
            let session = environment.sessions.last
            let configuration = try session?.read("configuration.json", as: SessionConfiguration.self)
            let authorizations = environment.authorizationRequests.count
            let helperRequests = environment.helperRequests.count
            let controlBefore = try session.map { try Data(contentsOf: $0.url.appendingPathComponent("control.json")) }
            model.selectDisplayMode(.keepOn)
            model.applySettingsDraft()
            try expect(environment.assertionDisplays == [false, true], "Enabling display during a timer must update live assertions")
            try expect(environment.defaults.string(forKey: "displayMode") == DisplayMode.keepOn.rawValue, "Successful display changes must persist")
            model.selectDisplayMode(.mayTurnOff)
            model.applySettingsDraft()
            try expect(environment.assertionDisplays == [false, true, false], "Disabling display during a timer must update live assertions")
            try expect(environment.defaults.string(forKey: "displayMode") == DisplayMode.mayTurnOff.rawValue, "Disabling display must persist")
            model.selectDisplayMode(.mayTurnOff)
            model.applySettingsDraft()
            try expect(environment.assertionDisplays == [false, true, false], "Unchanged display values must not churn assertions")
            environment.assertionFailure = WakecupError(message: "controlled display failure")
            model.selectDisplayMode(.keepOn)
            model.applySettingsDraft()
            try expect(!model.keepDisplayOn && environment.defaults.string(forKey: "displayMode") == DisplayMode.mayTurnOff.rawValue, "Failed live changes must preserve the old setting and preference")
            try expect(model.displayControlError != nil, "Display failure must be explained without failing the running mode")
            try expect(model.phase == .active && model.deadline == deadline && environment.assertionsActive, "Display changes and failures must preserve the active timer and system sleep prevention")
            try expect(environment.sessions.count == (closedLid ? 1 : 0) && environment.sessions.last === session,
                       "Display changes must preserve the existing session")
            let unchanged = try session?.read("configuration.json", as: SessionConfiguration.self)
            try expect(unchanged == configuration, "Display changes must not rewrite the guardian's trusted configuration")
            let controlAfter = try session.map { try Data(contentsOf: $0.url.appendingPathComponent("control.json")) }
            try expect(controlAfter == controlBefore, "Changing display must not change guardian controls")
            try expect(environment.authorizationRequests.count == authorizations && environment.helperRequests.count == helperRequests, "Display changes must not request privilege or restart a helper")
            environment.assertionFailure = nil
            model.selectDisplayMode(.keepOn)
            model.applySettingsDraft()
            try expect(model.keepDisplayOn && model.displayControlError == nil, "Retrying a display change must succeed and clear the error")
            model.stop()
        }
        print("PASS: live display changes preserve timer/guardian, persist success, roll back failures and require no authorization")
    }

    static func openLidStartExtendAndStop() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.selectDisplayMode(.keepOn)
        model.start()
        try expect(model.phase == .active && model.deadline == 4_600, "Open-lid start must activate the selected timer")
        try expect(environment.assertionsActive && environment.assertionDisplays == [true], "Open-lid start must hold the requested display assertion")
        try expect(environment.authorizationRequests.isEmpty && environment.helperRequests.isEmpty, "Open-lid start must need no privileged request")
        try expect(environment.sessions.isEmpty && environment.defaults.string(forKey: "lastSession") == nil,
                   "Open-lid Start must not create guardian files or set a recovery pointer")
        model.selectEndDate(model.endDate!.addingTimeInterval(120)); model.applySettingsDraft()
        try expect(model.deadline == 4_720 && model.remaining == 3_720, "Extension must update the active timer")
        model.stop()
        try expect(model.phase == .idle && model.deadline == nil && !environment.assertionsActive, "Stop must clear the timer and release assertions")
        try expect(model.message == nil, "Manual stop must not leave a redundant status notice")
        try expect(environment.sessions.isEmpty, "Changing or stopping an open-lid timer must not create guardian files")
        print("PASS: open-lid start, assertions, extension and clean stop")
    }

    static func openLidTimeAndPowerLimits() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.selectEndDate(model.currentDate.addingTimeInterval(60))
        model.start()
        environment.time += 59
        model.tick()
        try expect(model.phase == .active && model.remaining == 1, "Session must remain active before its deadline")
        environment.time += 1
        model.tick()
        try expect(model.phase == .idle && !environment.assertionsActive, "Deadline must end the session and release assertions")
        try expect(model.message == nil, "A timer ending on schedule must not leave a notice")
        model.editAllowBattery(false)
        model.start()
        environment.power = PowerState(onAC: false, percent: 80)
        model.tick()
        try expect(model.phase == .idle && model.message?.arguments == ["зарядка отключена"] && !environment.assertionsActive,
                   "Disconnecting AC in AC-only mode must stop the session")
        model.editAllowBattery(true)
        environment.power = PowerState(onAC: false, percent: 80)
        model.start()
        environment.power = PowerState(onAC: false, percent: Int(model.threshold))
        model.tick()
        try expect(model.phase == .idle && !environment.assertionsActive && model.message?.arguments == ["заряд достиг порога 20%"],
                   "Battery threshold must retain its stop reason")
        print("PASS: controllable clock and power stop the session at their boundaries")
    }

    static func closedLidAuthorizationAndStop() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        try expect(model.phase == .authorizing && model.waitingForPassword, "Password mode must wait for authorization")
        try expect(environment.authorizationRequests == [false] && !environment.assertionsActive, "Assertions must wait until the guardian confirms activation")
        environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
        try expect(model.phase == .authorizing, "Successful authorization alone must not claim an active session")
        try environment.publish("active")
        model.tick()
        model.tick()
        try expect(model.phase == .active && model.deadline == 4_600 && environment.assertionDisplays == [false], "Fresh guardian status must activate assertions exactly once")
        model.stop()
        let control = try environment.sessions.last!.read("control.json", as: SessionControl.self)
        try expect(model.phase == .stopping && control.stop && environment.assertionsActive, "Closed-lid stop must request restoration before finishing")
        try environment.publish("restoring")
        model.tick()
        let sessionPath = environment.sessions.last!.url.path
        try expect(model.phase == .stopping && FileManager.default.fileExists(atPath: sessionPath),
                   "Keep recovery files while sleep restoration is in progress")
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && !model.needsRecovery && !environment.assertionsActive, "Confirmed restoration must complete the stop")
        try expect(model.message == nil, "Confirmed manual closed-lid stop must not leave a redundant notice")
        try expect(!FileManager.default.fileExists(atPath: sessionPath) && environment.defaults.string(forKey: "lastSession") == nil,
                   "Confirmed restoration removes session files and clears the recovery pointer")
        print("PASS: password authorization, guardian activation and confirmed closed-lid stop")
    }

    static func passwordCancellation() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        let path = environment.sessions.last!.url.path
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "User canceled. (-128)"))
        try expect(!FileManager.default.fileExists(atPath: path) && environment.defaults.string(forKey: "lastSession") == nil,
                   "Confirmed password cancellation must remove the unstarted session and its recovery pointer")
        try expect(model.phase == .idle && !model.needsRecovery && model.deadline == nil && !environment.assertionsActive,
                   "Confirmed cancellation must finish without enabling assertions or waiting for the guardian")
        try expect(model.message?.key == "Request cancelled. The session was not started.", "Cancellation must preserve its specific explanation")
        try expect(environment.authorizationRequests.count == 1 && environment.helperRequests.isEmpty, "Cancellation must not launch another privileged request")
        print("PASS: password cancellation produces a clean stop without privileged retry")
    }

    static func authorizationLaunchFailure() throws {
        let environment = try SessionTestEnvironment()
        environment.authorizationLaunchError = WakecupError(message: "Could not launch authorization")
        let model = environment.model()
        model.start()
        let path = environment.sessions.last!.url.path
        try expect(model.phase == .failed && !model.needsRecovery && environment.defaults.string(forKey: "lastSession") == nil
                   && !FileManager.default.fileExists(atPath: path),
                   "A failure before the authorization process launches must remove the unstarted session")
    }

    static func ambiguousAuthorizationFailure() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        let files = environment.sessions.last!
        let guardian = try SessionFiles(url: files.url)
        try expect(try guardian.tryLockGuardianAccess(), "The fake guardian must be able to take the session lock")
        defer { guardian.unlockGuardianAccess() }
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "Command -128 timed out. (-1712)"))
        let control = try files.read("control.json", as: SessionControl.self)
        try expect(model.phase == .stopping && control.stop && FileManager.default.fileExists(atPath: files.url.path),
                   "An uncertain authorization failure must keep the files and record Stop for a possibly launched guardian")
        environment.time += 6
        model.tick()
        try expect(model.phase == .stopping, "An unconfirmed stop must continue monitoring a guardian that holds the session lock")
        model.start()
        try expect(environment.sessions.count == 1, "A new session must not replace the unconfirmed one")
        try environment.publish("arming")
        model.tick()
        try expect(model.phase == .stopping && !environment.assertionsActive,
                   "Late arming must not restart a stopped session")
        try environment.publish("failed")
        model.tick()
        try expect(model.phase == .failed && model.needsRecovery
                   && environment.defaults.string(forKey: "lastSession") == files.url.path,
                   "Failed restoration after late arming must preserve the recovery path")
    }

    static func delayedArmingAfterAuthorization() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
        environment.time += 6
        try environment.publish("arming")
        model.tick()
        let control = try environment.sessions.last!.read("control.json", as: SessionControl.self)
        try expect(model.phase == .authorizing && !control.stop && !environment.assertionsActive,
                   "Fresh arming must not hit the timeout for a guardian that has yet to start")
        try environment.publish("active")
        model.tick()
        try expect(model.phase == .active && environment.assertionsActive,
                   "A delayed guardian must start normally after confirming activation")
        model.stop()
    }

    static func reopenWhileGuardianIsPreparing() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        let files = environment.sessions.last!
        let guardian = try SessionFiles(url: files.url)
        try expect(try guardian.tryLockGuardianAccess(), "The fake guardian must be able to take the session lock")
        defer { guardian.unlockGuardianAccess() }
        let reopened = environment.model()
        let control = try files.read("control.json", as: SessionControl.self)
        try expect(reopened.phase == .stopping && control.stop, "Relaunch must fence a guardian that was still preparing")
        environment.time += 6
        reopened.tick()
        try expect(reopened.phase == .stopping, "Relaunch must keep watching until the guardian exits")
        environment.time += SessionStatus.responseTimeout
        reopened.tick()
        try expect(reopened.phase == .failed && reopened.needsRecovery
                   && reopened.message?.key == "Could not confirm that the guardian stopped.",
                   "An extended wait on the lock must offer recovery rather than spin indefinitely")
        try environment.publish("failed")
        reopened.tick()
        try expect(reopened.needsRecovery && reopened.phase == .failed, "Relaunch must surface a delayed restoration failure")
    }

    static func unreadableStartupStillTracksRecovery() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        let files = environment.sessions.last!
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "Authorization timed out. (-1712)"))
        try FileManager.default.removeItem(at: files.url.appendingPathComponent("status.json"))
        model.tick()
        environment.time += 10
        model.tick()
        try expect(model.phase == .failed && model.needsRecovery, "A missing startup status must leave recovery available")
        model.start()
        try expect(environment.sessions.count == 1, "Unconfirmed recovery must not lose the original session")
        try files.write(SessionStatus(phase: "failed", reason: "Late restoration failed",
            ownsSleepChange: true, sleepRestored: false), to: "status.json")
        model.tick()
        try expect(model.message?.arguments == ["Late restoration failed"] && model.needsRecovery,
                   "Late restoration failure must replace the read error")
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && !model.needsRecovery, "Late successful restoration must re-enable Start")
    }

    static func failedStopWriteCanBeRetried() throws {
        for guardianStarted in [false, true] {
            let environment = try SessionTestEnvironment()
            let model = environment.model()
            model.start()
            let files = environment.sessions.last!
            let path = files.url.appendingPathComponent("control.json")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
            environment.time += 6
            model.tick()
            try expect(model.phase == .failed && model.needsRecovery && model.message?.key == "Could not send the stop request to the guardian.",
                       "A Stop write failure must expose a retry without waiting on the status-read timer")
            model.recover()
            try expect(model.needsRecovery && environment.authorizationRequests == [false],
                       "A repeated I/O failure must not launch another authorization")
            try FileManager.default.removeItem(at: path)
            if guardianStarted {
                try environment.publish("active")
                model.recover()
                let control = try files.read("control.json", as: SessionControl.self)
                try expect(control.stop && environment.authorizationRequests == [false] && model.needsRecovery,
                           "Retry must send Stop to the live guardian without a new authorization")
                try environment.publish("stopped", restored: true)
                model.tick()
            } else {
                model.recover()
            }
            try expect(model.phase == .idle && !model.needsRecovery && !FileManager.default.fileExists(atPath: files.url.path),
                       "Retry after the write obstruction is removed must allow another session")
        }
    }

    static func reopenWithMissingStatusCanBeRetried() throws {
        let environment = try SessionTestEnvironment()
        environment.model().start()
        let files = environment.sessions.last!
        try FileManager.default.removeItem(at: files.url.appendingPathComponent("status.json"))
        let reopened = environment.model()
        try expect(reopened.phase == .failed && reopened.needsRecovery, "Restart must retain a session with missing status")
        environment.disabled = true
        reopened.recover()
        try expect(reopened.needsRecovery, "Missing status cannot be dismissed while system sleep is disabled")
        environment.disabled = false
        reopened.recover()
        try expect(reopened.phase == .idle && !reopened.needsRecovery && environment.defaults.string(forKey: "lastSession") == nil,
                   "With no writer and sleep enabled, retry must release the recovery block even without status")
    }

    static func guardianStartupTimeout() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
        environment.time += 6
        model.tick()
        let path = environment.sessions.last!.url.path
        try expect(model.phase == .failed && !model.needsRecovery
                   && !FileManager.default.fileExists(atPath: path),
                   "An unstarted guardian after authorization must time out and clean up the fenced session")
        try expect(model.message?.key == "The guardian did not start. Sleep settings were not confirmed.", "Startup timeout must explain the unconfirmed state")
        print("PASS: successful authorization without guardian activation times out safely")
    }

    static func lostHelperReplySendsStop() throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        let model = environment.model()
        model.start()
        try expect(model.phase == .authorizing && !model.waitingForPassword && environment.helperRequests.count == 1, "Installed mode must issue one helper request")
        try environment.publish("active")
        environment.helperReplies[0](.failure(WakecupError(message: "reply lost")))
        let control = try environment.sessions.last!.read("control.json", as: SessionControl.self)
        try expect(model.phase == .stopping && control.stop, "Lost helper reply must send stop even when the guardian started")
        model.tick()
        try expect(environment.helperRequests.count == 1 && environment.authorizationRequests.isEmpty, "Lost reply must never replay the helper request or fall back to a password")
        try expect(!environment.assertionsActive, "A stopped startup must not activate local assertions")
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && !model.needsRecovery && model.message?.key == "Helper request failed: %@", "Confirmed restoration after lost reply must retain the request failure explanation")
        print("PASS: lost helper reply sends durable stop and never replays start")
    }

    static func recoveryCompletionAndTimeout() throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        try environment.interruptedSession()
        let model = environment.model()
        try expect(model.phase == .failed && model.needsRecovery, "Interrupted owned sleep change must block new sessions")
        model.start()
        try expect(environment.sessions.count == 1 && environment.helperRequests.isEmpty, "Recovery requirement must reject a new start")
        model.recover()
        try expect(model.phase == .authorizing && environment.helperRequests.count == 1 && environment.helperRequests[0].restoreOnly, "Recovery must request restore-only for the existing session")
        environment.helperReplies[0](.success(4242))
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && !model.needsRecovery, "Restored terminal status must finish recovery")

        let timeout = try SessionTestEnvironment()
        timeout.installedHelper = true
        try timeout.interruptedSession()
        let waiting = timeout.model()
        waiting.recover()
        timeout.time += 29
        waiting.tick()
        try expect(waiting.phase == .authorizing && waiting.needsRecovery, "Recovery must remain pending before the 30-second limit")
        timeout.time += 2
        waiting.tick()
        try expect(waiting.phase == .failed && waiting.needsRecovery, "Recovery timeout must retain the recovery requirement")
        try timeout.publish("stopped", restored: true)
        waiting.tick()
        try expect(waiting.phase == .idle && !waiting.needsRecovery && timeout.helperRequests.count == 1, "Late restoration must clear recovery without another root request")
        print("PASS: restore-only recovery, recovery timeout and late restoration")
    }

    static func lateRecoveryReplyCannotFailNewAttempt() throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        try environment.interruptedSession()
        let model = environment.model()
        model.recover()
        let oldReply = environment.helperReplies[0]
        environment.time += 31
        model.tick()
        try expect(model.phase == .failed && model.needsRecovery, "Recovery must time out after 30 seconds")
        model.recover()
        try expect(model.phase == .authorizing && environment.helperReplies.count == 2, "A timed-out recovery may be retried")
        oldReply(.failure(WakecupError(message: "old request timed out")))
        try expect(model.phase == .authorizing && model.needsRecovery, "An old reply must not fail a new recovery attempt")
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && !model.needsRecovery, "Late confirmed restoration must still be accepted")
        print("PASS: late helper replies cannot change a new recovery attempt")
    }

    static func helperRecoveryFailureIsImmediate() throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        try environment.interruptedSession()
        let model = environment.model()
        let files = environment.sessions.last!
        let before = try Data(contentsOf: files.url.appendingPathComponent("status.json"))
        model.recover()
        try expect(model.phase == .authorizing && environment.helperReplies.count == 1, "Recovery must issue one helper request")
        environment.helperReplies[0](.failure(WakecupError(message: "Automatic recovery could not establish exclusive ownership. Try recovery again; if it still fails, use the manual recovery guide.")))
        try expect(environment.time == 1_000 && model.phase == .failed && model.needsRecovery,
            "Recovery refusal must leave busy state immediately without waiting for the 30-second timeout")
        try expect(model.message?.key == "Helper request failed: %@" && environment.helperRequests.count == 1
            && environment.authorizationRequests.isEmpty, "Refusal must show its reason without replay or password fallback")
        let after = try Data(contentsOf: files.url.appendingPathComponent("status.json"))
        try expect(after == before,
            "Reporting a failed recovery must preserve the original ownership/restoration status")
        print("PASS: helper recovery refusal is immediate, preserves ownership and never retries privileged work")
    }

    static func startupSafetyFailures() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        environment.disabled = true
        model.start()
        try expect(model.phase == .failed && environment.sessions.isEmpty && environment.authorizationRequests.isEmpty, "An existing disabled-sleep setting must prevent privileged startup")
        environment.disabled = false
        environment.power = nil
        model.start()
        try expect(model.phase == .failed && environment.sessions.isEmpty, "Unknown power must reject startup before creating session files")
        environment.power = PowerState(onAC: true, percent: 80)
        environment.assertionFailure = WakecupError(message: "assertions refused")
        model.editClosedLid(false)
        model.start()
        try expect(model.phase == .failed && !environment.assertionsActive && model.deadline == nil, "Assertion failure must leave a failed session without an active timer")
        print("PASS: preflight and assertion failures do not start an unsafe session")
    }
    static func stopDuringAuthorizationAndIgnoreOldReply() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        let previousFiles = environment.sessions.last!
        model.stop()
        let control = try previousFiles.read("control.json", as: SessionControl.self)
        try expect(model.phase == .stopping && control.stop && environment.authorizationCancellations == 1,
            "Stop while awaiting a password must cancel authorization and persist stop")
        try previousFiles.write(SessionStatus(phase: "stopped"), to: "status.json")
        model.tick()
        model.start()
        try expect(model.phase == .authorizing && environment.authorizationRequests.count == 2, "A clean stop must permit a new request")
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "-128"))
        let currentControl = try environment.sessions.last!.read("control.json", as: SessionControl.self)
        try expect(model.phase == .authorizing && !currentControl.stop && model.message == nil,
            "An old authorization reply must not cancel the new session")
        print("PASS: stop cancels pending authorization and old replies cannot change a new session")
    }

    static func passwordRecoveryAndFailedRestoration() throws {
        let environment = try SessionTestEnvironment()
        try environment.interruptedSession()
        let model = environment.model()
        model.recover()
        try expect(model.waitingForPassword && environment.authorizationRequests == [true], "Password recovery must request restore-only authorization")
        try environment.publish("stopped", restored: true)
        environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
        try expect(model.phase == .idle && !model.needsRecovery, "Password recovery must finish only after restored status")

        let failed = try SessionTestEnvironment()
        try failed.interruptedSession()
        let failure = failed.model()
        failure.recover()
        failed.authorizationReplies[0](CommandOutput(status: 1, text: "-128"))
        try expect(failure.phase == .failed && failure.needsRecovery, "Cancelled recovery must preserve the recovery requirement")
        try failed.publish("failed")
        failure.tick()
        try expect(failure.needsRecovery, "A failed status without restoration must not clear recovery")
        print("PASS: password recovery accepts confirmed restoration and preserves failed recovery")
    }

    static func missingStatusTimeout() throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        let model = environment.model()
        model.start()
        try environment.publish("active", deadline: nil)
        model.tick()
        let statusURL = environment.sessions.last!.url.appendingPathComponent("status.json")
        try FileManager.default.removeItem(at: statusURL)
        environment.time += 35 * 24 * 60 * 60
        model.tick()
        try expect(model.phase == .active && model.deadline == nil, "A single missing snapshot must not end a long-running indefinite session")
        try environment.publish("active", deadline: nil)
        environment.time += 9
        model.tick()
        try FileManager.default.removeItem(at: statusURL)
        environment.time += 2
        model.tick()
        try expect(model.phase == .active, "A successful read must reset the timeout")
        environment.time += 10
        model.tick()
        let control = try environment.sessions.last!.read("control.json", as: SessionControl.self)
        try expect(model.phase == .failed && control.stop && model.message?.key == "Could not read guardian state.",
            "Unreadable guardian status must time out and send stop")
        try expect(environment.helperRequests.count == 1, "Status-read timeout must not replay the helper request")
        print("PASS: unreadable guardian status times out with a durable stop")
    }

}

// No installed-daemon inspection or desktop interaction during model checks.
private func isolatedHelper(_ defaults: UserDefaults) -> PrivilegedHelperController {
    PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) },
        requestInformation: { _ in }, interaction: .inert)
}

private extension SessionModelTests {
    static func helperReadinessGate() throws {
        let environment = try SessionTestEnvironment()
        environment.defaults.set(true, forKey: "useInstalledHelper")
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        var reply: ((Result<HelperInformation, Error>) -> Void)?
        let helper = PrivilegedHelperController(defaults: environment.defaults,
            inspectInstallation: { .init(state: .ready, manifest: manifest) },
            requestInformation: { reply = $0 },
            interaction: .inert)
        let model = SessionModel(defaults: environment.defaults, operations: environment.operations, helper: helper)
        model.start()
        try expect(helper.checking && environment.sessions.isEmpty && environment.authorizationRequests.isEmpty,
                   "Starting must wait for the selected helper readiness check without silently requesting a password")
        reply?(.failure(WakecupError(message: "test unavailable")))
        model.start()
        try expect(helper.selected && !helper.usesHelper && model.waitingForPassword && environment.authorizationRequests == [false],
                   "An unavailable selected helper must permit explicit password fallback without forgetting intent")
        print("PASS: pending helper readiness blocks Start; failed check allows explicit password fallback")
    }
}

private extension SessionTestEnvironment {
    func publishSettings(revision: UInt64, mode: PowerMode, threshold: Int,
                         deadline: TimeInterval?, error: String? = nil) throws {
        try sessions.last!.write(SessionStatus(phase: "active", helperPID: 4242, phaseChangedAt: time,
            deadline: deadline, ownsSleepChange: true, sleepRestored: false,
            bootID: "test-boot", settingsRevision: revision, settingsError: error, powerMode: mode,
            threshold: threshold), to: "status.json")
    }
}

private extension SessionModelTests {
    static func liveSettingsTests() throws {
        let cases: [(String, () throws -> Void)] = [
            ("live threshold", liveThresholdSafety),
            ("open-lid settings draft", openLidSettingsDraft),
            ("guardian acknowledgement", guardianSettingsAcknowledgement),
            ("settings timeout", guardianSettingsTimeout),
            ("remaining duration", remainingDurationApply),
            ("combined duration and power", combinedDurationAndPowerDraft),
            ("precise end time", preciseEndTime),
            ("mode restart", modeRestartPreservesDeadline),
            ("combined lid restart", combinedLidRestart),
            ("guardian exit", restartWaitsForGuardianExit),
            ("restart authorization refusal", restartAuthorizationRefusal),
            ("lid safety", modeChangeRequiresOpenLid),
            ("authorization expiry", restartExpiryDuringAuthorization),
            ("restart stop", stopCancelsModeRestart)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            do { try test(); print("PASS: live settings — " + name) }
            catch { failures.append(name + ": " + error.localizedDescription) }
        }
        guard failures.isEmpty else { throw WakecupError(message: failures.joined(separator: "\n")) }
    }

    static func liveThresholdSafety() throws {
        let saved = try SessionTestEnvironment()
        saved.defaults.set(90.0, forKey: "threshold")
        let restored = saved.model()
        try expect(restored.threshold == 90, "A saved high threshold must survive relaunch")
        restored.editThreshold(80)
        try expect(restored.threshold == 80 && saved.defaults.double(forKey: "threshold") == 80, "The idle model must persist thresholds above 50")
        let environment = try SessionTestEnvironment()
        environment.power = PowerState(onAC: false, percent: 40)
        let model = environment.model()
        model.editClosedLid(false)
        model.start()
        let originalDeadline = model.deadline
        for invalid in [9.0, 91, 20.5, Double.nan, Double.infinity] {
            model.editThreshold(invalid)
            try expect(model.phase == .active && model.threshold == 20 && model.deadline == originalDeadline
                && model.settingsMessage != nil, "Invalid thresholds must leave the running policy and timer unchanged")
        }
        model.editThreshold(30)
        model.applySettingsDraft()
        try expect(model.phase == .active && model.threshold == 30 && model.deadline == originalDeadline
            && !model.settingsApplying, "An open-lid threshold change must apply immediately without resetting time")
        model.editThreshold(50)
        model.applySettingsDraft()
        try expect(model.phase == .idle && !environment.assertionsActive && model.message?.arguments == ["заряд достиг порога 50%"],
            "Raising the live threshold above current charge must stop on that same change")
        try expect(environment.authorizationRequests.isEmpty && environment.helperRequests.isEmpty,
            "Open-lid settings must never request authorization")
    }

    static func openLidSettingsDraft() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.start()
        defer { model.stop() }
        let originalDeadline = model.deadline
        let draftDate = model.currentDate.addingTimeInterval(240)
        model.editClosedLid(true)
        model.editAllowBattery(false)
        model.editThreshold(30)
        model.selectEndDate(draftDate)
        model.selectDisplayMode(.keepOn)
        environment.time += 12
        model.tick()
        try expect(model.canApplySettingsDraft && model.selectedEndDate == draftDate
            && model.selectedClosedLid && !model.selectedAllowBattery && model.selectedThreshold == 30
            && model.displayModeDraft == .keepOn && model.deadline == originalDeadline
            && !model.closedLid && model.allowBattery && model.threshold == 20 && model.displayMode == .mayTurnOff,
            "Editing and ticking must keep the draft separate from the running settings")
        model.discardSettingsDraft()
        try expect(!model.hasSettingsDraft && model.selectedEndDate == model.endDate
            && !model.selectedClosedLid && model.selectedAllowBattery && model.selectedThreshold == 20
            && model.displayModeDraft == nil, "Cancel must discard the whole draft")

        model.editAllowBattery(false)
        model.editThreshold(30)
        model.selectDisplayMode(.keepOn)
        model.setEndTimeInputInvalid(true)
        model.applySettingsDraft()
        try expect(!model.canApplySettingsDraft && model.allowBattery && model.threshold == 20
            && model.displayMode == .mayTurnOff, "Invalid time must block the entire batch")

        model.discardSettingsDraft()
        model.editAllowBattery(false)
        model.editThreshold(30)
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try expect(!model.hasSettingsDraft && !model.allowBattery && model.threshold == 30
            && model.displayMode == .keepOn && model.deadline == originalDeadline,
            "One Apply must update the power and display settings and preserve the untouched timer")
    }

    static func guardianSettingsAcknowledgement() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        try environment.publish("active")
        model.tick()
        let files = environment.sessions.last!
        let originalConfig = try files.read("configuration.json", as: SessionConfiguration.self)
        let originalAssertions = environment.assertionDisplays
        model.selectDisplayMode(.keepOn)
        model.editThreshold(30)
        model.editAllowBattery(false)
        model.applySettingsDraft()
        let first = try files.read("control.json", as: SessionControl.self).update!
        try expect(model.settingsApplying && first.revision == 1 && first.threshold == 30 && first.powerMode == .ac
            && first.deadline == 4_600 && model.allowBattery && model.threshold == 20,
            "One request must carry both power edits and keep the confirmed policy until acknowledgement")
        try expect(model.displayMode == .mayTurnOff && environment.assertionDisplays == originalAssertions,
            "The display change must wait for the guardian")
        try environment.publishSettings(revision: 0, mode: .battery, threshold: 20, deadline: 4_600)
        model.tick()
        try expect(model.settingsApplying && model.selectedThreshold == 30 && !model.selectedAllowBattery,
            "An older acknowledgement must not resolve the draft")
        try environment.publishSettings(revision: first.revision, mode: .battery, threshold: 20, deadline: 4_600,
            error: PowerRestriction.invalidThreshold.reason)
        model.tick()
        try expect(!model.settingsApplying && model.allowBattery && model.threshold == 20 && model.settingsMessage != nil
            && model.phase == .active && model.deadline == 4_600 && model.hasSettingsDraft,
            "A rejected update must show the error and retain the draft with the confirmed policy still effective")
        try expect(model.displayMode == .mayTurnOff && model.displayModeDraft == .keepOn
            && environment.assertionDisplays == originalAssertions, "Rejection must leave the display change unapplied")
        model.editAllowBattery(true)
        model.editThreshold(35)
        model.applySettingsDraft()
        let retry = try files.read("control.json", as: SessionControl.self).update!
        try environment.publishSettings(revision: retry.revision, mode: .battery, threshold: 35, deadline: 4_600)
        model.tick()
        try expect(retry.revision == 2 && !model.settingsApplying && model.settingsMessage == nil
            && model.threshold == 35 && environment.defaults.double(forKey: "threshold") == 35,
            "A later accepted revision must clear the error and persist the effective setting")
        try expect(!model.hasSettingsDraft && model.displayMode == .keepOn
            && environment.assertionDisplays == originalAssertions + [true],
            "An accepted revision must apply the staged display change once")
        try expect(try files.read("configuration.json", as: SessionConfiguration.self) == originalConfig,
            "Live settings must leave immutable guardian configuration unchanged")
        try expect(environment.authorizationRequests == [false] && environment.helperRequests.isEmpty
            && environment.sessions.count == 1, "Live policy changes must not restart or reauthorize the guardian")
        model.stop()
    }

    static func guardianSettingsTimeout() throws {
        try expectGuardianSettingsTimeout(replyArrivedBeforeNextTick: false)
        try expectGuardianSettingsTimeout(replyArrivedBeforeNextTick: true)
    }

    static func expectGuardianSettingsTimeout(replyArrivedBeforeNextTick: Bool) throws {
        let environment = try SessionTestEnvironment()
        environment.installedHelper = true
        let model = environment.model()
        model.start()
        try environment.publish("active")
        model.tick()
        model.editThreshold(30)
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        environment.time += 9
        if replyArrivedBeforeNextTick {
            try environment.publishSettings(revision: 1, mode: .battery, threshold: 30, deadline: 6_000)
        } else {
            try environment.publish("active")
        }
        model.tick()
        try expect(model.phase == .stopping && environment.assertionsActive
            && model.threshold == 20 && model.deadline == 4_600 && model.displayMode == .mayTurnOff,
            "The timeout must request a safe stop before accepting a late acknowledgement or applying its display change")
        try expect(try environment.sessions.last!.read("control.json", as: SessionControl.self).stop,
            "Settings timeout must persist the stop request")
        try expect(environment.helperRequests.count == 1 && environment.authorizationRequests.isEmpty,
            "Settings acknowledgement timeout must never replay a privileged start")
        try environment.publishSettings(revision: 1, mode: .battery, threshold: 30, deadline: nil)
        model.tick()
        try expect(model.phase == .stopping && model.threshold == 20
            && model.settingsMessage?.key == "Could not confirm the new settings.",
            "A late acknowledgement must not overwrite the settings or erase the error while stopping")
        try environment.publish("stopped", restored: true)
        model.tick()
        try expect(model.phase == .idle && model.message == nil && !model.showsSettingsActions
            && model.settingsMessage?.key == "Could not confirm the new settings.",
            "A settings acknowledgement failure must remain in the footer after the stop")
        environment.power = PowerState(onAC: false, percent: 25)
        model.tick()
        try expect(model.threshold == 20 && model.startPowerRestriction == nil
            && environment.defaults.double(forKey: "threshold") == 20,
            "An unconfirmed threshold must not affect the next session")
    }

    static func remainingDurationApply() throws {
        for closedLid in [false, true] {
            let environment = try SessionTestEnvironment()
            let model = environment.model()
            model.editClosedLid(closedLid)
            model.start()
            if closedLid { try environment.publish("active"); model.tick() }
            let files = environment.sessions.last
            environment.time = 1_061
            if closedLid { try environment.publish("active") }
            model.tick()
            try expect(model.selectedEndDate == model.endDate && !model.durationEditDirty && model.deadline == 4_600,
                "Untouched duration fields must follow the remaining time without changing the deadline")
            let draft = model.currentDate.addingTimeInterval(159)
            model.selectEndDate(draft)
            environment.time = 1_100
            if closedLid { try environment.publish("active") }
            model.tick()
            try expect(model.durationEditDirty && model.selectedEndDate == draft && model.deadline == 4_600,
                "Editing and ticks must preserve a dirty duration draft without applying it")
            model.applySettingsDraft()
            if let files {
                let update = try files.read("control.json", as: SessionControl.self).update!
                try expect(update.deadline == 1_220 && model.settingsApplying && model.deadline == 4_600,
                    "Duration Apply must send remaining time from Apply and wait for the acknowledged deadline")
                try environment.publishSettings(revision: update.revision, mode: .battery, threshold: 20, deadline: 1_220)
                model.tick()
            }
            try expect(model.deadline == 1_220 && model.remaining == 120 && !model.durationEditDirty,
                "Acknowledged duration Apply must replace the active remaining duration")
            environment.time = 1_161
            if let files {
                let revision = try files.read("control.json", as: SessionControl.self).update!.revision
                try environment.publishSettings(revision: revision, mode: .battery, threshold: 20, deadline: 1_220)
            }
            model.tick()
            try expect(model.selectedEndDate == model.endDate && !model.durationEditDirty,
                "After Apply the untouched editor must resume following remaining time")
            model.selectEndTimePreset(0)
            try expect(model.durationEditDirty && model.deadline == 1_220, "Selecting infinity must remain a draft until Apply")
            model.applySettingsDraft()
            if let files {
                let update = try files.read("control.json", as: SessionControl.self).update!
                try expect(update.deadline == nil, "Infinity Apply must encode an absent deadline")
                try environment.publishSettings(revision: update.revision, mode: .battery, threshold: 20, deadline: nil)
                model.tick()
            }
            try expect(model.deadline == nil && model.selectedEndDate == nil && !model.durationEditDirty, "Infinity must become effective after Apply")
            model.selectEndDate(model.currentDate.addingTimeInterval(60))
            model.applySettingsDraft()
            if let files {
                let update = try files.read("control.json", as: SessionControl.self).update!
                try environment.publishSettings(revision: update.revision, mode: .battery, threshold: 20, deadline: 1_221)
                model.tick()
            }
            try expect(model.deadline == 1_221 && !model.durationEditDirty, "An infinite session must accept a finite remaining-time replacement")
            try expect(environment.authorizationRequests.count == (closedLid ? 1 : 0) && environment.sessions.count == (closedLid ? 1 : 0),
                "All duration replacements must preserve the running session and authorization count")
            model.stop()
        }
    }

    static func combinedDurationAndPowerDraft() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.start()
        try environment.publish("active")
        model.tick()
        model.selectEndTimePreset(180)
        model.editThreshold(35)
        model.applySettingsDraft()
        let files = environment.sessions.last!
        let update = try files.read("control.json", as: SessionControl.self).update!
        try expect(update.revision == 1 && update.threshold == 35 && update.deadline == 11_800,
            "One Apply must send the new timer and threshold in the same revision")
        model.selectEndDate(model.currentDate.addingTimeInterval(660))
        model.editThreshold(40)
        model.applySettingsDraft()
        try expect(try files.read("control.json", as: SessionControl.self).update == update,
            "Edits while waiting for the helper must not send a second request")
        try environment.publishSettings(revision: update.revision, mode: .battery, threshold: 35, deadline: 11_800)
        model.tick()
        try expect(model.deadline == 11_800 && model.threshold == 35 && !model.settingsApplying && !model.hasSettingsDraft,
            "Acknowledgement must make both settings effective and close the draft")
        let savedData = environment.defaults.data(forKey: "endTimeChoice")!
        let saved = try JSONDecoder().decode(EndTimeSelection.Choice.self, from: savedData)
        guard case .preset(.threeHours, date: nil) = saved else {
            throw WakecupError(message: "Only the acknowledged preset must be persisted")
        }
        model.stop()
    }

    static func modeRestartPreservesDeadline() throws {
        for sourceClosed in [false, true] {
            for infinite in [false, true] {
                let environment = try SessionTestEnvironment()
                let model = environment.model()
                model.editClosedLid(sourceClosed)
                model.selectEndTimePreset(infinite ? 0 : 60)
                model.start()
                if sourceClosed { try environment.publish("active", deadline: infinite ? nil : 4_600); model.tick() }
                let oldFiles = environment.sessions.last
                let originalDeadline = model.deadline
                environment.time += 7
                model.editClosedLid(!sourceClosed)
                model.applySettingsDraft()
                try expect(model.isRestarting && model.deadline == originalDeadline && environment.assertionsActive
                    && environment.assertionStops == 0, "Internal mode restart must retain the exact deadline and assertions throughout handoff")
                if sourceClosed {
                    try expect(model.phase == .stopping && environment.sessions.count == 1,
                        "Leaving closed-lid mode must await restoration before creating a replacement")
                    try expect(try oldFiles?.read("control.json", as: SessionControl.self).stop == true,
                        "Leaving closed-lid mode must persist stop for the old guardian")
                    try environment.publish("stopped", restored: true, deadline: originalDeadline)
                    model.tick()
                } else {
                    try expect(model.phase == .authorizing && model.waitingForPassword,
                        "Entering closed-lid mode must use one explicit authorization")
                    environment.time += 9
                    environment.authorizationReplies[0](CommandOutput(status: 0, text: ""))
                    try environment.publish("active", deadline: originalDeadline)
                    model.tick()
                }
                try expect(environment.sessions.count == 1 && model.closedLid == !sourceClosed
                    && model.deadline == originalDeadline
                    && model.phase == .active && !model.isRestarting && environment.assertionsActive
                    && environment.assertionStops == 0,
                    "Both restart directions must preserve finite or infinite time, including handoff/authorization latency")
                try expect((model.deadline == nil) == infinite && environment.authorizationRequests == [false],
                    "Infinity must stay infinite and mode handoff must request authorization only for the closed-lid launch")
                if !sourceClosed {
                    let replacement = try environment.sessions.last!.read("configuration.json", as: SessionConfiguration.self)
                    try expect(replacement.absoluteDeadline == originalDeadline && (replacement.duration == nil) == infinite,
                               "Closed-lid launch must pass the same deadline to the guardian")
                }
                if sourceClosed {
                    environment.authorizationReplies[0](CommandOutput(status: 1, text: "-128"))
                    try expect(model.phase == .active && !model.closedLid, "A stale old guardian authorization reply must not cancel the replacement session")
                }
                model.stop()
            }
        }
    }

    static func combinedLidRestart() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.start()
        defer { model.stop() }
        let originalDeadline = model.deadline
        let deadline = environment.time + 40 * 60
        model.editClosedLid(true)
        model.editThreshold(26)
        model.selectEndDate(model.currentDate.addingTimeInterval(40 * 60))
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()

        let configuration = try environment.sessions.last!.read("configuration.json", as: SessionConfiguration.self)
        try expect(configuration.absoluteDeadline == deadline && configuration.threshold == 26,
            "The replacement guardian must start with the proposed timer and power policy")
        try expect(model.isRestarting && model.deadline == originalDeadline && model.displayMode == .mayTurnOff
            && environment.assertionDisplays == [false], "Authorization must not apply the new timer or display mode")
        try environment.publish("active", deadline: deadline)
        model.tick()
        try expect(model.phase == .active && !model.isRestarting && model.closedLid && model.deadline == deadline
            && model.threshold == 26 && model.displayMode == .keepOn && !model.hasSettingsDraft
            && environment.assertionDisplays.last == true && environment.assertionDisplays.filter { $0 }.count == 1,
            "Only a successful lid restart may apply the combined draft")
    }

    static func restartWaitsForGuardianExit() throws {
        for timeout in [false, true] {
            let environment = try SessionTestEnvironment()
            environment.installedHelper = true
            let model = environment.model()
            model.start()
            try environment.publish("active")
            model.tick()
            environment.guardianRunning = true
            model.editClosedLid(false)
            model.applySettingsDraft()
            try environment.publish("stopped", restored: true)
            model.tick()
            try expect(model.isRestarting && model.phase == .stopping && environment.sessions.count == 1
                && environment.assertionsActive, "Restored status alone must not restart while the prior guardian still exists")
            environment.time += timeout ? 6 : 4
            model.tick()
            if timeout {
                try expect(model.phase == .failed && !model.isRestarting && model.closedLid && environment.sessions.count == 1
                    && !environment.assertionsActive && !model.needsRecovery,
                    "Guardian exit timeout must stop safely without creating another session or losing restoration confirmation")
                try expect(model.message == nil && !model.showsSettingsActions
                    && model.settingsMessage?.key == "The previous guardian has not exited. Wakecup could not apply the change.",
                    "A restart timeout must show its specific error only in the footer")
            } else {
                try expect(model.isRestarting && environment.sessions.count == 1, "Guardian-exit wait must remain pending within its timeout")
                environment.guardianRunning = false
                model.tick()
                try expect(model.phase == .active && !model.closedLid && !model.isRestarting
                    && environment.sessions.count == 1 && environment.assertionStops == 0,
                    "Confirmed guardian exit must complete handoff without dropping assertions")
                model.stop()
            }
            try expect(environment.helperRequests.count == 1 && environment.authorizationRequests.isEmpty,
                "Waiting for guardian exit must not retry privileged starts")
        }
    }

    static func restartAuthorizationRefusal() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.start()
        model.editClosedLid(true)
        model.applySettingsDraft()
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "cancelled (-128)"))
        try expect(model.phase == .idle && !model.closedLid && !model.isRestarting
            && model.message == nil && !model.showsSettingsActions
            && model.settingsMessage?.key == "Request cancelled. The session was not started.",
            "Cancelling authorization during Apply must report the outcome only in the footer")
    }

    static func modeChangeRequiresOpenLid() throws {
        for sourceClosed in [false, true] {
            for lid: Bool? in [true, nil] {
                let environment = try SessionTestEnvironment()
                environment.lidIsClosed = lid
                let model = environment.model()
                model.editClosedLid(sourceClosed)
                model.start()
                if sourceClosed { try environment.publish("active"); model.tick() }
                model.editClosedLid(!sourceClosed)
                model.applySettingsDraft()
                try expect(model.phase == .active && model.closedLid == sourceClosed && !model.isRestarting
                    && model.settingsMessage?.key == "Open the lid before changing closed-lid mode."
                    && environment.sessions.count == (sourceClosed ? 1 : 0) && environment.assertionsActive,
                    "Closed or unknown lid state must block either internal mode transition")
                try expect(environment.authorizationRequests.count == (sourceClosed ? 1 : 0),
                    "Blocked lid transition must not launch another authorization")
                model.editClosedLid(sourceClosed)
                try expect(!model.hasSettingsDraft && model.settingsMessage == nil,
                    "Returning the switch to its applied value must clear the obsolete draft error")
                model.editClosedLid(!sourceClosed)
                model.applySettingsDraft()
                model.stop()
                if sourceClosed { try environment.publish("stopped", restored: true); model.tick() }
                try expect(!model.hasSettingsDraft && model.settingsMessage == nil,
                    "Stopping with an unapplied draft must clear its error")

            }
        }
    }

    static func restartExpiryDuringAuthorization() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false)
        model.selectEndDate(model.currentDate.addingTimeInterval(60))
        model.start()
        environment.time = 1_050
        model.editClosedLid(true)
        model.applySettingsDraft()
        let replacement = try environment.sessions.last!.read("configuration.json", as: SessionConfiguration.self)
        try expect(replacement.absoluteDeadline == 1_060 && model.isRestarting,
            "Authorization must carry the original continuous-clock deadline")
        environment.time = 1_061
        model.tick()
        try expect(!model.isRestarting && model.phase == .stopping && !model.closedLid
            && environment.authorizationCancellations == 1,
            "Expiry during authorization must cancel restart and stop the pending guardian")
        try expect(try environment.sessions.last!.read("control.json", as: SessionControl.self).stop,
            "Expired restart must durably prevent guardian activation")
        try environment.publish("active", deadline: 1_060)
        environment.authorizationReplies[0](CommandOutput(status: 1, text: "cancelled (-128)"))
        model.tick()
        try expect(model.phase == .stopping && environment.sessions.count == 1,
            "Late authorization or active status must never revive an expired restart")
        try environment.publish("stopped", restored: true, deadline: 1_060)
        model.tick()
        try expect(model.phase == .idle && !environment.assertionsActive
            && model.message?.key == "The Wakecup timer ended. “Keep awake with lid closed” was not changed." && environment.authorizationRequests == [false],
            "A late authorization cancellation must preserve the reason the lid setting was not applied")
    }

    static func stopCancelsModeRestart() throws {
        for sourceClosed in [false, true] {
            let environment = try SessionTestEnvironment()
            let model = environment.model()
            model.editClosedLid(sourceClosed)
            model.start()
            if sourceClosed { try environment.publish("active"); model.tick() }
            model.editClosedLid(!sourceClosed)
            model.applySettingsDraft()
            model.stop()
            try expect(!model.isRestarting && model.closedLid == sourceClosed && model.phase == .stopping,
                "Manual Stop must cancel either pending mode restart and restore the previous preference")
            try environment.publish("stopped", restored: true)
            model.tick()
            if !sourceClosed { environment.authorizationReplies[0](CommandOutput(status: 0, text: "")) }
            try expect(model.phase == .idle && !environment.assertionsActive
                && environment.sessions.count == 1
                && environment.authorizationRequests == [false],
                "Stopping during restart must never start or revive a replacement after restoration")
        }
    }
}

private extension SessionModelTests {
    static func preciseEndTime() throws {
        let environment = try SessionTestEnvironment()
        let model = environment.model()
        model.editClosedLid(false); model.selectEndTimePreset(60); model.start()
        environment.time += 0.25 // The UI can render between clock ticks.
        let expected = model.currentDate.addingTimeInterval(model.deadline! - environment.time)
        try expect(abs(model.endDate!.timeIntervalSince(expected)) < 0.05,
                   "The end time must use the authoritative clock without rounding remaining seconds")
        model.stop()
    }
}
