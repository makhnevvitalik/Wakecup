import ServiceManagement

struct LoginItemController {
    let readStatus: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void
    let openSettings: () -> Void

    var checked: Bool {
        readStatus() == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        let status = readStatus()
        if enabled {
            if status != .enabled && status != .requiresApproval { try register() }
            if readStatus() == .requiresApproval { openSettings() }
        } else if status != .notRegistered {
            try unregister()
        }
    }

    static var system: LoginItemController {
        LoginItemController(readStatus: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}
