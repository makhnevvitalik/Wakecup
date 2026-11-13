import Foundation
import Darwin

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let manifest: HelperManifest
    private var clientConfirmed = false
    private let queue = DispatchQueue(label: "local.wakecup.helper.requests")
    private var children = HelperChildren()

    init(manifest: HelperManifest) { self.manifest = manifest }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard [0, manifest.ownerUID].contains(connection.effectiveUserIdentifier),
              let peer = processIdentity(connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: WakecupHelperProtocol.self)
        connection.exportedObject = HelperPeer(service: self, connection: connection, peer: peer)
        connection.resume()
        return true
    }

    fileprivate func information(version: Int, callerUID: UInt32, reply: @escaping (Data?, String?) -> Void) {
        guard version == HelperConstants.protocolVersion else { reply(nil, "The Wakecup helper needs an update."); return }
        queue.async {
            if callerUID == self.manifest.ownerUID { self.clientConfirmed = true }
            do { reply(try JSONEncoder().encode(HelperInformation(manifest: self.manifest, clientConfirmed: self.clientConfirmed)), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    fileprivate func start(version: Int, path: String, restoreOnly: Bool, connection: NSXPCConnection,
                           peer: ProcessIdentity, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            do {
                guard version == HelperConstants.protocolVersion,
                      connection.effectiveUserIdentifier == self.manifest.ownerUID,
                      peer.matches(processIdentity(connection.processIdentifier)) else {
                    throw WakecupError(message: "The Wakecup connection is no longer valid.")
                }
                try HelperPolicy.validate(path: path)
                let files = try SessionFiles(url: URL(fileURLWithPath: path), expectedOwner: self.manifest.ownerUID)
                let config = try files.read("configuration.json", as: SessionConfiguration.self)
                try HelperPolicy.validate(configuration: config, peer: peer, restoreOnly: restoreOnly)
                if let pid = try self.children.existing(path: path, directory: files.identity, configuration: config, restoreOnly: restoreOnly) {
                    if restoreOnly {
                        throw WakecupError(message: "Recovery is already in progress. Check the session status before trying again.")
                    }
                    reply(pid, nil); return
                }
                let status = try files.read("status.json", as: SessionStatus.self)
                guard restoreOnly || status.phase == "preparing" else {
                    throw WakecupError(message: "This session has already been started. Check its current status.")
                }
                let context = ManagedGuardContext(ownerUID: self.manifest.ownerUID, directory: files.identity,
                    configuration: config, peer: peer, restoreOnly: restoreOnly)
                let encoded = try JSONEncoder().encode(context).base64EncodedString()
                let spawned = try spawnManagedGuard(path: path, context: encoded, recovery: restoreOnly)
                let pid = spawned.pid
                self.children.insert(HelperChildren.Child(path: path, directory: files.identity, configuration: config, pid: pid), restoreOnly: restoreOnly)
                if !restoreOnly { reply(pid, nil) }
                DispatchQueue.global().async {
                    if let output = spawned.output {
                        let result = HelperRecoveryCompletion.wait(pid: pid, output: output)
                        self.queue.async {
                            self.children.remove(pid: pid, restoreOnly: true)
                            switch result {
                            case .success: reply(pid, nil)
                            case .failure(let error): reply(0, error.localizedDescription)
                            }
                        }
                    } else {
                        var status: Int32 = 0
                        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                        self.queue.async { self.children.remove(pid: pid, restoreOnly: false) }
                    }
                }
            } catch { reply(0, error.localizedDescription) }
        }
    }

    static func run() throws -> Never {
        guard geteuid() == 0, let manifest = try HelperTrust.manifest(),
              manifest.protocolVersion == HelperConstants.protocolVersion,
              try HelperTrust.signingHash() == manifest.helperHash else {
            throw WakecupError(message: "The system helper identity is invalid.")
        }
        let service = HelperService(manifest: manifest)
        let listener = NSXPCListener(machServiceName: HelperConstants.label)
        let gui = try HelperPolicy.requirement(identifier: HelperConstants.clientIdentifier, hash: manifest.clientHash)
        let installer = try HelperPolicy.requirement(identifier: HelperConstants.label, hash: manifest.helperHash)
        listener.setConnectionCodeSigningRequirement("(" + gui + ") or (" + installer + ")")
        listener.delegate = service
        listener.resume()
        withExtendedLifetime((service, listener)) { RunLoop.current.run() }
        exit(0)
    }
}

private final class HelperPeer: NSObject, WakecupHelperProtocol {
    let service: HelperService
    weak var connection: NSXPCConnection?
    let peer: ProcessIdentity
    init(service: HelperService, connection: NSXPCConnection, peer: ProcessIdentity) {
        self.service = service; self.connection = connection; self.peer = peer
    }
    func information(version: Int, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let connection else { reply(nil, "The Wakecup connection ended."); return }
        service.information(version: version, callerUID: connection.effectiveUserIdentifier, reply: reply)
    }
    func startSession(version: Int, path: String, restoreOnly: Bool, withReply reply: @escaping (Int32, String?) -> Void) {
        guard let connection else { reply(0, "The Wakecup connection ended."); return }
        service.start(version: version, path: path, restoreOnly: restoreOnly, connection: connection, peer: peer, reply: reply)
    }
}

private func spawnManagedGuard(path: String, context: String, recovery: Bool) throws -> (pid: Int32, output: Int32?) {
    var descriptors: [Int32] = [-1, -1]
    var launched = false
    if recovery {
        guard pipe(&descriptors) == 0 else { throw WakecupError(message: "Could not prepare the recovery result.") }
    }
    defer {
        if descriptors[1] >= 0 { close(descriptors[1]) }
        if !launched, descriptors[0] >= 0 { close(descriptors[0]) }
    }
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw WakecupError(message: "Could not prepare the helper guard.") }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw WakecupError(message: "Could not prepare helper descriptors.") }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw WakecupError(message: "Could not isolate the helper guard.") }
    for fd: Int32 in 0...2 {
        let result = recovery && fd != 0
            ? posix_spawn_file_actions_adddup2(&actions, descriptors[1], fd)
            : posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        guard result == 0 else { throw WakecupError(message: "Could not isolate helper descriptors.") }
    }
    if recovery {
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            throw WakecupError(message: "Could not isolate recovery result descriptors.")
        }
    }
    let argumentStrings: [String] = [HelperConstants.executable, "--managed-guard", path, context]
    let strings = argumentStrings.map { strdup($0) }
    let environmentStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    let environment = environmentStrings.map { strdup($0) }
    defer { for string in strings + environment { free(string) } }
    var argv = strings + [nil], env = environment + [nil], pid: pid_t = 0
    let result = posix_spawn(&pid, HelperConstants.executable, &actions, &attributes, &argv, &env)
    guard result == 0 else { throw WakecupError(message: "Could not launch the helper guard (\(result)).") }
    launched = true
    return (pid, recovery ? descriptors[0] : nil)
}
