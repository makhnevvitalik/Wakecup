import Combine
import Foundation

// The typed UI boundary is scripted: no windows, activation, administrator
// requests, installed-helper access or shared preferences.
@main struct HelperPresentationTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func run() throws {
        let suite = "WakecupHelperPresentationTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "useInstalledHelper")
        defer { defaults.removePersistentDomain(forName: suite) }
        var simulatedInstallation = HelperStatus.State.updateRequired
        var inspections = 0
        var pendingResponse: ((HelperInteraction.Response) -> Void)?
        var deferResponse = false
        var response: HelperInteraction.Response = .primary
        var dialogs: [HelperInteraction.Request] = []
        var installations: [Bool] = []
        var events: [String] = []
        var interaction = HelperInteraction(activate: { events.append("activate") }, present: { request in
            events.append("present")
            dialogs.append(request)
            let complete: (HelperInteraction.Response) -> Void
            switch request {
            case .settings(_, let respond), .confirmRemoval(let respond): complete = respond
            case .explanation, .failure: return
            }
            if deferResponse { pendingResponse = complete }
            else { complete(response) }
        })
        let helper = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { remove in
            installations.append(remove)
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "printf '%s' '-128'; exit 1"]
            return task
        }, inspectInstallation: {
            inspections += 1
            return .init(state: simulatedInstallation)
        }, requestInformation: { reply in
            reply(.failure(WakecupError(message: "test cancellation")))
        })
        interaction.dismissPanel = { events.append("dismiss") }
        let model = helperTestModel(defaults: defaults, helper: helper)
        defer { model.stop() }
        func setSessionActive(_ active: Bool) throws {
            if active { model.start() } else { model.stop() }
            try expect(model.phase == (active ? .active : .idle), "The fixture must change session state")
        }
        interaction.showSettings(for: model)
        try settle(helper)
        try expect(dialogs.count == 1 && installations == [false], "Update needs one overview without a repeated explanation")
        guard case .settings(let snapshot, _) = dialogs[0] else { throw WakecupError(message: "Missing typed settings request") }
        try expect(snapshot.status.state == .updateRequired && snapshot.status.selected && !snapshot.status.usesHelper && snapshot.allowInstallationChanges,
                   "Settings must receive the complete permission-mode snapshot")
        try expect(helper.selected, "Cancelled authorization must preserve selected helper intent")
        try expect(events == ["present", "dismiss", "activate"],
                   "Only authorization dismisses the menu when settings already own the sheet")
        dialogs.removeAll(); installations.removeAll(); events.removeAll()
        let beforeUpdate = inspections
        interaction.changeInstallation(for: model, remove: false)
        try expect(inspections == beforeUpdate + 1, "An explicit update must inspect the installation once before authorization")
        try settle(helper)
        try expect(dialogs.isEmpty && installations == [false] && events == ["dismiss", "activate"],
                   "Explicit update must go directly to authorization after closing the menu")
        dialogs.removeAll(); installations.removeAll(); response = .close
        interaction.showSettings(for: model)
        try expect(dialogs.count == 1 && installations.isEmpty && helper.selected, "Close must preserve the helper")
        dialogs.removeAll(); response = .primary
        try setSessionActive(true)
        interaction.showSettings(for: model)
        guard case .settings(let readOnly, _) = dialogs[0] else { throw WakecupError(message: "Missing read-only settings") }
        try expect(!readOnly.allowInstallationChanges && installations.isEmpty,
                   "Read-only settings must not install/update even when a primary response is supplied")
        dialogs.removeAll(); response = .remove
        interaction.showSettings(for: model)
        try expect(dialogs.count == 1 && installations.isEmpty, "Read-only settings must not confirm or perform removal")
        try setSessionActive(false)
        dialogs.removeAll(); response = .cancel
        interaction.changeInstallation(for: model, remove: true)
        guard case .confirmRemoval = dialogs.first else { throw WakecupError(message: "Removal needs a typed confirmation") }
        try expect(dialogs.count == 1 && installations.isEmpty && helper.selected, "Cancelled removal must preserve helper intent")
        dialogs.removeAll()
        deferResponse = true
        interaction.changeInstallation(for: model, remove: true)
        simulatedInstallation = .missing
        pendingResponse?(.confirm)
        try expect(installations.isEmpty, "Removal must recheck whether the helper still exists after confirmation")

        simulatedInstallation = .updateRequired
        interaction.changeInstallation(for: model, remove: true)
        try setSessionActive(true)
        pendingResponse?(.confirm)
        try expect(installations.isEmpty, "Removal must be prevented if a session started while confirmation was open")

        try setSessionActive(false)
        interaction.showSettings(for: model)
        try setSessionActive(true)
        pendingResponse?(.primary)
        try expect(installations.isEmpty, "Update must be prevented if a session started while management was open")

        try setSessionActive(false)
        interaction.showSettings(for: model)
        simulatedInstallation = .missing
        pendingResponse?(.primary)
        try expect(installations.isEmpty, "An outdated Update button must not install a newly missing helper")
        simulatedInstallation = .updateRequired
        pendingResponse = nil
        deferResponse = false
        dialogs.removeAll(); response = .close
        interaction.showExplanation()
        guard case .explanation = dialogs.first else { throw WakecupError(message: "Missing typed explanation request") }
        try expect(dialogs.count == 1, "Explanation needs exactly one information dialog")

        defaults.set(false, forKey: "useInstalledHelper")
        dialogs.removeAll(); installations.removeAll(); response = .primary
        let missing = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { remove in
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "printf '%s' '-128'; exit 1"]; installations.append(remove); return task
        }, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
        let missingModel = helperTestModel(defaults: defaults, helper: missing)
        interaction.changeInstallation(for: missingModel, remove: false)
        try settle(missing)
        guard case .settings(let firstInstall, _) = dialogs[0] else { throw WakecupError(message: "First install requires settings") }
        try expect(dialogs.count == 1 && firstInstall.status.state == .missing && installations == [false],
                   "First installation needs one explanation")
        dialogs.removeAll(); installations.removeAll(); response = .close
        interaction.showSettings(for: missingModel)
        try expect(installations.isEmpty && !missing.selected, "Closing missing-helper settings must preserve password mode")
        response = .remove
        interaction.showSettings(for: missingModel)
        try expect(installations.isEmpty && !missing.selected, "A missing helper cannot be removed through a scripted response")

        let inert = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in
            throw WakecupError(message: "Inert interaction must never install")
        }, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
        let inertModel = helperTestModel(defaults: defaults, helper: inert)
        let inertInteraction = HelperInteraction()
        inertInteraction.showSettings(for: inertModel)
        inertInteraction.showExplanation()
        inertInteraction.changeInstallation(for: inertModel, remove: true)
        try expect(!inert.selected && !inert.working, "Default UI interaction must be inert")
        try checkUpdateWarning(defaults: defaults)
        print("PASS: typed helper overview, direct update, Close, read-only actions, cancellation, first install, removal and inert defaults")
    }

    private static func checkUpdateWarning(defaults: UserDefaults) throws {
        defaults.set(true, forKey: "useInstalledHelper")
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        var inspection = PrivilegedHelperController.Inspection(state: .updateRequired)
        var reply: ((Result<HelperInformation, Error>) -> Void)?
        let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { inspection },
            requestInformation: { reply = $0 })
        let model = helperTestModel(defaults: defaults, helper: helper)
        var snapshots: [HelperStatus] = []
        let observation = model.helperStatuses.sink { snapshots.append($0) }
        defer { observation.cancel() }

        inspection = .init(state: .ready, manifest: manifest)
        model.refreshHelperStatus()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(snapshots.last?.checking == true && snapshots.allSatisfy(\.updateRequired),
                   "The update warning must survive a pending daemon reply")
        reply?(.failure(WakecupError(message: "Helper did not authenticate")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(snapshots.last?.checking == false && snapshots.last?.detail == "Helper did not authenticate"
                   && snapshots.allSatisfy(\.updateRequired),
                   "The update warning must survive an unsuccessful confirmation")
        model.refreshHelperStatus()
        reply?(.success(.init(manifest: manifest, clientConfirmed: true)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(snapshots.last?.state == .ready && snapshots.last?.detail == ""
                   && snapshots.last?.updateRequired == false,
                   "Only a confirmed replacement clears the update warning")
    }
    private static func settle(_ helper: PrivilegedHelperController) throws {
        let limit = Date().addingTimeInterval(3)
        while helper.working && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(!helper.working, "Local installer stub did not finish")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WakecupError(message: message) }
    }
}
