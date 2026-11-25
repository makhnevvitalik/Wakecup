import Foundation

func helperTestModel(defaults: UserDefaults, helper: PrivilegedHelperController) -> SessionModel {
    defaults.set(false, forKey: "closedLid")
    let operations = SessionOperations(now: { 1_000 }, readPower: { .init(onAC: true, percent: 80) },
        readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
        createFiles: { _ in throw WakecupError(message: "Unexpected closed-lid session") },
        guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
        usesInstalledHelper: { false }, startHelper: { _, _, _ in },
        loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
        scheduleTicks: { _ in {} })
    return SessionModel(defaults: defaults, operations: operations, helper: helper)
}
