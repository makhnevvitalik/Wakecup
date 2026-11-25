import Foundation

enum StagedHelper {
    static func isPath(_ path: String) -> Bool {
        let prefix = "/Library/PrivilegedHelperTools/.wakecup-stage-"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        return suffix.utf8.count == 8 && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    static func readExecutable() throws -> Data? {
        guard let path = try recoveryProcess(getpid())?.executable, isPath(path) else { return nil }
        return try HelperTrust.read(path, maximum: HelperConstants.maximumExecutableBytes, executable: true)
    }
}
