import Foundation
import Darwin
import Security

@main struct HelperPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw WakecupError(message: message) }; checks += 1
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw WakecupError(message: "Unsafe helper request accepted")
        }
        try expect(NSStringFromProtocol(WakecupHelperProtocol.self) == "WakecupHelperProtocol", "GUI and helper must share one protocol name")
        let requirement = try HelperPolicy.requirement(identifier: HelperConstants.clientIdentifier, hash: String(repeating: "a", count: 40))
        var compiled: SecRequirement?
        try expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
                   "macOS rejected the helper code-signing requirement")
        try rejects { _ = try HelperPolicy.requirement(identifier: "other.app", hash: String(repeating: "a", count: 40)) }
        let peer = ProcessIdentity(pid: getpid(), startedAtMicroseconds: 123)
        let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: 60,
            powerMode: .battery, threshold: 20, closedLid: true, keepDisplayOn: false, parentIdentity: peer)
        try HelperPolicy.validate(configuration: config, peer: peer, restoreOnly: false)
        checks += 1
        try rejects { try HelperPolicy.validate(configuration: config, peer: ProcessIdentity(pid: peer.pid, startedAtMicroseconds: 124), restoreOnly: false) }
        try HelperPolicy.validate(configuration: config, peer: ProcessIdentity(pid: peer.pid + 1, startedAtMicroseconds: 124), restoreOnly: true)
        checks += 1
        for path in ["relative", "", "/a\u{0}b", "/" + String(repeating: "a", count: 4096)] {
            try rejects { try HelperPolicy.validate(path: path) }
        }
        try HelperPolicy.validate(path: "/Users/test/Session")
        checks += 1
        for hash in ["", "x", String(repeating: "g", count: 40), String(repeating: "a", count: 39)] {
            try expect(!HelperPolicy.validHash(hash), "Invalid signing hash")
        }
        try expect(HelperPolicy.validHash(String(repeating: "a", count: 40)), "Valid hash rejected")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try SessionFiles.create(at: directory, configuration: config)
        try rejects { _ = try SessionFiles(url: directory, expectedOwner: getuid() + 1) }
        let context = ManagedGuardContext(ownerUID: getuid(), directory: files.identity, configuration: config, peer: peer, restoreOnly: false)
        try context.validate(files: files)
        checks += 1
        let changed = SessionConfiguration(id: config.id, parentPID: config.parentPID, duration: nil,
            powerMode: .battery, threshold: 10, closedLid: true, keepDisplayOn: true, parentIdentity: peer)
        try files.write(changed, to: "configuration.json")
        try rejects { try context.validate(files: files) }
        try rejects { _ = try ManagedGuardContext.decode(String(repeating: "A", count: 20000)) }
        let huge = directory.appendingPathComponent("control.json")
        try Data(repeating: 0x20, count: 65537).write(to: huge)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: huge.path)
        try rejects { _ = try files.read("control.json", as: SessionControl.self) }
        try HelperTrust.rejectAllowACL(path: directory.path)
        let acl = try command("/bin/chmod", ["+a", "user:" + NSUserName() + " allow add_file,delete_child,file_inherit,directory_inherit", directory.path])
        try expect(acl.status == 0, "Could not create ACL fixture: " + acl.text)
        try rejects { try HelperTrust.rejectAllowACL(path: directory.path) }
        let inherited = directory.appendingPathComponent("inherited.txt")
        try Data("fixture".utf8).write(to: inherited)
        try rejects { try HelperTrust.rejectAllowACL(path: inherited.path) }
        let descriptor = open(inherited.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw WakecupError(message: "Could not open ACL fixture") }
        try HelperTrust.clearACL(descriptor: descriptor)
        try HelperTrust.rejectAllowACL(descriptor: descriptor)
        close(descriptor)
        checks += 1
        _ = try command("/bin/chmod", ["-N", directory.path])
        var children = HelperChildren()
        children.insert(HelperChildren.Child(path: directory.path, directory: files.identity, configuration: config, pid: 123), restoreOnly: false)
        try expect(try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: false) == 123,
                   "Duplicate start must reuse the child")
        try expect(try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: true) == nil,
                   "Recovery of a live hung normal child must be allowed")
        try rejects { _ = try children.existing(path: directory.path, directory: files.identity, configuration: changed, restoreOnly: true) }
        children.insert(HelperChildren.Child(path: directory.path, directory: files.identity, configuration: config, pid: 124), restoreOnly: true)
        try expect(try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: true) == 124,
                   "Duplicate recovery must reuse the recovery child")
        children.remove(pid: 123, restoreOnly: false)
        try rejects { _ = try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: false) }
        children.remove(pid: 100, restoreOnly: true)
        try expect(try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: true) == 124,
                   "An old completion must not clear a different child")
        children.remove(pid: 124, restoreOnly: true)
        try expect(try children.existing(path: directory.path, directory: files.identity, configuration: config, restoreOnly: false) == nil,
                   "Completed recovery must release the slot")
        for failingStage in ["change", "start"] {
            var state = "old", stopped = false, restored = false
            try rejects {
                try installationTransaction(stop: { stopped = true }, change: {
                    state = "partial"
                    if failingStage == "change" { throw WakecupError(message: "write failed") }
                    state = "new"
                }, start: { throw WakecupError(message: "bootstrap failed") }, rollback: { state = "old"; restored = true })
            }
            try expect(stopped && restored && state == "old", "A failed installation did not restore the prior state")
        }
        var mutated = false
        try rejects {
            try installationTransaction(stop: { throw WakecupError(message: "service busy") }, change: { mutated = true },
                                        start: {}, rollback: { mutated = true })
        }
        try expect(!mutated, "A busy service must fail before touching its installation")
        var state = "old"
        try installationTransaction(stop: {}, change: { state = "new" }, start: {}, rollback: { state = "old" })
        try expect(state == "new", "A successful installation unexpectedly rolled back")
        print("PASS: \(checks) helper policy, ownership, immutable configuration, bounded-read and installer rollback checks")
    }
}
