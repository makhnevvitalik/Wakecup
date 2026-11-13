import Foundation
import Darwin

// The privileged process only accesses these three JSON names through a retained
// directory descriptor. No root writes follow paths or symlinks supplied by UI.
final class SessionFiles {
    let url: URL
    let identity: SessionDirectoryIdentity
    private let directory: Int32
    let owner: uid_t
    private let group: gid_t
    private let names: Set<String> = ["configuration.json", "control.json", "status.json"]

    init(url: URL, expectedOwner: uid_t? = nil) throws {
        self.url = url
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WakecupError(message: "Не удалось открыть каталог сеанса.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700, info.st_uid != 0,
              expectedOwner == nil || info.st_uid == expectedOwner else {
            close(descriptor)
            throw WakecupError(message: "Недопустимые права каталога сеанса.")
        }
        directory = descriptor
        identity = SessionDirectoryIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
        owner = info.st_uid
        group = info.st_gid
    }

    deinit { close(directory) }

    func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard names.contains(name) else { throw WakecupError(message: "Неизвестный файл сеанса.") }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WakecupError(message: "Не удалось прочитать состояние сеанса.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == owner, info.st_nlink == 1,
              (info.st_mode & 0o777) == 0o600, info.st_size <= 65_536 else {
            throw WakecupError(message: "Недопустимый файл состояния сеанса.")
        }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw WakecupError(message: "Состояние сеанса слишком велико.") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, to name: String) throws {
        guard names.contains(name) else { throw WakecupError(message: "Неизвестный файл сеанса.") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw WakecupError(message: "Состояние сеанса слишком велико.") }
        let temporary = "." + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WakecupError(message: "Не удалось сохранить состояние сеанса.") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        if geteuid() == 0, fchown(fd, owner, group) != 0 {
            throw WakecupError(message: "Не удалось установить владельца файла сеанса.")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw WakecupError(message: "Ошибка записи состояния сеанса.") }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else {
            throw WakecupError(message: "Не удалось зафиксировать состояние сеанса.")
        }
    }

    // A guardian holds this lock while it can change sleep. Wakecup can also
    // take it after recording Stop to confirm a session never began.
    func tryLockGuardianAccess() throws -> Bool {
        if flock(directory, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw WakecupError(message: "Не удалось открыть каталог сеанса.")
    }

    func unlockGuardianAccess() { flock(directory, LOCK_UN) }

    func removeIfFinished() -> Bool {
        guard let status = try? read("status.json", as: SessionStatus.self),
              status.sleepRestored, status.phase == "stopped" || status.phase == "failed" else { return false }
        return removeSessionFiles()
    }

    // Call only when no guardian can start or be running for these files.
    func removeIfUnstarted() -> Bool {
        guard let status = try? read("status.json", as: SessionStatus.self),
              status.phase == "preparing", status.helperPID == 0, !status.ownsSleepChange, status.sleepRestored else { return false }
        return removeSessionFiles()
    }

    // Keep the status file until the other known files have been removed.
    private func removeSessionFiles() -> Bool {
        var info = stat()
        guard geteuid() == owner, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              UInt64(UInt32(bitPattern: info.st_dev)) == identity.device, info.st_ino == identity.inode,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              Set(entries).isSubset(of: names) else { return false }
        for name in ["configuration.json", "control.json", "status.json"] {
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { return false }
        }
        return rmdir(url.path) == 0
    }

    static func create(at url: URL, configuration: SessionConfiguration) throws -> SessionFiles {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let files = try SessionFiles(url: url)
        try files.write(configuration, to: "configuration.json")
        try files.write(SessionControl(), to: "control.json")
        try files.write(SessionStatus(phase: "preparing"), to: "status.json")
        return files
    }
}
