import Darwin
import Foundation

/// Local, per-user command transport. One bounded JSON request per connection.
final class AutomationSocket {
    static var systemPath: String {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        var buffer = [CChar](repeating: 0, count: count)
        let directory = count > 0 && confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count) == count
            ? String(cString: buffer) : NSTemporaryDirectory()
        return URL(fileURLWithPath: directory).appendingPathComponent("wakecup/control").path
    }
    private static let maxMessage = 32 * 1024
    private let listener: DispatchSourceRead

    init(path: String = systemPath, receive: @escaping (AutomationEnvelope) -> AutomationReply) throws {
        let directory = (path as NSString).deletingLastPathComponent
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw Self.failure("Cannot create the command directory.") }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw Self.failure("Invalid command directory permissions.") }

        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Self.failure("Cannot open the Wakecup command lock.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw Self.failure("Another Wakecup instance already handles commands.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); throw Self.failure("Cannot create the Wakecup command socket.") }
        var bound = false
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw Self.failure("Cannot configure the Wakecup command socket.")
            }
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
                    throw Self.failure("Invalid Wakecup command socket.")
                }
            }
            bound = try Self.withAddress(path) { bind(fd, $0, $1) } == 0
            guard bound, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                throw Self.failure("Cannot listen for Wakecup commands.")
            }
        } catch {
            close(fd)
            if bound { unlink(path) }
            close(lock)
            throw error
        }
        let queue = DispatchQueue(label: "local.wakecup.automation")
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setCancelHandler {
            close(fd)
            unlink(path)
            close(lock)
        }
        listener.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard Self.configure(client), Self.sameUser(client) else { return }
            do {
                let data = try Self.readLine(client)
                let envelope = try AutomationJSON.decode(AutomationEnvelope.self, from: data)
                let reply = DispatchQueue.main.sync { receive(envelope) }
                try Self.writeLine(AutomationJSON.encode(reply), to: client)
            } catch {
                let reply = AutomationReply(outcome: .rejected, message: "Invalid Wakecup command or connection closed.")
                if let data = try? AutomationJSON.encode(reply) { try? Self.writeLine(data, to: client) }
            }
        }
        listener.resume()
    }

    deinit { listener.cancel() }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Wakecup is not running or its command socket is unavailable." }
    }

    static func send(_ envelope: AutomationEnvelope, path: String = systemPath) throws -> AutomationReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("Cannot open a Wakecup command connection.") }
        defer { close(fd) }
        guard configure(fd) else { throw failure("Cannot configure the Wakecup command connection.") }
        guard try withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw Unavailable() }
            throw failure("Cannot connect to the Wakecup command socket.")
        }
        guard sameUser(fd) else { throw failure("The Wakecup command socket belongs to another user.") }
        try writeLine(AutomationJSON.encode(envelope), to: fd)
        return try AutomationJSON.decode(AutomationReply.self, from: readLine(fd, timeout: 15))
    }

    private static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    private static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, 0) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            && setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    private static func readLine(_ fd: Int32, timeout: TimeInterval = 2) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while data.count < maxMessage {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&ready, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { break }
            let length = read(fd, &buffer, min(buffer.count, maxMessage - data.count))
            if length < 0 && errno == EINTR { continue }
            guard length > 0 else { break }
            let bytes = buffer.prefix(length)
            if let end = bytes.firstIndex(of: 10) {
                data.append(contentsOf: bytes[..<end])
                return data
            }
            data.append(contentsOf: bytes)
        }
        throw failure("Wakecup command timed out, closed, or exceeded its message limit. Check status before retrying.")
    }

    private static func writeLine(_ data: Data, to fd: Int32) throws {
        guard data.count < maxMessage else { throw failure("Wakecup command exceeds its message limit.") }
        var line = data
        line.append(10)
        try line.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let length = Darwin.send(fd, start.advanced(by: offset), buffer.count - offset, 0)
                if length < 0 && errno == EINTR { continue }
                guard length > 0 else { throw failure("Wakecup command connection closed. Check status before retrying.") }
                offset += length
            }
        }
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw failure("Wakecup command socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = MemoryLayout<sockaddr_un>.size - capacity + bytes.count
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init(bitPattern:))) }
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(length)) } }
    }

    private static func failure(_ message: String) -> WakecupError { WakecupError(message: message) }
}
