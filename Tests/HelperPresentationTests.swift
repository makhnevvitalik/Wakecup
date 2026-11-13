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
        var response: HelperInteraction.Response = .primary
        var dialogs: [HelperInteraction.Request] = []
        var installations: [Bool] = []
        var events: [String] = []
        let interaction = HelperInteraction(activate: { events.append("activate") }, present: { request in
            events.append("present")
            dialogs.append(request)
            return response
        })
        let helper = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { remove in
            installations.append(remove)
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "printf '%s' '-128'; exit 1"]
            return task
        }, inspectInstallation: { .init(state: .updateRequired) }, requestInformation: { reply in
            reply(.failure(WakecupError(message: "test cancellation")))
        }, interaction: interaction)
        helper.willPresentDialog = { events.append("dismiss") }
        helper.showSettings()
        try settle(helper)
        try expect(dialogs.count == 1 && installations == [false], "Update needs one overview without a repeated explanation")
        guard case .settings(let snapshot) = dialogs[0] else { throw WakecupError(message: "Missing typed settings request") }
        try expect(snapshot.state == .updateRequired && snapshot.selected && !snapshot.usesHelper && snapshot.allowInstallationChanges,
                   "Settings must receive the complete permission-mode snapshot")
        try expect(helper.selected, "Cancelled authorization must preserve selected helper intent")
        try expect(events == ["dismiss", "activate", "present", "dismiss", "activate"],
                   "Each dialog and authorization must close the menu before activation")
        dialogs.removeAll(); installations.removeAll(); events.removeAll()
        helper.changeInstallation(remove: false)
        try settle(helper)
        try expect(dialogs.isEmpty && installations == [false] && events == ["dismiss", "activate"],
                   "Explicit update must go directly to authorization after closing the menu")
        dialogs.removeAll(); installations.removeAll(); response = .close
        helper.showSettings()
        try expect(dialogs.count == 1 && installations.isEmpty && helper.selected, "Close must preserve the helper")
        dialogs.removeAll(); response = .primary
        helper.showSettings(allowInstallationChanges: false)
        guard case .settings(let readOnly) = dialogs[0] else { throw WakecupError(message: "Missing read-only settings") }
        try expect(!readOnly.allowInstallationChanges && installations.isEmpty,
                   "Read-only settings must not install/update even when a primary response is supplied")
        dialogs.removeAll(); response = .remove
        helper.showSettings(allowInstallationChanges: false)
        try expect(dialogs.count == 1 && installations.isEmpty, "Read-only settings must not confirm or perform removal")
        dialogs.removeAll(); response = .cancel
        helper.changeInstallation(remove: true)
        guard case .confirmRemoval = dialogs.first else { throw WakecupError(message: "Removal needs a typed confirmation") }
        try expect(dialogs.count == 1 && installations.isEmpty && helper.selected, "Cancelled removal must preserve helper intent")
        dialogs.removeAll(); response = .close
        helper.showExplanation()
        guard case .explanation = dialogs.first else { throw WakecupError(message: "Missing typed explanation request") }
        try expect(dialogs.count == 1, "Explanation needs exactly one information dialog")

        defaults.set(false, forKey: "useInstalledHelper")
        dialogs.removeAll(); installations.removeAll(); response = .primary
        let missing = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { remove in
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "printf '%s' '-128'; exit 1"]; installations.append(remove); return task
        }, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in }, interaction: interaction)
        missing.willPresentDialog = { events.append("dismiss") }
        missing.changeInstallation(remove: false)
        try settle(missing)
        guard case .settings(let firstInstall) = dialogs[0] else { throw WakecupError(message: "First install requires settings") }
        try expect(dialogs.count == 1 && firstInstall.state == .missing && installations == [false],
                   "First installation needs one explanation")
        dialogs.removeAll(); installations.removeAll(); response = .close
        missing.showSettings()
        try expect(installations.isEmpty && !missing.selected, "Closing missing-helper settings must preserve password mode")
        response = .remove
        missing.showSettings()
        try expect(installations.isEmpty && !missing.selected, "A missing helper cannot be removed through a scripted response")

        let inert = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in
            throw WakecupError(message: "Inert interaction must never install")
        }, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
        inert.showSettings(); inert.showExplanation(); inert.changeInstallation(remove: true)
        try expect(!inert.selected && !inert.working, "Default UI interaction must be inert")
        print("PASS: typed helper overview, direct update, Close, read-only actions, cancellation, first install, removal and inert defaults")
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
