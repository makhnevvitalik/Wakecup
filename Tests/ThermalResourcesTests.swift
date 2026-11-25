import Foundation

@main struct ThermalResourcesTests {
    private final class Hardware {
        enum Event { case released, restored, guardianStop, delivered }

        private let lock = NSLock()
        private var temperature: ProcessInfo.ThermalState = .nominal
        private var events: [(Event, UInt64)] = []
        private var starts: [Bool] = []

        func setTemperature(_ value: ProcessInfo.ThermalState) { lock.withLock { temperature = value } }
        func readTemperature() -> ProcessInfo.ThermalState { lock.withLock { temperature } }
        func start(display: Bool) { lock.withLock { starts.append(display) } }
        var assertionStarts: [Bool] { lock.withLock { starts } }
        func record(_ event: Event) {
            lock.withLock { events.append((event, DispatchTime.now().uptimeNanoseconds)) }
        }
        func timestamps(for event: Event) -> [UInt64] {
            lock.withLock { events.filter { $0.0 == event }.map { $0.1 } }
        }
        func resources(restore: @escaping () -> Void = {}) -> SessionPowerResources {
            SessionPowerResources(startAssertions: start, stopAssertions: { self.record(.released) },
                                  readThermalState: readTemperature, restoreAfterThermalStop: restore)
        }
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Wakecup-thermal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try stopDoesNotWaitForMain(root: root)
        try liveThresholdAndSettings(root: root)
        try guardianThermalStatusCancelsLidRestart(root: root)
        try terminalStopRebuildsUnreadableControl(root: root)
        try failedStopWriteIsRetried(root: root, byPoll: true)
        try failedStopWriteIsRetried(root: root, byPoll: false)
        try failedStopWriteIsRetried(root: root, byPoll: true, afterEnding: true)
        try staleDarkeningAndRestart()
        print("PASS: thermal stop effects while main is blocked, control merging, live threshold ordering, stop retry, and stale darkening rejection")
    }

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw WakecupError(message: message) }
    }

    private static func expectThermalStop(_ work: () throws -> Void) throws {
        do { try work() }
        catch let termination as SessionTermination {
            try expect(termination.code == .thermal, "Expected a typed thermal stop")
            return
        }
        throw WakecupError(message: "Expected the operation to stop on heat")
    }

    private static func sessionFiles(in root: URL) throws -> SessionFiles {
        let id = UUID().uuidString
        return try SessionFiles.create(at: root.appendingPathComponent(id),
            configuration: SessionConfiguration(id: id, parentPID: getpid(), duration: nil, powerMode: .ac,
                                                threshold: 30, closedLid: true, keepDisplayOn: false,
                                                thermalStopLevel: .critical))
    }

    private static func control(in files: SessionFiles) throws -> SessionControl {
        try files.read("control.json", as: SessionControl.self)
    }

    private static func stopDoesNotWaitForMain(root: URL) throws {
        let hardware = Hardware()
        let restoreQueue = DispatchQueue(label: "test.thermal.brightness")
        let restorationFinished = DispatchSemaphore(value: 0)
        let pollFinished = DispatchSemaphore(value: 0)
        let resources = hardware.resources {
            restoreQueue.async {
                hardware.record(.restored)
                restorationFinished.signal()
            }
        }
        let files = try sessionFiles(in: root)
        let id = files.url.lastPathComponent
        var delivered: [String] = []
        try resources.begin(id: id, level: .critical, files: files, continuing: false) {
            delivered.append($0)
            hardware.record(.delivered)
        }
        try resources.holdAssertions(display: true)
        let update = SessionLiveUpdate(revision: 3, powerMode: .battery, threshold: 46, deadline: 999)
        try resources.updateGuardianSettings(update, files: files)

        let mainBlockedAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global().async {
            hardware.setTemperature(.critical)
            resources.checkTemperature()
            resources.checkTemperature()
            if let saved = try? control(in: files), saved.stop, saved.thermalStopRequested == true,
               saved.update == update {
                hardware.record(.guardianStop)
            }
            pollFinished.signal()
        }
        try expect(pollFinished.wait(timeout: .now() + 3) == .success, "Main must not block threshold sampling or the guardian stop")
        try expect(restorationFinished.wait(timeout: .now() + 3) == .success, "The brightness restore queue must run while main is blocked")
        let mainResumedAt = DispatchTime.now().uptimeNanoseconds
        for event in [Hardware.Event.released, .restored, .guardianStop] {
            let timestamps = hardware.timestamps(for: event)
            try expect(timestamps.count == 1 && (mainBlockedAt...mainResumedAt).contains(timestamps[0]),
                       "Expected one \(event) before the main queue resumed")
        }
        try expect(delivered.isEmpty, "Model callback must wait for the main queue")
        let callbackDeadline = Date().addingTimeInterval(2)
        while delivered.isEmpty && Date() < callbackDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(delivered == [id] && hardware.timestamps(for: .delivered).allSatisfy { $0 >= mainResumedAt },
                   "Exactly one model callback should arrive on main after it resumes")
        hardware.setTemperature(.nominal)
        resources.checkTemperature()
        try expect(resources.hasThermalStop(for: id), "Cooling must not clear a detected thermal stop")
        resources.end(id: id)
        try expect(hardware.timestamps(for: .released).count == 1, "Finishing a thermal stop must not release assertions twice")
    }

    private static func guardianThermalStatusCancelsLidRestart(root: URL) throws {
        let hardware = Hardware()
        let resources = hardware.resources()
        let files = try sessionFiles(in: root)
        let id = files.url.lastPathComponent
        try resources.begin(id: id, level: .critical, files: files, continuing: false, onThermalStop: { _ in })
        try resources.holdAssertions(display: false)
        try resources.sendGuardianStop(files)
        var status = SessionStatus(phase: .stopped)
        status.setTermination(.thermal)
        try files.write(status, to: "status.json")
        resources.checkTemperature()
        try expect(resources.hasThermalStop(for: id) && hardware.timestamps(for: .released).count == 1,
                   "A guardian thermal report must release local assertions even if the app never read a hot temperature")
        try expect(try control(in: files).thermalStopRequested == true,
                   "A thermal report must supersede an existing ordinary stop request")
        try expect(resources.discardFinished(files), "Terminal restored guardian files should be removed")
        try expectThermalStop { try resources.checkStart(level: .critical, continuing: true) }
    }

    private static func liveThresholdAndSettings(root: URL) throws {
        let hardware = Hardware()
        let resources = hardware.resources()
        let files = try sessionFiles(in: root)
        let id = files.url.lastPathComponent
        try resources.begin(id: id, level: .critical, files: files, continuing: false, onThermalStop: { _ in })
        let update = SessionLiveUpdate(revision: 7, powerMode: .battery, threshold: 50, deadline: 250)
        try resources.updateGuardianSettings(update, files: files)
        hardware.setTemperature(.serious)
        resources.checkTemperature()
        try expect(!resources.hasThermalStop(for: id), "Critical must allow a serious thermal state")
        try resources.setThermalLevel(.serious)
        try expect(resources.hasThermalStop(for: id), "A stricter level must be sampled immediately")
        let stopped = try control(in: files)
        try expect(stopped.thermalStopRequested == true && stopped.thermalStopLevel == .serious && stopped.update == update,
                   "A threshold change and a thermal stop must preserve the pending power update")
        hardware.setTemperature(.nominal)
        try expectThermalStop { try resources.setThermalLevel(.critical) }
        try expectThermalStop { try resources.updateGuardianSettings(
            SessionLiveUpdate(revision: 8, powerMode: .ac, threshold: 25, deadline: nil), files: files) }
        resources.end(id: id)
        try resources.sendGuardianStop(files)
        try expect(try control(in: files).thermalStopRequested == true && control(in: files).update == update,
                   "Recovery stop must preserve an inactive guardian's thermal reason and pending settings")

        let other = try sessionFiles(in: root)
        let otherID = other.url.lastPathComponent
        try resources.begin(id: otherID, level: .critical, files: other, continuing: false, onThermalStop: { _ in })
        try resources.setThermalLevel(.serious)
        hardware.setTemperature(.serious)
        try expectThermalStop { try resources.setThermalLevel(.critical) }
        try expect(try control(in: other).thermalStopLevel == .serious && control(in: other).thermalStopRequested == true,
                   "A weaker setting cannot bypass heat already at the previous threshold")
    }

    private static func failedStopWriteIsRetried(root: URL, byPoll: Bool, afterEnding: Bool = false) throws {
        let hardware = Hardware()
        let resources = hardware.resources()
        let files = try sessionFiles(in: root)
        let id = files.url.lastPathComponent
        try resources.begin(id: id, level: .critical, files: files, continuing: false, onThermalStop: { _ in })
        try resources.holdAssertions(display: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.url.path) }
        var rejected = false
        do { try resources.setThermalLevel(.serious) } catch { rejected = true }
        try expect(rejected, "Threshold update must report the failed control access")
        hardware.setTemperature(.serious)
        resources.checkTemperature()
        try expect(!resources.hasThermalStop(for: id), "A failed control write must leave the previous threshold active")
        hardware.setTemperature(.critical)
        resources.checkTemperature()
        try expect(resources.hasThermalStop(for: id) && hardware.timestamps(for: .released).count == 1,
                   "Guardian control write failure must leave the local thermal stop latched")
        try expect(try !control(in: files).stop, "The read-only directory must prevent the initial stop write")
        if afterEnding {
            resources.end(id: id)
            try expect(try !control(in: files).stop, "The final UI cleanup write must still fail while the directory is read-only")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.url.path)
        hardware.setTemperature(.nominal)
        if byPoll { resources.checkTemperature() } else { try resources.sendGuardianStop(files) }
        try expect(try control(in: files).stop && control(in: files).thermalStopRequested == true,
                   "The next stop attempt must still persist the latched thermal stop after cooling")
    }

    private static func terminalStopRebuildsUnreadableControl(root: URL) throws {
        let hardware = Hardware()
        let resources = hardware.resources()
        let active = try sessionFiles(in: root)
        let previous = try sessionFiles(in: root)
        try resources.begin(id: active.url.lastPathComponent, level: .critical, files: active,
                            continuing: false, onThermalStop: { _ in })
        try FileManager.default.removeItem(at: active.url.appendingPathComponent("control.json"))
        hardware.setTemperature(.critical)
        resources.checkTemperature()
        let thermal = try control(in: active)
        try expect(thermal.stop && thermal.thermalStopRequested == true,
                   "Heat must fence a pending guardian launch even when its control file disappeared")

        try Data("invalid JSON".utf8).write(to: previous.url.appendingPathComponent("control.json"))
        try resources.sendGuardianStop(previous)
        let recovery = try control(in: previous)
        try expect(recovery.stop && recovery.thermalStopRequested == nil,
                   "An inactive recovery stop must replace invalid control without borrowing the current thermal reason")
    }

    private static func staleDarkeningAndRestart() throws {
        let hardware = Hardware()
        let resources = hardware.resources()
        hardware.setTemperature(.critical)
        try expectThermalStop { try resources.begin(id: "hot", level: .critical, files: nil, continuing: false, onThermalStop: { _ in }) }
        try expect(hardware.assertionStarts.isEmpty, "A hot start must never hold assertions")
        hardware.setTemperature(.nominal)
        try resources.begin(id: "first", level: .critical, files: nil, continuing: false, onThermalStop: { _ in })
        try resources.holdAssertions(display: true)
        let previousPermission = resources.darkeningPermission()
        try resources.begin(id: "second", level: .critical, files: nil, continuing: true, onThermalStop: { _ in })
        resources.end(id: "first")
        try expect(hardware.timestamps(for: .released).isEmpty, "Lid restart must preserve assertions and reject a stale release")
        var wroteDarkness = false
        do { try previousPermission { wroteDarkness = true } } catch {}
        try expect(!wroteDarkness, "A prepared blackout must not darken a replacement session")
        let permission = resources.darkeningPermission()
        try permission { wroteDarkness = true }
        try expect(wroteDarkness, "A current, cool session may darken")
        wroteDarkness = false
        hardware.setTemperature(.critical)
        try expectThermalStop { try permission { wroteDarkness = true } }
        try expect(!wroteDarkness && resources.hasThermalStop(for: "second"),
                   "Darkening must sample temperature again just before writing zero")
        hardware.setTemperature(.nominal)
        try expectThermalStop { try resources.holdAssertions(display: false) }
        try expectThermalStop { try resources.begin(id: "third", level: .critical, files: nil, continuing: true, onThermalStop: { _ in }) }
        try expect(hardware.assertionStarts == [true] && hardware.timestamps(for: .released).count == 1,
                   "A latched stop must prevent reacquiring assertions through a late restart")
    }
}
