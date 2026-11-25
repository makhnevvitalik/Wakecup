import Foundation
import Darwin

struct RecoveryProcess {
    let identity: ProcessIdentity
    let parentPID: Int32
    let executable: String
    let stopped: Bool
    let effectiveUID: UInt32
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
