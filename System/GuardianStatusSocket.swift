import Darwin
import Foundation

// The guard serves these requests on its monitoring loop. A separate server
// thread could still answer while the loop responsible for sleep was stuck.
final class GuardianStatusSocket {
    enum Reply: Equatable { case responsive, timedOut, unavailable }

    static let path = "/private/var/run/wakecup-status/socket"
    private static let response: UInt8 = 1
    private let descriptor: Int32
    private let path: String

    static func system(owner: uid_t) throws -> GuardianStatusSocket {
        let directory = (path as NSString).deletingLastPathComponent
        guard mkdir(directory, 0o755) == 0 || errno == EEXIST else { throw setupError }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o755 else { throw setupError }
        // The caller holds the global sleep lease, so this pathname cannot
        // belong to another guard running the sleep loop.
        guard unlink(path) == 0 || errno == ENOENT else { throw setupError }
        return try GuardianStatusSocket(path: path, owner: owner)
    }

    init(path: String, owner: uid_t) throws {
        guard let address = Self.address(path), let fd = Self.openSocket() else { throw Self.setupError }
        guard Self.withAddress(address, { bind(fd, $0, $1) }) == 0 else {
            close(fd)
            throw Self.setupError
        }
        guard (geteuid() == owner || chown(path, owner, gid_t.max) == 0),
              chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            throw Self.setupError
        }
        self.path = path
        descriptor = fd
    }

    deinit {
        close(descriptor)
        unlink(path)
    }

    func answerWaitingProbes() {
        // Bound the work in one iteration even if requests keep arriving.
        for _ in 0..<16 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard Self.configure(client) else { continue }
            var response = Self.response
            _ = send(client, &response, 1, 0)
        }
    }

    static func probe(pid: pid_t, owner: uid_t = 0, path: String = path, timeout: Int32 = 1_500) -> Reply {
        guard pid > 1, let address = address(path), let fd = openSocket() else { return .unavailable }
        defer { close(fd) }
        guard withAddress(address, { connect(fd, $0, $1) }) == 0 else { return .unavailable }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == owner,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0,
              peerPID == pid else { return .unavailable }
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&readable, 1, timeout)
        if result == 0 { return .timedOut }
        var byte: UInt8 = 0
        guard result > 0, recv(fd, &byte, 1, 0) == 1, byte == response else { return .unavailable }
        return .responsive
    }

    private static var setupError: WakecupError { WakecupError(message: "Could not open the guardian status socket.") }

    private static func openSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard configure(fd) else { close(fd); return nil }
        return fd
    }

    private static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size - capacity + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return address
    }

    private static func withAddress(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = address
        let length = socklen_t(address.sun_len)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) } }
    }
}
