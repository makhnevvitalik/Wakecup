import Foundation
import CoreGraphics
import ColorSync
import Darwin

private struct BacklightError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BacklightDisplay: Codable, Equatable {
    let id: UInt32
    let uuid: String
}

struct BacklightRecoveryRecord: Codable {
    let version: Int
    let token: UUID
    let ownerUID: UInt32
    let parentPID: Int32
    let display: BacklightDisplay
    let brightness: Float

    init(display: BacklightDisplay, brightness: Float) {
        version = 1; token = UUID(); ownerUID = getuid(); parentPID = getpid()
        self.display = display; self.brightness = brightness
    }

    func validate() throws {
        guard version == 1, ownerUID == getuid(), geteuid() == getuid(), getuid() != 0,
              parentPID > 1, display.id != 0, !display.uuid.isEmpty,
              brightness.isFinite, brightness > 0, brightness <= 1 else {
            throw BacklightError(message: "Invalid backlight recovery information.")
        }
    }

    func save(in directory: URL) throws -> URL {
        try validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw BacklightError(message: "Cannot open backlight recovery directory.") }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw BacklightError(message: "Unsafe backlight recovery directory permissions.")
        }
        let name = token.uuidString + ".json"
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BacklightError(message: "Cannot save backlight recovery information.") }
        defer { close(fd) }
        do {
            let data = try JSONEncoder().encode(self)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw BacklightError(message: "Cannot write backlight recovery information.") }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw BacklightError(message: "Cannot commit backlight recovery information.") }
        } catch { unlinkat(dir, name, 0); throw error }
        return directory.appendingPathComponent(name)
    }

    static func read(from url: URL) throws -> BacklightRecoveryRecord {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BacklightError(message: "Cannot read backlight recovery information.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else {
            throw BacklightError(message: "Unsafe backlight recovery file.")
        }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw BacklightError(message: "Backlight recovery file is too large.") }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate()
        return record
    }
}

struct BacklightRestorer {
    let isRunning: () -> Bool
    let disarm: () throws -> Void
    let requestRestore: () -> Void
}

// Construction is inert. Only begin() is allowed to darken the display.
final class BacklightSession {
    struct Operations {
        var display: () throws -> BacklightDisplay
        var read: (UInt32) throws -> Float
        var write: (UInt32, Float) throws -> Void
        var save: (BacklightRecoveryRecord) throws -> URL
        var remove: (URL) throws -> Void
        var launch: (BacklightRecoveryRecord, URL) throws -> BacklightRestorer
        var pause: (TimeInterval) -> Void
        var validate: (BacklightDisplay) throws -> Void = { _ in }

