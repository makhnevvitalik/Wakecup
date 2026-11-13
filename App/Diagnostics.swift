import Foundation
import IOKit
import IOKit.pwr_mgt
func selfTest() throws {
    func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw WakecupError(message: "FAILED: " + label) }
        print("PASS: " + label)
    }
    try expect(try parseDisabled("System-wide power settings:\n SleepDisabled 1\n") == true, "enabled state")
    try expect(try parseDisabled("System-wide power settings:\nCurrently in use:\n sleep 0\n") == false, "absent means disabled flag is off")
    var invalidRejected = false
    do { _ = try parseDisabled("permission denied") } catch { invalidRejected = true }
    try expect(invalidRejected, "unreadable state rejected")
    var state = false
    var writes: [Bool] = []
    try temporaryDisable(read: { state }, write: { state = $0; writes.append($0) }, body: {})
    try expect(!state && writes == [true, false], "timer/normal stop restores state")
    writes = []
    do {
        try temporaryDisable(read: { state }, write: { state = $0; writes.append($0) }, body: { throw WakecupError(message: "simulated interruption") })
    } catch {}
    try expect(!state && writes == [true, false], "body failure restores state")
    var reads = 0
    writes = []
    do {
        try temporaryDisable(read: { reads += 1; return false }, write: { writes.append($0) }, body: {})
    } catch {}
    try expect(writes == [true, false] && reads == 3, "failed enable verification still restores")
    writes = []
    do { try temporaryDisable(read: { true }, write: { writes.append($0) }, body: {}) } catch {}
    try expect(writes.isEmpty, "preexisting global disable is left untouched")
    var failureReported = false
    do {
        try temporaryDisable(read: { state }, write: { value in
            if !value { throw WakecupError(message: "simulated restore failure") }
            state = value
        }, body: {})
    } catch { failureReported = error.localizedDescription.contains("sudo pmset") }
    try expect(failureReported, "restore failure is reported explicitly")
}

func nativeSmokeTest() throws {
    let assertions = SleepAssertions()
    try assertions.start(display: true)
    let ids = assertions.ids
    defer { assertions.stop() }
    guard ids.count == 2, ids.allSatisfy({ IOPMAssertionCopyProperties($0)?.takeRetainedValue() != nil }) else {
        throw WakecupError(message: "Нативные удержания сна не созданы.")
    }
    let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 2,
        powerMode: .battery, threshold: 10, closedLid: false, keepDisplayOn: true)
    let start = continuousNow()
    var monitor = try SessionMonitor(configuration: config, now: start)
    var reason: String?
    repeat {
        reason = monitor.step(now: continuousNow(), control: SessionControl(), power: readPowerState(), ownerAlive: true)
        if reason == nil { Thread.sleep(forTimeInterval: 0.1) }
    } while reason == nil && continuousNow() - start < 5
    assertions.stop()
    guard reason == "время истекло", ids.allSatisfy({ IOPMAssertionCopyProperties($0)?.takeRetainedValue() == nil }) else {
        throw WakecupError(message: "Нативный сеанс не завершился по таймеру или удержания не освобождены.")
    }
    print("PASS: actual native idle/display assertions created; 2-second timer expired; both assertions released")
}

func guardSmokeTest() throws {
    guard try !readDisabled() else { throw WakecupError(message: "Глобальный запрет сна уже включён — проверка отменена.") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wakecup-guard-check-" + UUID().uuidString)
    let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 2,
        powerMode: .battery, threshold: 10, closedLid: true, keepDisplayOn: false, parentIdentity: processIdentity(getpid()))
    let files = try SessionFiles.create(at: root, configuration: config)
    defer {
        try? files.write(SessionControl(stop: true), to: "control.json")
        if let status = try? files.read("status.json", as: SessionStatus.self), status.phase == "stopped", status.sleepRestored {
            try? FileManager.default.removeItem(at: root)
        } else { print("State retained for recovery: \(root.path)") }
    }
    let task = try HelperAuthorization.guardTask(files: files)
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw WakecupError(message: "Авторизация проверки не завершена: " + String(decoding: data, as: UTF8.self))
    }
    let timeout = continuousNow() + 15
    var observedActive = false
    while continuousNow() < timeout {
        let status = try files.read("status.json", as: SessionStatus.self)
        if status.phase == "active", !observedActive {
            guard GuardianStatusSocket.probe(pid: status.helperPID) == .responsive,
                  try readDisabled() else {
                throw WakecupError(message: "Не удалось подтвердить ответ защитного процесса и включённый режим.")
            }
            observedActive = true
        }
        if status.phase == "stopped" {
            guard observedActive, status.reason == "время истекло", status.sleepRestored, try !readDisabled() else {
                throw WakecupError(message: "Режим не прошёл проверку автоматического восстановления.")
            }
            print("PASS: real closed-lid flag enabled; guard answered over the local socket; 2-second timer expired; original sleep flag restored")
            return
        }
        if status.phase == "failed" { throw WakecupError(message: status.reason) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw WakecupError(message: "Истекло время ожидания защитного процесса.")
}
