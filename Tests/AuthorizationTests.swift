import Foundation
import Darwin

// Executes only owned shell fixtures, never osascript, root, a real helper or pmset.
@main struct AuthorizationTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wakecup-authorization-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("helper ' $(printf unsafe)")
        let original = Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8)
        try original.write(to: source)
        let digest = HelperTrust.sha256(original)
        let argument = "literal ' $() `printf unsafe`\nargument"
        let protected = root.appendingPathComponent("protected").path
        try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: false)
        func fixture(_ script: String) -> String {
            // Root ownership/ACL enforcement stays intact in production; tests
            // redirect the stage and omit only the two root-directory checks.
            script.replacingOccurrences(of: "        check_dir /Library\n", with: "")
                .replacingOccurrences(of: "check_dir /Library\n", with: "")
                .replacingOccurrences(of: "check_dir /Library/PrivilegedHelperTools\n", with: "")
                .replacingOccurrences(of: "/Library/PrivilegedHelperTools", with: protected)
        }
        let script = try PrivilegedExecution.stagingScript(source: source, sha256: digest, arguments: [argument], detached: false)
        try expect(!script.contains(shellQuote(source.path) + " " + shellQuote(argument)), "Source path must never be invoked")
        let normal = try command("/bin/sh", ["-c", fixture(script)])
        try expect(normal.status == 0 && normal.text == argument, "Verified payload and quoted argument must run unchanged")
        let oversized = root.appendingPathComponent("oversized")
        let oversizedBytes = Data(("#!/bin/sh\nexit 0\n" + String(repeating: " ", count: 8192)).utf8)
        try oversizedBytes.write(to: oversized)
        let oversizedScript = try PrivilegedExecution.stagingScript(source: oversized, sha256: HelperTrust.sha256(oversizedBytes), arguments: [], detached: false)
        let boundedFixture = fixture(oversizedScript).replacingOccurrences(of: String(HelperConstants.maximumExecutableBytes), with: "4096")
        let oversizedResult = try command("/bin/sh", ["-c", boundedFixture])
        try expect(oversizedResult.status == 72, "Oversized helper must be rejected before copy/hash/execution")
        let exact = root.appendingPathComponent("exact-cap")
        let header = "#!/bin/sh\nexit 0\n"
        let exactBytes = Data((header + String(repeating: " ", count: 4096 - header.utf8.count)).utf8)
        try exactBytes.write(to: exact)
        let exactScript = try PrivilegedExecution.stagingScript(source: exact, sha256: HelperTrust.sha256(exactBytes), arguments: [], detached: false)
        let exactResult = try command("/bin/sh", ["-c", fixture(exactScript).replacingOccurrences(of: String(HelperConstants.maximumExecutableBytes), with: "4096")])
        try expect(exactResult.status == 0, "Authenticated source exactly at the limit must be accepted")
        let fifo = root.appendingPathComponent("source-fifo")
        try expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture must be created")
        let sourceLink = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        let zeroLink = root.appendingPathComponent("zero-link")
        try FileManager.default.createSymbolicLink(atPath: zeroLink.path, withDestinationPath: "/dev/zero")
        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        let sparse = root.appendingPathComponent("oversized-sparse")
        try Data().write(to: sparse)
        let sparseFile = try FileHandle(forWritingTo: sparse)
        try sparseFile.truncate(atOffset: UInt64(HelperConstants.maximumExecutableBytes) + 1)
        try sparseFile.close()
        for invalid in [fifo, sourceLink, zeroLink, URL(fileURLWithPath: "/dev/zero"), root, empty, sparse] {
            let candidate = try PrivilegedExecution.stagingScript(source: invalid, sha256: digest, arguments: [], detached: false)
            let started = ProcessInfo.processInfo.systemUptime
            let result = try command("/bin/sh", ["-c", fixture(candidate)], timeout: 2)
            try expect(result.status == 72 && ProcessInfo.processInfo.systemUptime - started < 2,
                "Nonregular, linked, empty or oversized source must fail promptly: " + invalid.lastPathComponent)
            var rejectedSource = false
            do { _ = try PrivilegedExecution.sourceDigest(at: invalid) } catch { rejectedSource = true }
            try expect(rejectedSource, "Preflight must reject unsafe source: " + invalid.lastPathComponent)
            try expect(try FileManager.default.contentsOfDirectory(atPath: protected).isEmpty, "Rejected copy must remove its stage")
        }
        try expect(try PrivilegedExecution.sourceDigest(at: source) == digest, "Regular preflight must compute the expected digest")
        let hardlink = root.appendingPathComponent("source-hardlink")
        try expect(link(source.path, hardlink.path) == 0, "Hardlink fixture must be created")
        let parentLink = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        for alias in [hardlink, parentLink.appendingPathComponent(source.lastPathComponent)] {
            let candidate = try PrivilegedExecution.stagingScript(source: alias, sha256: digest, arguments: [argument], detached: false)
            let result = try command("/bin/sh", ["-c", fixture(candidate)])
            try expect(result.status == 0 && result.text == argument, "Authenticated regular aliases must remain usable")
            try expect(try PrivilegedExecution.sourceDigest(at: alias) == digest, "Regular alias preflight must remain usable")
        }
        let digestStep = "my $digest = Digest::SHA->new(256);"
        let growth = #"open(my $growth, ">>", $source) or reject_copy(); print $growth "x" x 8192; close($growth); "# + digestStep
        let growing = fixture(script).replacingOccurrences(of: String(HelperConstants.maximumExecutableBytes), with: "4096")
            .replacingOccurrences(of: digestStep, with: growth)
        let grew = try command("/bin/sh", ["-c", growing])
        try expect(grew.status == 72, "Source growth after fstat must be bounded during streaming")
        try original.write(to: source)
        let swap = #"rename($source, $source . ".opened") or reject_copy(); open(my $replacement, ">", $source) or reject_copy(); print $replacement "replaced"; close($replacement); "# + digestStep
        let fdBound = fixture(script).replacingOccurrences(of: digestStep, with: swap)
        let swapped = try command("/bin/sh", ["-c", fdBound])
        try expect(swapped.status == 0 && swapped.text == argument, "Copy must retain the original descriptor across source path replacement")
        try Data("#!/bin/sh\nprintf REPLACED".utf8).write(to: source)
        let replaced = try command("/bin/sh", ["-c", fixture(script)])
        try expect(replaced.status == 71 && !replaced.text.contains("REPLACED"), "Replacement before approval must fail its compiled pin")
        try original.write(to: source)
        let replacement = root.appendingPathComponent("replacement")
        try Data("#!/bin/sh\nprintf REPLACED".utf8).write(to: replacement)
        let afterCopy = fixture(script).replacingOccurrences(of: "/bin/chmod 755 \"$stage\"", with:
            "/bin/chmod 755 \"$stage\"\n/bin/cat " + shellQuote(replacement.path) + " > " + shellQuote(source.path))
        let protectedResult = try command("/bin/sh", ["-c", afterCopy])
        try expect(protectedResult.status == 0 && protectedResult.text == argument, "Replacing the writable source after verification cannot change the protected executed bytes")
        try expect(try FileManager.default.contentsOfDirectory(atPath: protected).isEmpty, "Synchronous stages must be cleaned up")
        let backgroundBytes = Data("#!/bin/sh\n/bin/sleep 0.3\nprintf DONE > \"$1\"\n".utf8)
        try backgroundBytes.write(to: source)
        let marker = root.appendingPathComponent("completed")
        let background = try PrivilegedExecution.stagingScript(source: source, sha256: HelperTrust.sha256(backgroundBytes), arguments: [marker.path], detached: true)
        try expect(background.contains("trap - EXIT") && background.components(separatedBy: "trap '/bin/rm -f \"$stage\"' EXIT").count == 3,
            "Detached supervisor must retain stage cleanup after the outer shell returns")
        let launched = try command("/bin/sh", ["-c", fixture(background)])
        try expect(launched.status == 0, "Detached authorization must return after launch")
        let limit = Date().addingTimeInterval(3)
        while Date() < limit {
            if FileManager.default.fileExists(atPath: marker.path), try FileManager.default.contentsOfDirectory(atPath: protected).isEmpty { break }
            usleep(10_000)
        }
        try expect((try? String(contentsOf: marker, encoding: .utf8)) == "DONE", "Detached stage must survive until its child executes")
        try expect(try FileManager.default.contentsOfDirectory(atPath: protected).isEmpty, "Detached supervisor must clean up after child exit")
        try expect(PrivilegedExecution.isStagedPath("/Library/PrivilegedHelperTools/.wakecup-stage-aB12cD34"), "Canonical stage accepted")
        for path in ["/Library/PrivilegedHelperTools/.wakecup-stage-x/../other", "/Library/PrivilegedHelperTools/.wakecup-stage-12345678/child", "/tmp/.wakecup-stage-12345678", "/Library/PrivilegedHelperTools/.wakecup-stage-12345678/", "/Library/PrivilegedHelperTools/.wakecup-stage-123456789"] {
            try expect(!PrivilegedExecution.isStagedPath(path), "Noncanonical stage rejected")
        }
        var rejected = false
        do { _ = try PrivilegedExecution.stagingScript(source: source, sha256: "invalid", arguments: [], detached: false) }
        catch { rejected = true }
        try expect(rejected, "Invalid pin rejected")
        let task = PrivilegedExecution.authorizationTask(script: script)
        try expect(task.executableURL?.path == "/usr/bin/osascript" && !task.isRunning, "Authorization is prepared without executing it")
        print("PASS: bounded regular-file copy/preflight; FIFO/device/symlink/sparse rejection; growth/path-swap protection; aliases, pinned staging and cleanup; no elevation")
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WakecupError(message: message) }
    }
}
