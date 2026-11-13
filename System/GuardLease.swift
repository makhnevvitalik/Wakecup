import Foundation
import Darwin

// One root-owned lease serializes all writers of the global SleepDisabled
// flag, across application instances, user accounts and recovery processes.
// The lock inode never changes. The separate owner record is replaced
// atomically so a contender cannot read a partly written process identity.
final class GuardLease {
    private let directory: Int32
    private let lock: Int32
    private var acquired = false
    private var currentOwner: GuardLeaseOwner?

    init() throws {
        let path = "/private/var/run/wakecup"
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw WakecupError(message: "Could not open the system sleep lease.")
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw WakecupError(message: "Could not open the system sleep lease.") }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_mode & 0o777 == 0o700 else {
            close(directory)
            throw WakecupError(message: "Invalid system sleep lease permissions.")
        }
        let lock = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { close(directory); throw WakecupError(message: "Could not open the system sleep lease.") }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == 0, lockInfo.st_nlink == 1,
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o777 == 0o600 else {
            close(lock); close(directory)
            throw WakecupError(message: "Invalid system sleep lease permissions.")
        }
        self.directory = directory
        self.lock = lock
    }

    deinit { close(lock); close(directory) }

    func tryAcquire() throws -> Bool {
        if acquired { return true }
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { acquired = true; return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw WakecupError(message: "Could not acquire the system sleep lease.")
        }
        return false
    }

    func readOwner() throws -> GuardLeaseOwner? {
        let fd = openat(directory, "owner.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw WakecupError(message: "Could not read the system sleep owner.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 8192 else {
            throw WakecupError(message: "Invalid system sleep owner record.")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard data.count <= 8192 else { throw WakecupError(message: "Invalid system sleep owner record.") }
        return try JSONDecoder().decode(GuardLeaseOwner.self, from: data)
    }

    func claim(session: SessionDirectoryIdentity, bootID: String, recovering: Bool) throws {
        guard acquired, let identity = processIdentity(getpid()) else {
            throw WakecupError(message: "Could not acquire the system sleep lease.")
        }
        let owner = GuardLeaseOwner(session: session, process: identity, bootID: bootID, recovering: recovering,
            ownsSleepChange: recovering)
        try save(owner)
        currentOwner = owner
    }

    func armSleepChange() throws {
        guard var owner = currentOwner else { throw WakecupError(message: "Invalid system sleep owner record.") }
        owner.ownsSleepChange = true
        try save(owner)
        currentOwner = owner
    }

    func hasLiveCommands() throws -> Bool {
        let owner = try readOwner()
        for identity in owner?.commands ?? [] {
            if identity.matches(try recoveryProcess(identity.pid)?.identity) { return true }
        }
        return false
    }

    func runCommand(_ path: String, _ arguments: [String]) throws -> CommandOutput {
        guard acquired, currentOwner != nil, try !hasLiveCommands() else {
            throw WakecupError(message: "A previous system command has not stopped. Try recovery again.")
        }
        return try command(path, arguments, onLaunch: { identity in
            guard var owner = self.currentOwner else { throw WakecupError(message: "Invalid system sleep owner record.") }
            owner.commands.append(identity)
            try self.save(owner)
            self.currentOwner = owner
        }, onExit: { identity in
            guard var owner = self.currentOwner else { return }
            owner.commands.removeAll { $0.matches(identity) }
            try self.save(owner)
            self.currentOwner = owner
        })
    }

    private func save(_ owner: GuardLeaseOwner) throws {
        guard acquired else { throw WakecupError(message: "Could not acquire the system sleep lease.") }
        let data = try JSONEncoder().encode(owner)
        guard data.count <= 8192 else { throw WakecupError(message: "Invalid system sleep owner record.") }
        let temporary = ".owner-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WakecupError(message: "Could not save the system sleep owner.") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw WakecupError(message: "Could not save the system sleep owner.") }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, "owner.json") == 0 else {
            throw WakecupError(message: "Could not save the system sleep owner.")
        }
    }
}

func systemBootID() throws -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else {
        throw WakecupError(message: "Could not identify the current boot session.")
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
        throw WakecupError(message: "Could not identify the current boot session.")
    }
    return String(cString: bytes)
}

// A zombie cannot execute further writes. Permission/read errors are not
// interpreted as a dead process, which would incorrectly authorize recovery.
func recoveryProcess(_ pid: Int32) throws -> RecoveryProcess? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard count == MemoryLayout<proc_bsdinfo>.size else {
        if kill(pid, 0) < 0, errno == ESRCH { return nil }
        throw WakecupError(message: "Could not verify the guardian process.")
    }
    if info.pbi_status == 5 { return nil } // SZOMB
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
        throw WakecupError(message: "Could not verify the guardian process.")
    }
    return RecoveryProcess(identity: ProcessIdentity(pid: pid, startedAtMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec),
        parentPID: Int32(info.pbi_ppid), executable: String(cString: path), stopped: info.pbi_status == 4, effectiveUID: info.pbi_uid)
}

func recoveryChildren(_ parent: Int32) throws -> [RecoveryProcess] {
    // A frozen guardian launches one direct pmset at a time. A larger or
    // changing set is refused rather than silently omitting a late writer.
    var pids = [Int32](repeating: 0, count: 64)
    let count = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
    guard count >= 0, count < pids.count else {
        throw WakecupError(message: "Could not verify guardian subprocesses.")
    }
    return try pids.prefix(Int(count)).compactMap { pid in
        guard let child = try recoveryProcess(pid), child.parentPID == parent else { return nil }
        return child
    }
}

func signalRecoveryProcess(_ identity: ProcessIdentity, _ signal: Int32) throws {
    guard identity.matches(try recoveryProcess(identity.pid)?.identity) else { return }
    guard kill(identity.pid, signal) == 0 else {
        if errno == ESRCH { return }
        throw WakecupError(message: "Could not stop the unresponsive guardian.")
    }
}