        static func system() -> Operations {
            let driver = BuiltInBacklight()
            return Operations(display: { try driver.availableDisplay() }, read: { try driver.read($0) },
                write: { try driver.write($0, $1) }, save: { record in
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: true)
                    return try record.save(in: support.appendingPathComponent("Wakecup/BacklightRecovery"))
                }, remove: {
                    if unlink($0.path) != 0 && errno != ENOENT { throw BacklightError(message: "Cannot remove backlight recovery information.") }
                },
                launch: { try BacklightRestoreProcess.launch(record: $0, file: $1) },
                pause: { Thread.sleep(forTimeInterval: $0) }, validate: { try driver.validateIdentity($0) })
        }
    }
    private let operations: Operations
    private var record: BacklightRecoveryRecord?
    private var file: URL?
    private var child: BacklightRestorer?
    var isHealthy: Bool { record != nil && child?.isRunning() == true }
    var needsRestoration: Bool { record != nil }

    init(operations: Operations? = nil) { self.operations = operations ?? .system() }

    func begin() throws {
        if record != nil {
            guard isHealthy else { throw BacklightError(message: "Backlight restoration process stopped. Restore brightness before trying again.") }
            return
        }
        let display = try operations.display()
        let brightness = try operations.read(display.id)
        guard brightness.isFinite, brightness > 0, brightness <= 1 else {
            throw BacklightError(message: "Backlight off requires a supported, awake built-in display with positive brightness.")
        }
        let saved = BacklightRecoveryRecord(display: display, brightness: brightness)
        let savedFile = try operations.save(saved)
        record = saved; file = savedFile
        var attemptedZero = false
        do {
            child = try operations.launch(saved, savedFile) // Returns only after READY.
            guard child?.isRunning() == true else { throw BacklightError(message: "Backlight restoration process did not stay ready.") }
            // Revalidate session/display after launching the safety process.
            guard try operations.display() == display else { throw BacklightError(message: "The built-in display changed during preparation.") }
            attemptedZero = true
            try operations.write(display.id, 0)
            let current = try operations.read(display.id)
            guard current.isFinite, abs(current) <= 0.001, child?.isRunning() == true else {
                throw BacklightError(message: "macOS did not confirm backlight off with a live restoration process.")
            }
        } catch {
            let original = error
            if attemptedZero {
                do { try restore() }
                catch { throw BacklightError(message: "Backlight entry failed and brightness restoration is uncertain. Recovery information and the safety process were retained.") }
            } else {
                // No dark write has occurred. Keep the saved positive value if cleanup is uncertain.
                do { try child?.disarm(); try operations.remove(savedFile); child = nil; record = nil; file = nil }
                catch { child?.requestRestore() }
            }
            throw original
        }
    }

    func restore() throws {
        guard let record else { return }
        do {
            try BacklightRestoreCommand.restore(record: record, write: { id, value in
                try operations.validate(record.display); try operations.write(id, value)
            }, read: { id in
                try operations.validate(record.display); return try operations.read(id)
            }, pause: operations.pause)
        } catch {
            child?.requestRestore() // EOF triggers independent retry; never terminate a safety child.
            throw BacklightError(message: "Could not verify brightness restoration. Recovery information was retained.")
        }
        try child?.disarm()
        if let file { try operations.remove(file) }
        child = nil; file = nil; self.record = nil
    }

    deinit {
        // Releasing the control pipe also covers unexpected owner teardown.
        if record != nil { try? restore() }
    }
}

// Shared by the GUI and independent child; bounded retries cover asynchronous OS rewrites.
enum BacklightRestoreCommand {
    static func restore(record: BacklightRecoveryRecord, write: (UInt32, Float) throws -> Void,
                        read: (UInt32) throws -> Float, pause: (TimeInterval) -> Void) throws {
        guard record.brightness.isFinite, record.brightness > 0, record.brightness <= 1 else {
            throw BacklightError(message: "Refusing to restore an invalid brightness snapshot.")
        }
        var stable = 0
        for _ in 0..<15 {
            do {
                if stable == 0 { try write(record.display.id, record.brightness) }
                pause(0.1)
                let value = try read(record.display.id)
                if value.isFinite, value >= 0, value <= 1, abs(value - record.brightness) <= 0.005 {
                    stable += 1
                    if stable == 3 { return }
                } else { stable = 0 }
            } catch { stable = 0; pause(0.1) }
        }
        throw BacklightError(message: "Brightness did not return to the saved value.")
    }

    static func run(record: BacklightRecoveryRecord, input: FileHandle, output: FileHandle,
                    write: (UInt32, Float) throws -> Void, read: (UInt32) throws -> Float,
                    pause: (TimeInterval) -> Void) -> Int32 {
        do {
            try record.validate()
            try output.write(contentsOf: Data("READY\n".utf8))
            // One byte is enough: D is sent only after verified restoration; EOF or R restores.
            let command = try input.read(upToCount: 1) ?? Data()
            // Distinguish a parent-verified restore so only its parent removes the record.
            if command.first == UInt8(ascii: "D") { return 2 }
            try restore(record: record, write: write, read: read, pause: pause)
            return 0
        } catch { return 1 }
    }

    static func main(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == "--restore-backlight" else { return 1 }
        do {
            let file = URL(fileURLWithPath: arguments[2])
            let record = try BacklightRecoveryRecord.read(from: file)
            guard record.parentPID == getppid() else { throw BacklightError(message: "Backlight restorer parent changed.") }
            let driver = BuiltInBacklight()
            try driver.validateIdentity(record.display)
            let status = run(record: record, input: .standardInput, output: .standardOutput,
                write: { try driver.validateIdentity(record.display); try driver.write($0, $1) },
                read: { try driver.validateIdentity(record.display); return try driver.read($0) },
                pause: { Thread.sleep(forTimeInterval: $0) })
            if status == 0 { try? FileManager.default.removeItem(at: file) }
            return status == 2 ? 0 : status
        } catch { return 1 }
    }
}

