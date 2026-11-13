import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Darwin

func continuousNow() -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}

func processIdentity(_ pid: Int32) -> ProcessIdentity? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
    return ProcessIdentity(pid: pid, startedAtMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

func processExists(_ pid: Int32) -> Bool {
    pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
}

final class SleepAssertions {
    private var systemID: IOPMAssertionID?
    private var displayID: IOPMAssertionID?
    private let createAssertion: (String) throws -> IOPMAssertionID
    private let releaseAssertion: (IOPMAssertionID) -> Void
    var ids: [IOPMAssertionID] { [systemID, displayID].compactMap { $0 } }

    init(create: @escaping (String) throws -> IOPMAssertionID = { type in
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Wakecup: активный сеанс" as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw WakecupError(message: "macOS не разрешила удержание сна (\(result)).")
        }
        return id
    }, release: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }) {
        createAssertion = create
        releaseAssertion = release
    }

    // Repeated starts update only display sleep. Keep the system assertion alive
    // throughout a live change; an unsuccessful update retains the old state.
    func start(display: Bool) throws {
        let starting = systemID == nil
        do {
            if starting { systemID = try createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep) }
            if display, displayID == nil {
                displayID = try createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            } else if !display, let id = displayID {
                releaseAssertion(id)
                displayID = nil
            }
        } catch {
            if starting { stop() }
            throw error
        }
    }

    func stop() {
        ids.forEach(releaseAssertion)
        systemID = nil
        displayID = nil
    }

    deinit { stop() }
}

struct CommandOutput {
    let status: Int32
    let text: String
}

// Start suspended so a privileged mutating command cannot run before its
// identity is durably registered in the global lease. Only this direct child
// is signalled and reaped; no process groups or unrelated PIDs are involved.
func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
             onLaunch: ((ProcessIdentity) throws -> Void)? = nil,
             onExit: ((ProcessIdentity) throws -> Void)? = nil) throws -> CommandOutput {
    guard timeout.isFinite, timeout > 0, timeout <= 180 else {
        throw WakecupError(message: "Invalid system command timeout.")
    }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw WakecupError(message: "Could not create the system command pipe.") }
    let input = descriptors[0]
    let output = descriptors[1]
    defer { close(input) }
    guard fcntl(input, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(output, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(input, F_SETFL, O_NONBLOCK) == 0 else {
        close(output)
        throw WakecupError(message: "Could not prepare the system command.")
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        close(output)
        throw WakecupError(message: "Could not prepare the system command.")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
        close(output)
        throw WakecupError(message: "Could not prepare the system command.")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0,
          posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
        close(output)
        throw WakecupError(message: "Could not prepare the system command.")
    }
    var argv = ([path] + arguments).map { strdup($0) } + [nil]
    var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
    var pid: Int32 = 0
    let result = posix_spawn(&pid, path, &actions, &attributes, &argv, &environment)
    close(output)
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    var reaped = false
    var waitStatus: Int32 = 0
    let identity = processIdentity(pid)
    var captured = Data()
    func drain() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Drain even after reaching the output cap, without allowing a noisy
        // child to postpone the deadline forever.
        for _ in 0..<16 {
            let count = Darwin.read(input, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            if captured.count < 65_536 { captured.append(contentsOf: bytes.prefix(min(count, 65_536 - captured.count))) }
        }
    }
    func poll() throws -> Bool {
        if reaped { return true }
        let result = waitpid(pid, &waitStatus, WNOHANG)
        if result == pid { reaped = true; return true }
        if result < 0, errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return false
    }
    func killAndReap() {
        guard !reaped else { return }
        // An unreaped direct child cannot have its PID reused. Re-checking the
        // identity also protects cleanup if a future caller installs SIGCHLD.
        if let identity, identity.matches(processIdentity(pid)) { _ = kill(pid, SIGKILL) }
        else if identity == nil, (try? recoveryProcess(pid))?.parentPID == getpid() { _ = kill(pid, SIGKILL) }
        for _ in 0..<40 {
            drain()
            if (try? poll()) == true { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
    do {
        guard let identity else { throw WakecupError(message: "Could not identify the system command.") }
        try onLaunch?(identity)
        guard kill(pid, SIGCONT) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            drain()
            if try poll() { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WakecupError(message: "The system command timed out. Try recovery again.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drain()
        try onExit?(identity)
        let signal = waitStatus & 0x7f
        let status = signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
        return CommandOutput(status: status, text: String(decoding: captured, as: UTF8.self))
    } catch {
        killAndReap()
        if reaped, let identity { try? onExit?(identity) }
        throw error
    }
}

func parseDisabled(_ text: String) throws -> Bool {
    guard text.contains("System-wide power settings:") else {
        throw WakecupError(message: "Не удалось прочитать настройки сна.")
    }
    for line in text.components(separatedBy: .newlines) {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.first == "SleepDisabled" {
            guard parts.count == 2, parts[1] == "0" || parts[1] == "1" else {
                throw WakecupError(message: "Неизвестное значение SleepDisabled.")
            }
            return parts[1] == "1"
        }
    }
    return false
}

func readDisabled() throws -> Bool {
    try readDisabled(using: { try command($0, $1) })
}

func readDisabled(using execute: (String, [String]) throws -> CommandOutput) throws -> Bool {
    let result = try execute("/usr/bin/pmset", ["-g"])
    guard result.status == 0 else { throw WakecupError(message: "pmset не прочитал настройки.") }
    return try parseDisabled(result.text)
}

func readPowerState() -> PowerState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?,
          provider == kIOPSACPowerValue || provider == kIOPSBatteryPowerValue else { return nil }
    var percent: Int?
    if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0, current >= 0, current <= maximum else { continue }
            percent = Int(floor(Double(current) * 100 / Double(maximum)))
            break
        }
    }
    return PowerState(onAC: provider == kIOPSACPowerValue, percent: percent)
}

func lidClosed() -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}

// Restoration is attempted even when enabling succeeds but its verification fails.
func temporaryDisable(read: () throws -> Bool, write: (Bool) throws -> Void,
                      body: () throws -> Void) throws {
    let previous = try read()
    guard !previous else { throw WakecupError(message: "Сон уже отключён другой настройкой. Сеанс не запущен.") }
    var bodyError: Error?
    do {
        try write(true)
        guard try read() else { throw WakecupError(message: "macOS не включила режим закрытой крышки.") }
        try body()
    } catch { bodyError = error }
    var restored = false
    for _ in 0..<3 {
        do {
            try write(previous)
            restored = try read() == previous
        } catch { restored = false }
        if restored { break }
    }
    guard restored else {
        throw WakecupError(message: "Не удалось вернуть режим сна. Нужна команда восстановления: sudo pmset disablesleep 0")
    }
    if let bodyError { throw bodyError }
}
