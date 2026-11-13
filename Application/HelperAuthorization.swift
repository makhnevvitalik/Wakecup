import Foundation

// Factories shared by password-per-use and installation. UI never supplies an
// executable to elevate; it supplies an immutable session context to the pinned helper.
enum HelperAuthorization {
    static func guardTask(files: SessionFiles, restoreOnly: Bool = false) throws -> Process {
        guard let peer = processIdentity(getpid()) else {
            throw WakecupError(message: "Could not verify the running Wakecup signature.")
        }
        let configuration = try files.read("configuration.json", as: SessionConfiguration.self)
        try HelperPolicy.validate(configuration: configuration, peer: peer, restoreOnly: restoreOnly)
        let context = ManagedGuardContext(ownerUID: getuid(), directory: files.identity,
            configuration: configuration, peer: peer, restoreOnly: restoreOnly)
        let encoded = try JSONEncoder().encode(context).base64EncodedString()
        return try task(arguments: ["--authorized-guard", files.url.path, encoded], detached: !restoreOnly)
    }

    static func installationTask(remove: Bool) throws -> Process {
        let ownHash = try HelperTrust.signingHash()
        return try task(arguments: [remove ? "--uninstall" : "--install", String(getuid()), ownHash], detached: false)
    }

    private static func task(arguments: [String], detached: Bool) throws -> Process {
        guard Bundle.main.bundleIdentifier == HelperConstants.clientIdentifier,
              let source = Bundle.main.url(forResource: HelperConstants.label, withExtension: nil, subdirectory: "Helper") else {
            throw WakecupError(message: "The bundled helper is missing or damaged. Reinstall Wakecup.")
        }
        // A preflight improves the error; only the protected post-copy comparison
        // is the security boundary, because the bundle may change during approval.
        guard try PrivilegedExecution.sourceDigest(at: source) == HelperBuildIdentity.sha256 else {
            throw WakecupError(message: "The bundled helper is missing or damaged. Reinstall Wakecup.")
        }
        let script = try PrivilegedExecution.stagingScript(source: source, sha256: HelperBuildIdentity.sha256,
            arguments: arguments, detached: detached)
        return PrivilegedExecution.authorizationTask(script: script)
    }
}
