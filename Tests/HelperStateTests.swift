import Foundation

// No windows, app activation, root helper, system installation, sleep changes or shared preferences.
@main struct HelperStateTests {
    private static let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion,
        ownerUID: getuid(), clientHash: String(repeating: "a", count: 40),
        helperHash: HelperBuildIdentity.cdHash, helperSHA256: HelperBuildIdentity.sha256)
    private static var checks = 0

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let ui = HeadlessInteraction()
        let suite = "WakecupHelperStateTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "useInstalledHelper")
        var inspection = PrivilegedHelperController.Inspection(state: .ready, manifest: manifest)
        var replies: [(Result<HelperInformation, Error>) -> Void] = []
        let helper = PrivilegedHelperController(defaults: defaults,
            inspectInstallation: { inspection }, requestInformation: { replies.append($0) }, interaction: ui.value)
        try expect(helper.selected && !helper.usesHelper && helper.checking && !helper.working,
                   "A file-only inspection must wait for mutual trust without losing helper intent")
        helper.refresh(); helper.refresh()
        try expect(replies.count == 1, "Repeated refresh must coalesce the current information request")
        replies[0](.success(HelperInformation(manifest: manifest, clientConfirmed: true)))
        try expect(helper.state == .ready && helper.usesHelper && !helper.checking, "Mutual trust must enable the selected helper")
        helper.select(false)
        try expect(!helper.selected && !helper.usesHelper && !defaults.bool(forKey: "useInstalledHelper"), "An explicit password choice must persist for a healthy helper")
        helper.select(true)
        try expect(helper.selected && helper.usesHelper, "A healthy helper can be explicitly selected again")
        helper.refresh()
        replies[1](.failure(WakecupError(message: "daemon stopped")))
        try expect(helper.state == .unavailable && helper.selected && !helper.usesHelper && !helper.checking,
                   "An unavailable daemon must preserve intent and expose the password fallback")
        helper.refresh()
        replies[2](.success(HelperInformation(manifest: manifest, clientConfirmed: false)))
        try expect(helper.state == .unavailable && !helper.usesHelper, "An unconfirmed client must not enable the helper")
        helper.refresh()
        let mismatch = HelperManifest(protocolVersion: manifest.protocolVersion, ownerUID: manifest.ownerUID,
            clientHash: String(repeating: "b", count: 40), helperHash: manifest.helperHash, helperSHA256: manifest.helperSHA256)
        replies[3](.success(HelperInformation(manifest: mismatch, clientConfirmed: true)))
        try expect(helper.state == .unavailable && helper.selected, "A mismatched daemon identity must preserve intent and remain unusable")
        helper.refresh()
        let staleReply = replies[4]
        inspection = .init(state: .updateRequired)
        helper.refresh()
        staleReply(.success(HelperInformation(manifest: manifest, clientConfirmed: true)))
        try expect(helper.state == .updateRequired && !helper.checking && helper.selected,
                   "A stale information reply must not override a changed installation")
        inspection = .init(state: .missing)
        helper.refresh()
        try expect(helper.state == .missing && helper.selected && replies.count == 5,
                   "Missing files must preserve intent without contacting a daemon")
        helper.select(false)
        try expect(!helper.selected && !defaults.bool(forKey: "useInstalledHelper"), "An explicit password choice must persist")
        helper.select(true)
        try expect(!helper.selected, "An unavailable helper cannot be newly selected")

        inspection = .init(state: .ready, manifest: manifest)
        helper.refresh()
        replies.last!(.failure(WakecupError(message: "daemon stopped")))
        let previousDetail = helper.detail
        helper.refresh()
        try expect(helper.checking && !previousDetail.isEmpty && helper.detail == previousDetail,
                   "A pending availability retry must preserve its previous diagnostic for Details")
        replies.last!(.success(HelperInformation(manifest: manifest, clientConfirmed: true)))
        try expect(helper.state == .ready && helper.detail.isEmpty && !helper.checking && !helper.selected,
                   "Successful mutual-trust confirmation must clear the stale diagnostic without changing intent")

        try checkInstallation(defaults: defaults)
        print("PASS: \(checks) helper intent, availability, mutual-trust, stale-reply and safe installation-result checks")
    }

    private static func checkInstallation(defaults: UserDefaults) throws {
        let ui = HeadlessInteraction()
        defaults.set(true, forKey: "useInstalledHelper")
        var replies: [(Result<HelperInformation, Error>) -> Void] = []
        var inspection = PrivilegedHelperController.Inspection(state: .ready, manifest: manifest)
        let cancelled = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in
            task("printf '%s' '-128'; exit 1")
        }, inspectInstallation: { inspection }, requestInformation: { replies.append($0) }, interaction: ui.value)
        let stale = replies[0]
        cancelled.changeInstallation(remove: false)
        try expect(cancelled.working && !cancelled.checking, "An installation must invalidate its pending health check")
        cancelled.select(false)
        stale(.success(HelperInformation(manifest: manifest, clientConfirmed: true)))
        try expect(cancelled.selected && !cancelled.usesHelper, "A stale reply or preference change during installation must be ignored")
        try waitUntil { !cancelled.working }
        try expect(cancelled.selected && defaults.bool(forKey: "useInstalledHelper"), "Cancelled authorization must preserve prior helper intent")
        inspection = .init(state: .unavailable)
        cancelled.refresh()
        ui.responses = [.cancel]
        cancelled.changeInstallation(remove: true)
        try expect(cancelled.selected, "Cancelling removal must preserve helper intent")

        defaults.set(false, forKey: "useInstalledHelper")
        let installed = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in task("exit 0") },
            inspectInstallation: { .init(state: .ready, manifest: manifest) },
            requestInformation: { reply in reply(.failure(WakecupError(message: "daemon unavailable"))) }, interaction: ui.value)
        installed.changeInstallation(remove: false)
        try waitUntil { !installed.working }
        try expect(installed.selected && defaults.bool(forKey: "useInstalledHelper") && installed.state == .unavailable && !installed.usesHelper,
                   "Successful installation with failed confirmation must remember helper intent without enabling it")

        defaults.set(false, forKey: "useInstalledHelper")
        let healthy = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in task("exit 0") },
            inspectInstallation: { .init(state: .ready, manifest: manifest) },
            requestInformation: { reply in reply(.success(HelperInformation(manifest: manifest, clientConfirmed: true))) }, interaction: ui.value)
        healthy.changeInstallation(remove: false)
        try waitUntil { !healthy.working }
        try expect(healthy.selected && healthy.usesHelper && !healthy.checking,
                   "Successful installation with mutual trust must enable and remember the helper")

        defaults.set(true, forKey: "useInstalledHelper")
        let failed = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in task("exit 1") },
            inspectInstallation: { .init(state: .unavailable) }, requestInformation: { _ in }, interaction: ui.value)
        failed.changeInstallation(remove: false)
        try waitUntil { !failed.working }
        try expect(failed.selected && defaults.bool(forKey: "useInstalledHelper"), "Failed update must preserve prior helper intent")

        var removed = false
        let removal = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { remove in
            removed = remove
            return task("exit 0")
        }, inspectInstallation: { .init(state: removed ? .missing : .unavailable) }, requestInformation: { _ in }, interaction: ui.value)
        removal.changeInstallation(remove: true)
        try waitUntil { !removal.working }
        try expect(removed && removal.state == .missing && !removal.selected && !defaults.bool(forKey: "useInstalledHelper"),
                   "Successful removal must turn off helper intent")
        try expect(ui.failures.count == 2,
                   "Failed installation and confirmation must report their warnings through the injected interaction")
    }

    private static func task(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WakecupError(message: message) }
        checks += 1
    }
    private static func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "Timed out waiting for a safe local installer stub")
    }
    private final class HeadlessInteraction {
        var responses: [HelperInteraction.Response] = []
        var failures: [String] = []
        var value: HelperInteraction {
            .init(present: { [self] request in
                if case .failure(let message, _, _) = request { failures.append(message) }
                if !responses.isEmpty { return responses.removeFirst() }
                if case .confirmRemoval = request { return .confirm }
                return .primary
            })
        }
    }
}
