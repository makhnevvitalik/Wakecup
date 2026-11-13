import Darwin
import Foundation

@main struct GuardianStatusSocketTests {
    static func main() throws {
        let path = "/private/tmp/wakecup-test-\(UUID().uuidString).sock"
        let socket = try GuardianStatusSocket(path: path, owner: getuid())
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "guardian-test-probe")
        queue.async {
            while received.wait(timeout: .now() + 0.01) == .timedOut {
                socket.answerWaitingProbes()
            }
        }
        let responsive = GuardianStatusSocket.probe(pid: getpid(), owner: getuid(), path: path)
        received.signal()
        queue.sync {}
        try expect(responsive == .responsive, "Live loop answers the probe")
        try expect(GuardianStatusSocket.probe(pid: getpid(), owner: getuid(), path: path, timeout: 50) == .timedOut,
                   "An existing socket cannot hide a stalled loop")
        try expect(GuardianStatusSocket.probe(pid: getpid() + 1, owner: getuid(), path: path) == .unavailable,
                   "A different process cannot stand in for the guard")
        try expect(GuardianStatusSocket.probe(pid: getpid(), owner: getuid(), path: path + ".absent") == .unavailable,
                   "An absent socket is distinct from a stalled authenticated process")
        print("PASS: guardian socket authenticates its peer and distinguishes a stalled loop from a missing endpoint")
    }

    private static func expect(_ passed: Bool, _ message: String) throws {
        guard passed else { throw WakecupError(message: message) }
    }
}
