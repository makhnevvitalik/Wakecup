import Foundation

// Actual client reply decoding, controller state and model recovery, with inert
// operation closures: no XPC, authorization, installation or system registrations.
@main struct HelperRetryTests {
    private static var checks = 0
    private static let rejection = "Automatic recovery could not establish exclusive ownership. Try recovery again; if it still fails, use the manual recovery guide."

    static func main() {
        do {
            let pid = try HelperClient.startResult(pid: 42, error: nil).get()
            try expect(pid == 42, "A valid successful reply must retain the guard PID")
            try checkRetry(after: HelperClient.startResult(pid: 0, error: rejection), remainsReady: true)
            try checkRetry(after: HelperClient.startResult(pid: 0, error: "A different operation was rejected."), remainsReady: true)
            try checkRetry(after: .failure(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted,
                userInfo: [NSLocalizedDescriptionKey: "The helper connection was interrupted."])), remainsReady: false)
            try checkRetry(after: HelperClient.startResult(pid: 0, error: nil), remainsReady: false)
            try checkRetry(after: HelperClient.startResult(pid: 42, error: rejection), remainsReady: false)
            try checkRetry(after: HelperClient.startResult(pid: 0, error: ""), remainsReady: false)
            try checkRetry(after: HelperClient.startResult(pid: 0, error: String(repeating: "x", count: 16_385)), remainsReady: false)
            try checkRetry(after: .failure(WakecupError(message: "Simulated helper timeout.")),
                           remainsReady: false, finishOlderHealthCheck: true)
            try checkStaleTransportReplies()
            print("PASS: \(checks) helper operation, transport, malformed-reply and recovery retry checks")
        } catch {
            FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func checkStaleTransportReplies() throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "useInstalledHelper")
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        let information = HelperInformation(manifest: manifest, clientConfirmed: true)
        var statusReplies: [(Result<HelperInformation, Error>) -> Void] = []
        var startReplies: [(Result<Int32, Error>) -> Void] = []
        let helper = PrivilegedHelperController(defaults: defaults,
            inspectInstallation: { .init(state: .ready, manifest: manifest) },
            requestInformation: { statusReplies.append($0) },
            requestStart: { _, _, completion in startReplies.append(completion) })
        statusReplies[0](.success(information))
        try expect(helper.usesHelper, "The initial health check must confirm readiness")

        let timeout = WakecupError(message: "Simulated delayed helper timeout.")
        var olderReplyDelivered = false
        helper.start(path: "old", restoreOnly: true) { reply in
            if case .failure = reply { olderReplyDelivered = true }
        }
        helper.start(path: "new", restoreOnly: true) { _ in }
        startReplies[1](.success(42))
        startReplies[0](.failure(timeout))
        try expect(olderReplyDelivered && helper.usesHelper,
            "Deliver the old transport failure to its caller without invalidating a newer request")

        helper.start(path: "old-before-refresh", restoreOnly: true) { _ in }
        helper.refresh()
        startReplies[2](.failure(timeout))
        try expect(helper.checking && helper.usesHelper,
            "An older failure must leave a newer health check in progress")
        statusReplies[1](.success(information))
        try expect(!helper.checking && helper.usesHelper, "The pending health confirmation must still be usable")

        helper.start(path: "old-before-confirmation", restoreOnly: true) { _ in }
        helper.refresh()
        statusReplies[2](.success(information))
        startReplies[3](.failure(timeout))
        try expect(helper.usesHelper && helper.detail.isEmpty,
            "An older failure must not replace fresh health confirmation or its diagnostic")

