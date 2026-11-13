import Foundation
import Darwin

@main struct BacklightSessionTests {
    static func main() {
        do {
            if CommandLine.arguments.contains("--fake-restorer") || CommandLine.arguments.contains("--restore-backlight") {
                let record = try BacklightRecoveryRecord.read(from: URL(fileURLWithPath: CommandLine.arguments[2]))
                let marker = CommandLine.arguments.contains("--restore-backlight")
                    ? URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("fake-brightness")
                    : URL(fileURLWithPath: CommandLine.arguments[3])
                var delayed = false
                let status = BacklightRestoreCommand.run(record: record, input: .standardInput, output: .standardOutput,
                    write: { _, value in
                        if !delayed && FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().appendingPathComponent("delay").path) {
                            delayed = true; Thread.sleep(forTimeInterval: 1.8)
                        }
                        if !CommandLine.arguments.contains("--refuse") { try String(value).write(to: marker, atomically: true, encoding: .utf8) }
                    },
                    read: { _ in Float(try String(contentsOf: marker, encoding: .utf8))! }, pause: { _ in })
                exit(status)
            }
            try run()
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: message, code: 1) }
    }
    static func run() throws {
        // Removing READY ordering or the positive-value guard must fail these tests.
        final class Fixture {
            var level: Float = 0.65
            var saved: BacklightRecoveryRecord?
            var childAlive = true
            var actualRestorer: BacklightRestorer?
            var ready = false
            var failLaunch = false
            var refuseRestore = false
            var zeroThrows = false
            var cleaned = false
            var disarmed = false
            var restoreRequested = false
            var writes: [Float] = []
            func session() -> BacklightSession {
                BacklightSession(operations: .init(
                    display: { BacklightDisplay(id: 42, uuid: "fake-built-in") },
                    read: { _ in self.level }, write: { _, value in
                        if value == 0 && !self.ready { throw NSError(domain: "dark before READY", code: 1) }
                        self.writes.append(value)
                        if value > 0 && self.refuseRestore { return }
                        self.level = value
                        if value == 0 && self.zeroThrows { throw NSError(domain: "zero failed after change", code: 1) }
                    }, save: { self.saved = $0; return URL(fileURLWithPath: "/fake/record") },
                    remove: { _ in self.cleaned = true }, launch: { _, _ in
                        if self.failLaunch { throw NSError(domain: "launch", code: 1) }
                        self.ready = true
                        if let restorer = self.actualRestorer { return restorer }
                        return BacklightRestorer(isRunning: { self.childAlive }, disarm: { self.disarmed = true; self.childAlive = false },
                            requestRestore: { self.restoreRequested = true })
                    }, pause: { _ in }))
            }
        }
        let normal = Fixture(), session = normal.session()
        try expect(normal.saved == nil && normal.writes.isEmpty, "Construction must be inert")
        try session.begin()
        try expect(normal.level == 0 && normal.saved?.brightness == 0.65 && session.isHealthy && session.needsRestoration, "Entry saves positive value and darkens only after READY")
        try session.begin()
        try expect(normal.writes == [0], "Repeated begin must not overwrite the snapshot with zero")
        normal.childAlive = false
        try expect(!session.isHealthy, "Exited child makes an active session unhealthy")
        normal.childAlive = true
        try session.restore()
        try expect(normal.level == 0.65 && normal.disarmed && normal.cleaned && !session.needsRestoration, "Verified parent restore disarms child and clears recovery")
        for value: Float in [0, -0.1, 1.1, .nan, .infinity] {
            let invalid = Fixture(); invalid.level = value
            do { try invalid.session().begin(); throw NSError(domain: "invalid brightness accepted", code: 1) }
            catch { try expect(invalid.saved == nil && invalid.writes.isEmpty, "Invalid input must fail before saving or writing") }
        }
        let launch = Fixture(); launch.failLaunch = true
        do { try launch.session().begin() } catch {}
        try expect(launch.writes.isEmpty && launch.cleaned, "Launch failure must leave visible brightness and remove unused recovery")
        let rollback = Fixture(); rollback.zeroThrows = true
        do { try rollback.session().begin() } catch {}
        try expect(rollback.level == 0.65 && rollback.disarmed && rollback.cleaned, "Partial entry failure rolls back verified brightness")
        let uncertain = Fixture(), uncertainSession = uncertain.session()
        uncertain.zeroThrows = true; uncertain.refuseRestore = true
        do { try uncertainSession.begin() } catch {}
        try expect(uncertainSession.needsRestoration && !uncertain.disarmed && !uncertain.cleaned && uncertain.restoreRequested,
                   "A failed entry with failed rollback must retain the escape path and recovery record")
        uncertain.refuseRestore = false; try uncertainSession.restore()
        let stableRecord = BacklightRecoveryRecord(display: BacklightDisplay(id: 42, uuid: "fake-built-in"), brightness: 0.65)
        var readbacks: [Float] = [0.65, 0.1, 0.65, 0.65, 0.65]
        var rewritten: [Float] = []
        try BacklightRestoreCommand.restore(record: stableRecord, write: { _, value in rewritten.append(value) },
            read: { _ in readbacks.removeFirst() }, pause: { _ in })
        try expect(readbacks.isEmpty && rewritten == [0.65, 0.65], "An OS overwrite requires rewriting and fresh stable verification")
        let stuck = Fixture(), stuckSession = stuck.session()
        try stuckSession.begin(); stuck.refuseRestore = true
        do { try stuckSession.restore() } catch {}
        try expect(!stuck.disarmed && !stuck.cleaned && stuckSession.needsRestoration && stuck.restoreRequested && stuck.saved?.brightness == 0.65,
                   "Uncertain restore must retain recovery and request independent restoration")
        stuck.refuseRestore = false; try stuckSession.restore()
        try expect(stuck.cleaned && stuck.level == 0.65, "Failed restoration remains retryable")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Wakecup-backlight-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = BacklightRecoveryRecord(display: BacklightDisplay(id: 42, uuid: "fake-built-in"), brightness: 0.65)
        let file = try record.save(in: folder)
        try expect(try BacklightRecoveryRecord.read(from: file).brightness == 0.65, "Recovery file preserves positive snapshot")
        let marker = folder.appendingPathComponent("fake-brightness")
        try "0".write(to: marker, atomically: true, encoding: .utf8)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fake-restorer", file.path, marker.path]
        child.standardInput = input; child.standardOutput = output
        try child.run()
        try expect(try output.fileHandleForReading.read(upToCount: 6) == Data("READY\n".utf8), "Fake child must acknowledge before parent releases control")
        try input.fileHandleForWriting.close() // Parent death is the same EOF, with no hardware adapter in this executable.
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(!child.isRunning && child.terminationStatus == 0, "EOF restoration must finish within its bound")
        try expect(try String(contentsOf: marker, encoding: .utf8) == "0.65", "EOF must restore saved brightness through injected adapter")
        let failed = Process(), failedInput = Pipe(), failedOutput = Pipe()
        try "0".write(to: marker, atomically: true, encoding: .utf8)
        failed.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        failed.arguments = ["--fake-restorer", file.path, marker.path, "--refuse"]
        failed.standardInput = failedInput; failed.standardOutput = failedOutput
        try failed.run()
        try expect(try failedOutput.fileHandleForReading.read(upToCount: 6) == Data("READY\n".utf8), "Failed child fixture must first become ready")
        try failedInput.fileHandleForWriting.write(contentsOf: Data("R".utf8))
        try failedInput.fileHandleForWriting.close()
        let failedDeadline = Date().addingTimeInterval(3)
        while failed.isRunning && Date() < failedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(!failed.isRunning && failed.terminationStatus == 1 && FileManager.default.fileExists(atPath: file.path),
                   "Bounded failed child restoration must retain the positive recovery record")
        try Data().write(to: folder.appendingPathComponent("delay"))
        let delayedRestorer = try BacklightRestoreProcess.launch(record: record, file: file)
        let delayedFixture = Fixture(); delayedFixture.actualRestorer = delayedRestorer
        let delayedSession = delayedFixture.session()
        try delayedSession.begin()
        delayedRestorer.requestRestore() // Child is now committed to its independent, delayed restoration.
        var disarmRejected = false
        do { try delayedSession.restore() } catch { disarmRejected = true }
        try expect(disarmRejected && delayedSession.needsRestoration && !delayedFixture.cleaned && delayedRestorer.isRunning(),
                   "A still-restoring child must prevent parent cleanup and preserve the escape path")
        try delayedSession.begin()
        try expect(delayedFixture.writes.filter { $0 == 0 }.count == 1, "Pending restoration must not darken a new session")
        let delayedDeadline = Date().addingTimeInterval(3)
        while delayedRestorer.isRunning() && Date() < delayedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        try expect(!delayedRestorer.isRunning(), "Delayed fake restorer must finish without termination")
        try delayedSession.restore()
        try expect(!delayedSession.needsRestoration && delayedFixture.cleaned, "Cleanup can finish after the previous safety child exits")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var rejected = false
        do { _ = try BacklightRecoveryRecord.read(from: file) } catch { rejected = true }
        try expect(rejected, "Recovery files must reject unsafe permissions")
        print("PASS: inert backlight construction, READY ordering, input guards, rollback, recovery retention, child health and independent EOF restoration (fake hardware only)")
    }
}
