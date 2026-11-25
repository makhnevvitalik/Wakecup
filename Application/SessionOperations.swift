import Foundation

// The model owns lifecycle decisions; these operations supply their system effects.
// Normal launches keep the existing assertions, authorization process and helper.
struct SessionOperations {
    let now: () -> TimeInterval
    let readPower: () -> PowerState?
    let readSleepDisabled: () throws -> Bool
    let startAssertions: (Bool) throws -> Void
    let stopAssertions: () -> Void
    let createFiles: (SessionConfiguration) throws -> SessionFiles
    let guardianResponding: (SessionStatus, TimeInterval) -> Bool
    let authorization: (SessionFiles, Bool) -> SessionAuthorization
    let usesInstalledHelper: () -> Bool
    let startHelper: (SessionFiles, Bool, @escaping (Result<Int32, Error>) -> Void) -> Void
    let loginItem: LoginItemController
    let scheduleTicks: (@escaping () -> Void) -> (() -> Void)
    var wallNow: () -> Date = Date.init
    var readLidClosed: () -> Bool? = { nil }
    var guardianIsRunning: (SessionStatus) -> Bool = { _ in false }
    var enterBacklight: (@escaping BacklightDarkeningPermission, @escaping (Result<Void, Error>, Bool) -> Void) -> Void = { _, complete in
        complete(.failure(WakecupError(message: "Backlight control is unavailable.")), false)
    }
    var restoreBacklight: (DisplayModeController.RestorationPolicy, @escaping (Result<Bool, Error>) -> Void) -> Void = { _, complete in
        complete(.success(true))
    }
    var validateDisplayShortcut: (DisplayShortcut) throws -> Void = { _ in }
    var checkDisplayShortcutConflict: (DisplayShortcut) -> DisplayShortcutConflict? = { _ in nil }
    var registerDisplayShortcut: (DisplayShortcut, @escaping () -> Void) throws -> Void = { _, _ in }
    var unregisterDisplayShortcut: () -> Void = {}
    var readThermalState: () -> ProcessInfo.ThermalState = { .nominal }
    var scheduleThermalChecks: (@escaping () -> Void) -> (() -> Void) = { _ in {} }
    // Enqueue on the same brightness queue as regular display operations.
    var restoreBacklightAfterThermalStop: () -> Void = {}
    var checkBacklight: (@escaping (DisplayModeController.BacklightState) -> Void) -> Void = { $0(.monitoring) }


    var readGuardianStatus: (SessionFiles) throws -> SessionStatus = { try $0.read("status.json", as: SessionStatus.self) }

    static func backgroundThermalChecks(_ sample: @escaping () -> Void) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.setEventHandler(handler: sample)
        timer.resume()
        return { timer.cancel() }
    }

    static func system(helper: PrivilegedHelperController) -> SessionOperations {
        let guardianStatus = GuardianStatusObserver()
        let assertions = SleepAssertions()
        let backlight = BacklightSession()
        let backlightQueue = DispatchQueue(label: "local.wakecup.backlight")
        let displayHotKey = GlobalDisplayHotKey()
        return SessionOperations(now: continuousNow, readPower: readPowerState, readSleepDisabled: readDisabled,
            startAssertions: { try assertions.start(display: $0) }, stopAssertions: assertions.stop,
            createFiles: { configuration in
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Wakecup", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
                try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                return try SessionFiles.create(at: sessions.appendingPathComponent(configuration.id), configuration: configuration)
            }, guardianResponding: { status, now in
                guardianStatus.isResponding(status, at: now)
            }, authorization: SessionAuthorization.system,
            usesInstalledHelper: { helper.usesHelper },
            startHelper: { files, restoreOnly, completion in
                helper.start(path: files.url.path, restoreOnly: restoreOnly, completion: completion)
            }, loginItem: .system, scheduleTicks: { tick in
                let timer = Timer(timeInterval: 1, repeats: true) { _ in tick() }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            }, readLidClosed: lidClosed, guardianIsRunning: { status in
                guard processExists(status.helperPID) else { return false }
                if let expected = status.helperIdentity, let actual = processIdentity(status.helperPID) {
                    return expected == actual
                }
                return true
            }, enterBacklight: { performDarkening, complete in
                backlightQueue.async {
                    let result = Result { try backlight.begin(performDarkening: performDarkening) }
                    let needsRestoration = backlight.needsRestoration
                    DispatchQueue.main.async { complete(result, needsRestoration) }
                }
            }, restoreBacklight: { policy, complete in
                backlightQueue.async {
                    let result = Result {
                        switch policy {
                        case .saved:
                            try backlight.restore()
                        case .preserveVisible:
                            try backlight.restore(preservingVisibleBrightness: true)
                        case .visibleOnly:
                            return try backlight.endIfBrightnessReturned()
                        }
                        return true
                    }
                    DispatchQueue.main.async { complete(result) }
                }
            }, validateDisplayShortcut: displayHotKey.validate,
               checkDisplayShortcutConflict: { shortcut in
                   if Thread.isMainThread {
                       return MainActor.assumeIsolated { DisplayShortcutConflictDetector.conflict(for: shortcut) }
                   }
                   return DispatchQueue.main.sync { DisplayShortcutConflictDetector.conflict(for: shortcut) }
               },
               registerDisplayShortcut: displayHotKey.register,
               unregisterDisplayShortcut: displayHotKey.unregister,
               readThermalState: { ProcessInfo.processInfo.thermalState },
               scheduleThermalChecks: backgroundThermalChecks,
               restoreBacklightAfterThermalStop: {
                   backlightQueue.async { try? backlight.restore(preservingVisibleBrightness: true) }
               },
               checkBacklight: { complete in
                   backlightQueue.async {
                       // The controller decides which request wins before recovery state is changed.
                       let state: DisplayModeController.BacklightState
                       if backlight.hasVisibleBrightness { state = .brightnessReturned }
                       else { state = backlight.isHealthy ? .monitoring : .restorerStopped }
                       DispatchQueue.main.async { complete(state) }
                   }
               })
    }
}

// Reference identity rejects an old authorization reply after a new request.
final class SessionAuthorization {
    let run: (@escaping (CommandOutput) -> Void) throws -> Void
    let cancel: () -> Void

    init(run: @escaping (@escaping (CommandOutput) -> Void) throws -> Void, cancel: @escaping () -> Void) {
        self.run = run
        self.cancel = cancel
    }

    static func system(files: SessionFiles, restoreOnly: Bool) -> SessionAuthorization {
        var task: Process?
        return SessionAuthorization(run: { completion in
            let prepared = try HelperAuthorization.guardTask(files: files, restoreOnly: restoreOnly)
            task = prepared
            let pipe = Pipe()
            prepared.standardOutput = pipe
            prepared.standardError = pipe
            try prepared.run()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                prepared.waitUntilExit()
                let result = CommandOutput(status: prepared.terminationStatus, text: String(decoding: data, as: UTF8.self))
                DispatchQueue.main.async { completion(result) }
            }
        }, cancel: { if let task, task.isRunning { task.terminate() } })
    }
}