        helper.start(path: "latest", restoreOnly: true) { _ in }
        startReplies[4](.failure(timeout))
        try expect(helper.state == .unavailable && helper.detail == timeout.localizedDescription,
            "The latest transport failure must still mark the helper unavailable")
    }

    private static func checkRetry(after result: Result<Int32, Error>, remainsReady: Bool,
                                   finishOlderHealthCheck: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WakecupHelperRetry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: "useInstalledHelper")
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        var replies: [(Result<Int32, Error>) -> Void] = []
        var requests: [(String, Bool)] = []
        var deferHealthCheck = false
        var healthReply: ((Result<HelperInformation, Error>) -> Void)?
        let information = HelperInformation(manifest: manifest, clientConfirmed: true)
        let helper = PrivilegedHelperController(defaults: defaults,
            inspectInstallation: { .init(state: .ready, manifest: manifest) },
            requestInformation: { reply in
                if deferHealthCheck { healthReply = reply }
                else { reply(.success(information)) }
            },
            requestStart: { path, restoreOnly, completion in requests.append((path, restoreOnly)); replies.append(completion) })
        let configuration = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 60,
            powerMode: .battery, threshold: 20, closedLid: true, keepDisplayOn: false)
        let files = try SessionFiles.create(at: directory, configuration: configuration)
        try files.write(SessionStatus(phase: .failed, helperPID: 4242, phaseChangedAt: 980,
            ownsSleepChange: true, sleepRestored: false), to: "status.json")
        defaults.set(directory.path, forKey: "lastSession")
        var passwordRequests = 0
        let operations = SessionOperations(now: { 1000 }, readPower: { PowerState(onAC: true, percent: 80) },
            readSleepDisabled: { true }, startAssertions: { _ in }, stopAssertions: {}, createFiles: { _ in files },
            guardianResponding: { _, _ in false }, authorization: { _, _ in
                SessionAuthorization(run: { _ in passwordRequests += 1 }, cancel: {})
            }, usesInstalledHelper: { helper.usesHelper }, startHelper: { files, restoreOnly, completion in
                helper.start(path: files.url.path, restoreOnly: restoreOnly, completion: completion)
            }, loginItem: LoginItemController(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        try expect(helper.usesHelper && model.needsRecovery, "A mutually trusted selected helper must handle previous-session recovery")
        if finishOlderHealthCheck {
            deferHealthCheck = true
            helper.refresh()
            try expect(helper.checking && helper.usesHelper, "An ordinary refresh can overlap recovery for a ready helper")
        }
        model.recover()
        try expect(requests.count == 1 && requests[0].0 == directory.path && requests[0].1 && !model.waitingForPassword,
            "Recovery must use the actual controller with the original path and restore-only mode")
        if finishOlderHealthCheck {
            guard let healthReply else { throw WakecupError(message: "Missing deferred health check") }
            healthReply(.success(information))
            try expect(!helper.checking, "The earlier health check must complete before the recovery reply")
        }
        replies[0](result)
        try expect(model.phase == .failed && model.needsRecovery && model.message != nil,
            "A failed recovery must report its error and keep recovery available")
        if case .failure(let error) = result {
            try expect(model.message?.arguments == [error.localizedDescription],
                "Preserving helper readiness must still deliver the original operation error to the user")
        }
        try expect(helper.selected && helper.usesHelper == remainsReady && helper.state == (remainsReady ? .ready : .unavailable),
            remainsReady ? "An operation rejection must preserve the healthy selected helper" : "A transport, trust or malformed reply must invalidate helper availability")
        try expect(requests.count == 1 && passwordRequests == 0, "A failed request must never be automatically replayed or request a password")
        model.recover()
        try expect(requests.count == (remainsReady ? 2 : 1) && passwordRequests == (remainsReady ? 0 : 1),
            remainsReady ? "Explicit recovery retry must reuse the healthy helper without asking for a password" : "An unavailable helper must retain the password fallback on explicit retry")
        if remainsReady {
            try expect(requests[1].0 == directory.path && requests[1].1 && !model.waitingForPassword,
                "The second recovery must still use the same restore-only helper operation")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WakecupError(message: message) }
        checks += 1
    }

    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func data(forKey key: String) -> Data? { values[key] as? Data }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    }
}
