import Foundation
import Darwin

// Kept separate from authorization/UI: this entry is called only by a verified,
// root-owned staged copy. The system sleep lease spans the whole transaction.
enum HelperInstaller {
    private static let paths = [HelperConstants.executable, HelperConstants.manifest, HelperConstants.plist]

    static func perform(ownerUID: UInt32, clientHash: String, remove: Bool) throws {
        guard geteuid() == 0, ownerUID > 0, HelperPolicy.validHash(clientHash) else {
            throw WakecupError(message: "Invalid administrator installation request.")
        }
        guard let ownPath = try recoveryProcess(getpid())?.executable,
              PrivilegedExecution.isStagedPath(ownPath),
              let ownBytes = try HelperTrust.read(ownPath, maximum: HelperConstants.maximumExecutableBytes, executable: true) else {
            throw WakecupError(message: "The installer must run from a verified system staging file.")
        }
        let ownHash = try HelperTrust.signingHash()
        for path in paths { try HelperTrust.validateParents(of: path) }
        let lease = try GuardLease()
        guard try lease.tryAcquire(), try !lease.hasLiveCommands(), try !readDisabled() else {
            throw WakecupError(message: "Stop Wakecup and restore normal sleep before changing the helper.")
        }
        // A process may be suspended before writing its first setting. Refuse
        // its live trusted identity even if it no longer holds the lock.
        if let owner = try lease.readOwner(), owner.bootID == (try systemBootID()),
           owner.process.matches(try recoveryProcess(owner.process.pid)?.identity) {
            throw WakecupError(message: "Stop the active Wakecup guardian before changing the helper.")
        }
        let previous = try paths.map { try HelperTrust.read($0, maximum: $0 == HelperConstants.executable ? HelperConstants.maximumExecutableBytes : 16_384,
                                                         executable: $0 == HelperConstants.executable) }
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: ownerUID,
            clientHash: clientHash, helperHash: ownHash, helperSHA256: HelperTrust.sha256(ownBytes))
        let plist: [String: Any] = ["Label": HelperConstants.label,
            "ProgramArguments": [HelperConstants.executable, "--daemon"],
            "MachServices": [HelperConstants.label: true], "AbandonProcessGroup": true,
            "ProcessType": "Background", "UserName": "root"]
        let replacement: [Data?] = remove ? [nil, nil, nil] : [ownBytes, try JSONEncoder().encode(manifest),
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)]
        try installationTransaction(stop: stopService, change: {
            for (index, path) in paths.enumerated() { try replace(path, with: replacement[index]) }
        }, start: {
            if !remove { try startService(expected: manifest) }
        }, rollback: {
            try stopService()
            for (index, path) in paths.enumerated() { try replace(path, with: previous[index]) }
            if previous[2] != nil { try startService() }
        })
        withExtendedLifetime(lease) {}
    }

    private static func stopService() throws {
        let present = try command("/bin/launchctl", ["print", "system/" + HelperConstants.label])
        guard present.status == 0 else { return }
        let stopped = try command("/bin/launchctl", ["bootout", "system/" + HelperConstants.label], timeout: 15)
        guard stopped.status == 0 else { throw WakecupError(message: "Could not stop the installed Wakecup helper.") }
    }
    private static func startService(expected: HelperManifest? = nil) throws {
        let result = try command("/bin/launchctl", ["bootstrap", "system", HelperConstants.plist], timeout: 15)
        guard result.status == 0 else { throw WakecupError(message: "Could not register the Wakecup helper.") }
        let check = try command("/bin/launchctl", ["print", "system/" + HelperConstants.label])
        guard check.status == 0 else { throw WakecupError(message: "The installed Wakecup helper was not registered.") }
        if let expected {
            // Keep the old files and the sleep lease until the real GUI has
            // authenticated to the new daemon. Root can query readiness only;
            // it cannot request a session through this connection.
            let client = HelperClient(hash: expected.helperHash)
            let limit = Date().addingTimeInterval(25)
            var confirmed = false
            while !confirmed && Date() < limit {
                var replied = false
                client.status { result in
                    if case .success(let info) = result { confirmed = info.manifest == expected && info.clientConfirmed }
                    replied = true
                }
                while !replied && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                if !confirmed { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            }
            guard confirmed else { throw WakecupError(message: "The new helper did not authenticate with Wakecup. The previous installation has been restored.") }
        }
    }
    private static func replace(_ path: String, with data: Data?) throws {
        try HelperTrust.validateParents(of: path)
        // Validate an existing target before unlink/rename, including its link count.
        _ = try HelperTrust.read(path, maximum: path == HelperConstants.executable ? HelperConstants.maximumExecutableBytes : 16_384,
                                executable: path == HelperConstants.executable)
        guard let data else {
            guard unlink(path) == 0 || errno == ENOENT else { throw WakecupError(message: "Could not remove the Wakecup helper file.") }
            return
        }
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(".wakecup-" + UUID().uuidString).path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WakecupError(message: "Could not stage a Wakecup helper file.") }
        defer { close(fd); unlink(temporary) }
        try HelperTrust.clearACL(descriptor: fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw WakecupError(message: "Could not write a Wakecup helper file.") }
                offset += written
            }
        }
        guard fchmod(fd, path == HelperConstants.executable ? 0o755 : 0o644) == 0,
              fsync(fd) == 0, rename(temporary, path) == 0 else {
            throw WakecupError(message: "Could not commit a Wakecup helper file.")
        }
    }
}

// Any failed replacement or bootstrap restores the prior installation. Failure
// to restore is surfaced separately; a partial state is never reported as ready.
func installationTransaction(stop: () throws -> Void, change: () throws -> Void,
                             start: () throws -> Void, rollback: () throws -> Void) throws {
    try stop()
    do { try change(); try start() }
    catch {
        let original = error
        do { try rollback() }
        catch { throw WakecupError(message: "Helper installation failed and its previous installation could not be restored: " + error.localizedDescription) }
        throw original
    }
}
