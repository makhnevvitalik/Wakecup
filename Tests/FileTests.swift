import Foundation
import Darwin

@main
struct FileTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wakecup-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 2,
            powerMode: .battery, threshold: 20, closedLid: true, keepDisplayOn: false)
        let files = try SessionFiles.create(at: root, configuration: config)
        var checks = 0
        func expect(_ condition: Bool, _ name: String) throws {
            guard condition else { throw WakecupError(message: "FAIL: " + name) }
            checks += 1
        }
        let loaded = try files.read("configuration.json", as: SessionConfiguration.self)
        try expect(loaded.id == config.id && loaded.threshold == 20, "configuration round trip")
        try files.write(SessionStatus(phase: "active", deadline: 123, ownsSleepChange: true, sleepRestored: false), to: "status.json")
        let status = try files.read("status.json", as: SessionStatus.self)
        try expect(status.phase == "active" && status.deadline == 123 && !status.sleepRestored, "guard status round trip")
        try expect(!files.removeIfFinished(), "an active session cannot be removed")
        try expect(!files.removeIfUnstarted(), "unstarted cleanup cannot remove an active guardian")
        let target = root.appendingPathComponent("unrelated.txt")
        try "untouched".write(to: target, atomically: true, encoding: .utf8)
        let statusPath = root.appendingPathComponent("status.json")
        try FileManager.default.removeItem(at: statusPath)
        try FileManager.default.createSymbolicLink(at: statusPath, withDestinationURL: target)
        var rejected = false
        do { _ = try files.read("status.json", as: SessionStatus.self) } catch { rejected = true }
        try expect(rejected, "symlink reads rejected")
        try files.write(SessionStatus(phase: "stopped"), to: "status.json")
        try expect(try String(contentsOf: target, encoding: .utf8) == "untouched", "atomic write does not follow symlink")
        rejected = false
        do { try files.write(SessionControl(), to: "../outside.json") } catch { rejected = true }
        try expect(rejected, "unknown and traversal names rejected")
        let alias = root.appendingPathExtension("alias")
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        rejected = false
        do { _ = try SessionFiles(url: alias) } catch { rejected = true }
        try expect(rejected, "symlink directory rejected")
        try FileManager.default.removeItem(at: root.appendingPathComponent("control.json"))
        let fifo = root.appendingPathComponent("control.json")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw WakecupError(message: "Failed to create FIFO fixture") }
        rejected = false
        do { _ = try files.read("control.json", as: SessionControl.self) } catch { rejected = true }
        try expect(rejected, "FIFO rejected without blocking")
        let payload = "space ' quote $(echo BAD) `echo BAD`\nnext line"
        let result = try command("/bin/sh", ["-c", "printf '%s' " + shellQuote(payload)])
        try expect(result.status == 0 && result.text == payload, "authorization shell quoting preserves literal data")
        try expect(!files.removeIfFinished(), "a terminal directory with unrelated files is not removed")
        try FileManager.default.removeItem(at: target)
        try files.write(SessionStatus(phase: "failed", ownsSleepChange: true, sleepRestored: false), to: "status.json")
        try expect(!files.removeIfFinished(), "failed restoration retains the session")
        try files.write(SessionStatus(phase: "stopped", ownsSleepChange: true), to: "status.json")
        try expect(files.removeIfFinished() && !FileManager.default.fileExists(atPath: root.path),
                   "a terminal, restored session can be removed")
        print("File/IPC checks: \(checks), failures: 0")
    }
}
