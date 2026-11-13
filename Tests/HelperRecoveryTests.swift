import Foundation
import Darwin

@main struct HelperRecoveryTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: " + error.localizedDescription + "\n", stderr); exit(1) }
    }

    private static func run() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw WakecupError(message: message) }; checks += 1
        }
        func child(_ script: String) throws -> (pid: Int32, output: Int32) {
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else { throw WakecupError(message: "Fixture pipe failed") }
            guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
                close(descriptors[0]); close(descriptors[1])
                throw WakecupError(message: "Fixture nonblocking pipe failed")
            }
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw WakecupError(message: "Fixture actions failed") }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawn_file_actions_adddup2(&actions, descriptors[1], 1) == 0,
                  posix_spawn_file_actions_adddup2(&actions, descriptors[1], 2) == 0,
                  posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
                  posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else {
                throw WakecupError(message: "Fixture redirection failed")
            }
            let argumentStrings: [String] = ["/bin/sh", "-c", script]
            let strings = argumentStrings.map { strdup($0) }
            defer { strings.forEach { free($0) } }
            var arguments = strings + [nil], environment: [UnsafeMutablePointer<CChar>?] = [nil], pid: Int32 = 0
            let result = posix_spawn(&pid, "/bin/sh", &actions, nil, &arguments, &environment)
            close(descriptors[1])
            guard result == 0 else { close(descriptors[0]); throw WakecupError(message: "Fixture spawn failed") }
            return (pid, descriptors[0])
        }
        func completion(_ script: String) throws -> Result<Int32, Error> {
            let spawned = try child(script)
            return HelperRecoveryCompletion.wait(pid: spawned.pid, output: spawned.output)
        }
        switch try completion("printf 'recovery rejected\n' >&2; exit 1") {
        case .failure(let error): try expect(error.localizedDescription == "recovery rejected", "Recovery failure lost its diagnostic")
        case .success: throw WakecupError(message: "Failed recovery was acknowledged as successful")
        }
        switch try completion("exit 0") {
        case .success(let pid): try expect(pid > 1, "Successful completion lost its child identifier")
        case .failure(let error): throw error
        }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("wakecup-recovery-completed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        switch try completion("i=0; while [ \"$i\" -lt 10000 ]; do i=$((i+1)); done; : > '" + marker.path + "'; exit 0") {
        case .success: try expect(FileManager.default.fileExists(atPath: marker.path), "Recovery replied before the child completed")
        case .failure(let error): throw error
        }
        switch try completion("kill -TERM $$") {
        case .failure(let error): try expect(!error.localizedDescription.isEmpty, "Signal termination lost its failure")
        case .success: throw WakecupError(message: "Killed recovery was acknowledged as successful")
        }
        switch try completion("exit 1") {
        case .failure(let error): try expect(!error.localizedDescription.isEmpty, "Silent failure needs a fallback diagnostic")
        case .success: throw WakecupError(message: "Silent failure was acknowledged as successful")
        }
        switch try completion("i=0; while [ \"$i\" -lt 40000 ]; do printf x; i=$((i+1)); done; exit 1") {
        case .failure(let error): try expect(error.localizedDescription.utf8.count == HelperRecoveryCompletion.maximumOutput - 3,
                                              "Recovery output was not bounded")
        case .success: throw WakecupError(message: "Noisy failed recovery was acknowledged as successful")
        }
        print("PASS: \(checks) managed recovery completion, diagnostic, signal and bounded-output checks")
    }
}
