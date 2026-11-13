import Foundation

// Captured by the authenticated service, checked once by its child, then used
// unchanged. Configuration is never reopened after this check.
struct ManagedGuardContext: Codable {
    let ownerUID: UInt32
    let directory: SessionDirectoryIdentity
    let configuration: SessionConfiguration
    let peer: ProcessIdentity
    let restoreOnly: Bool

    func validate(files: SessionFiles) throws {
        guard files.owner == ownerUID, files.identity == directory,
              try files.read("configuration.json", as: SessionConfiguration.self) == configuration else {
            throw WakecupError(message: "The helper session changed before it could start.")
        }
        try HelperPolicy.validate(configuration: configuration, peer: peer, restoreOnly: restoreOnly)
    }
    static func decode(_ value: String) throws -> Self {
        guard value.utf8.count <= 16_384, let data = Data(base64Encoded: value) else {
            throw WakecupError(message: "Invalid managed guard context.")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
