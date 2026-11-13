import Foundation

@objc(WakecupHelperProtocol) protocol WakecupHelperProtocol {
    func information(version: Int, withReply reply: @escaping (Data?, String?) -> Void)
    // A normal start acknowledges launch. A restore-only reply reports the
    // completed child result; a PID alone never acknowledges pending recovery.
    func startSession(version: Int, path: String, restoreOnly: Bool, withReply reply: @escaping (Int32, String?) -> Void)
}

enum HelperConstants {
    static let label = "local.wakecup.helper"
    static let clientIdentifier = "local.wakecup"
    static let protocolVersion = 4
    static let maximumExecutableBytes = 8 * 1024 * 1024
    static let executable = "/Library/PrivilegedHelperTools/" + label
    static let manifest = executable + ".json"
    static let plist = "/Library/LaunchDaemons/" + label + ".plist"
}

struct HelperManifest: Codable, Equatable {
    let protocolVersion: Int
    let ownerUID: UInt32
    let clientHash: String
    let helperHash: String
    let helperSHA256: String
}

struct HelperInformation: Codable {
    let manifest: HelperManifest
    let clientConfirmed: Bool
}

enum HelperPolicy {
    static func validHash(_ value: String, length: Int = 40) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validate(path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
            throw WakecupError(message: "Invalid helper session path.")
        }
    }
    static func validate(configuration: SessionConfiguration, peer: ProcessIdentity, restoreOnly: Bool) throws {
        _ = try SessionMonitor(configuration: configuration, now: 0)
        guard configuration.closedLid, restoreOnly || (configuration.parentPID == peer.pid && configuration.parentIdentity == peer) else {
            throw WakecupError(message: "The session does not belong to the requesting Wakecup process.")
        }
    }
    static func requirement(identifier: String, hash: String) throws -> String {
        guard validHash(hash), [HelperConstants.label, HelperConstants.clientIdentifier].contains(identifier) else {
            throw WakecupError(message: "Invalid helper signing identity.")
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(hash)\""
    }
}