final class BacklightRestoreProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var closed = false

    static func launch(record: BacklightRecoveryRecord, file: URL) throws -> BacklightRestorer {
        let owner = BacklightRestoreProcess()
        owner.process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        owner.process.arguments = ["--restore-backlight", file.path]
        owner.process.standardInput = owner.input
        owner.process.standardOutput = owner.output
        owner.process.standardError = FileHandle.nullDevice
        guard fcntl(owner.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw BacklightError(message: "Cannot prepare the backlight restoration control pipe.")
        }
        try owner.process.run()
        do {
            var ready = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ready.count < 6 && ProcessInfo.processInfo.systemUptime < deadline {
                var event = pollfd(fd: owner.output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&event, 1, 50)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0, owner.process.isRunning else { throw BacklightError(message: "Backlight restoration process exited before READY.") }
                if result > 0 {
                    let bytes = try owner.output.fileHandleForReading.read(upToCount: 6 - ready.count) ?? Data()
                    guard !bytes.isEmpty else { throw BacklightError(message: "Backlight restoration process closed its readiness pipe.") }
                    ready.append(bytes)
                }
            }
            guard ready == Data("READY\n".utf8) else { throw BacklightError(message: "Backlight restoration process did not acknowledge readiness.") }
            return BacklightRestorer(isRunning: { owner.process.isRunning }, disarm: {
                if owner.process.isRunning && !owner.closed {
                    try owner.input.fileHandleForWriting.write(contentsOf: Data("D".utf8))
                }
                owner.closeInput()
                // Waiting is bounded; the process is never killed if its outcome is uncertain.
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while owner.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard !owner.process.isRunning else {
                    throw BacklightError(message: "Backlight restoration process is still finishing. Try restoring brightness again.")
                }
            }, requestRestore: { owner.closeInput() })
        } catch { owner.closeInput(); throw error }
    }

    private func closeInput() {
        if !closed { closed = true; try? input.fileHandleForWriting.close() }
    }
    deinit { closeInput() }
}

private final class BuiltInBacklight {
    typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (UInt32, Float) -> Int32
    private var library: UnsafeMutableRawPointer?
    private var getter: Get?
    private var setter: Set?

    private func load() throws {
        if getter != nil { return }
        guard getuid() != 0, geteuid() == getuid(),
              let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW | RTLD_LOCAL) else {
            throw BacklightError(message: "Built-in brightness control is unavailable.")
        }
        guard let get = dlsym(library, "DisplayServicesGetBrightness"), let set = dlsym(library, "DisplayServicesSetBrightness") else {
            dlclose(library)
            throw BacklightError(message: "This macOS version does not support built-in brightness control.")
        }
        self.library = library
        getter = unsafeBitCast(get, to: Get.self); setter = unsafeBitCast(set, to: Set.self)
    }
    deinit { if let library { dlclose(library) } }

    func availableDisplay() throws -> BacklightDisplay {
        try load()
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              session["kCGSSessionOnConsoleKey"] as? Bool == true else {
            throw BacklightError(message: "Unlock the active Mac session before turning the backlight off.")
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displays, &count) == .success else { throw BacklightError(message: "Cannot identify the built-in display.") }
        let builtIn = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
        guard builtIn.count == 1, let id = builtIn.first, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw BacklightError(message: "Backlight off requires an awake built-in Mac display.")
        }
        return BacklightDisplay(id: id, uuid: CFUUIDCreateString(nil, uuid) as String)
    }

    func validateIdentity(_ display: BacklightDisplay) throws {
        guard CGDisplayIsBuiltin(display.id) != 0, CGDisplayIsOnline(display.id) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue(),
              CFUUIDCreateString(nil, uuid) as String == display.uuid else {
            throw BacklightError(message: "Saved built-in display identity is no longer available.")
        }
    }
    func read(_ display: UInt32) throws -> Float {
        try load()
        var value: Float = -1
        guard getter?(display, &value) == 0, value.isFinite, value >= 0, value <= 1 else {
            throw BacklightError(message: "Cannot read a valid built-in display brightness.")
        }
        return value
    }
    func write(_ display: UInt32, _ brightness: Float) throws {
        try load()
        guard brightness.isFinite, brightness >= 0, brightness <= 1, setter?(display, brightness) == 0 else {
            throw BacklightError(message: "macOS refused the built-in brightness change.")
        }
    }
}
