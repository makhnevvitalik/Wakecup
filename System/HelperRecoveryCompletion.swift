import Foundation
import Darwin

// Only the owning parent calls this for its unreaped direct recovery child,
// using a pipe configured nonblocking before spawning that child.
// Drain while waiting, including after the diagnostic cap, so output cannot
// deadlock recovery. The result channel never changes the session ownership.
enum HelperRecoveryCompletion {
    static let maximumOutput = 16_384

    static func wait(pid: Int32, output: Int32) -> Result<Int32, Error> {
        defer { close(output) }
        var captured = Data()
        var status: Int32 = 0
        var reaped = false
        func drain() {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = Darwin.read(output, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                if captured.count < maximumOutput {
                    captured.append(contentsOf: bytes.prefix(min(count, maximumOutput - captured.count)))
                }
            }
        }
        func failure(_ message: String) -> Result<Int32, Error> {
            .failure(WakecupError(message: message))
        }
        guard pid > 1 else { return failure("Invalid recovery completion request.") }
        while !reaped {
            drain()
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true; break }
            if result < 0 && errno != EINTR {
                // ECHILD is not success. The PID may now have been reused,
                // so no signal is permitted after losing reaping ownership.
                return failure("Could not confirm recovery completion.")
            }
            usleep(10_000)
        }
        drain()
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
            let decoded = String(decoding: captured, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostic = String(decoding: decoded.utf8.prefix(maximumOutput - 3), as: UTF8.self)
            return failure(diagnostic.isEmpty ? "Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide." : diagnostic)
        }
        return .success(pid)
    }
}
