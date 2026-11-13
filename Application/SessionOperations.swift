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
    var enterBacklight: (DisplayShortcut, @escaping () -> Void, @escaping (Result<Void, Error>, Bool) -> Void) -> Void = { _, _, complete in
        complete(.failure(WakecupError(message: "Backlight control is unavailable.")), false)
    }
    var restoreBacklight: (@escaping (Result<Void, Error>) -> Void) -> Void = { $0(.success(())) }
    var validateDisplayShortcut: (DisplayShortcut) throws -> Void = { _ in }
    var checkBacklightHealth: (@escaping (Bool) -> Void) -> Void = { $0(true) }


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
            }, enterBacklight: { shortcut, handler, complete in
                do { try displayHotKey.register(shortcut, handler: handler) }
                catch { complete(.failure(error), false); return }
                backlightQueue.async {
                    let result = Result { try backlight.begin() }
                    let needsRestoration = backlight.needsRestoration
                    DispatchQueue.main.async {
                        // Keep the escape shortcut armed after an uncertain rollback.
                        if !needsRestoration { displayHotKey.unregister() }
                        complete(result, needsRestoration)
                    }
                }
            }, restoreBacklight: { complete in
                backlightQueue.async {
                    let result = Result { try backlight.restore() }
                    DispatchQueue.main.async {
                        if case .success = result { displayHotKey.unregister() }
                        complete(result)
                    }
                }
            }, validateDisplayShortcut: GlobalDisplayHotKey.validate,
               checkBacklightHealth: { complete in
                   backlightQueue.async {
                       let healthy = backlight.isHealthy
                       DispatchQueue.main.async { complete(healthy) }
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
