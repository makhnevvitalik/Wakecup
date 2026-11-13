import Foundation
import ServiceManagement

@main
struct LoginItemTests {
    static func main() throws {
        var status = SMAppService.Status.enabled
        var registered = 0
        var unregistered = 0
        var settingsOpened = 0
        let controller = LoginItemController(readStatus: { status },
            register: { registered += 1; status = .enabled },
            unregister: { unregistered += 1; status = .notRegistered },
            openSettings: { settingsOpened += 1 })
        var checks = 0
        var failed: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failed.append(name) }
        }
        expect(controller.checked, "enabled service is checked")
        status = .notRegistered
        expect(!controller.checked, "external removal clears check without restarting app")
        try controller.setEnabled(true)
        expect(status == .enabled && registered == 1, "enabling after external removal registers again")
        try controller.setEnabled(false)
        expect(status == .notRegistered && unregistered == 1, "disabling an enabled service unregisters it")
        status = .requiresApproval
        expect(!controller.checked, "revoked consent is not shown as enabled")
        try controller.setEnabled(true)
        expect(settingsOpened == 1 && registered == 1 && unregistered == 1, "revoked consent opens settings without re-register loop")
        expect(status == .requiresApproval && !controller.checked, "check remains off until actual OS approval")
        status = .enabled
        expect(controller.checked, "approval in OS reflected without restart")
        try controller.setEnabled(true)
        expect(registered == 1, "already enabled is idempotent")
        status = .notRegistered
        try controller.setEnabled(false)
        expect(unregistered == 1, "already removed is idempotent")
        var attempted = false
        let failing = LoginItemController(readStatus: { .notRegistered },
            register: { attempted = true; throw NSError(domain: "Test", code: 1) },
            unregister: {}, openSettings: {})
        var reported = false
        do { try failing.setEnabled(true) } catch { reported = true }
        expect(attempted && reported && !failing.checked, "registration failure leaves authoritative unchecked state")
        var pendingStatus = SMAppService.Status.notRegistered
        var pendingSettingsOpened = 0
        let pending = LoginItemController(readStatus: { pendingStatus },
            register: { pendingStatus = .requiresApproval }, unregister: {},
            openSettings: { pendingSettingsOpened += 1 })
        try pending.setEnabled(true)
        expect(!pending.checked && pendingSettingsOpened == 1,
               "new registration needing approval opens settings and stays unchecked")
        print("Login item checks: \(checks), failures: \(failed.count)")
        failed.forEach { print("FAIL: " + $0) }
        exit(failed.isEmpty ? 0 : 1)
    }
}
