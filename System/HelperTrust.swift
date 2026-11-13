import Foundation
import Security
import CryptoKit
import Darwin

enum HelperTrust {
    static func signingHash(of url: URL? = nil) throws -> String {
        var code: SecStaticCode?
        if let url {
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else {
                throw WakecupError(message: "Could not verify helper signature.")
            }
        } else {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &code) == errSecSuccess,
                  SecCodeCheckValidity(running, [], nil) == errSecSuccess else {
                throw WakecupError(message: "Could not verify the running Wakecup signature.")
            }
        }
        guard let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw WakecupError(message: "The helper signature is invalid.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber, flags.uint32Value & 0x10000 != 0 else {
            throw WakecupError(message: "Hardened Runtime is required for the Wakecup helper.")
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
                    "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory"] {
            guard entitlements[key] as? Bool != true else { throw WakecupError(message: "Unsafe helper signing entitlements.") }
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func validateParents(of path: String) throws {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        while current.path != "/" {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                throw WakecupError(message: "Unsafe system helper directory: " + current.path)
            }
            try rejectAllowACL(path: current.path)
            current.deleteLastPathComponent()
        }
    }

    static func read(_ path: String, maximum: Int = 16_384, executable: Bool = false) throws -> Data? {
        try validateParents(of: path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw WakecupError(message: "Could not open the installed helper.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0,
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= maximum,
              !executable || info.st_mode & 0o111 == 0o111 else {
            throw WakecupError(message: "Unsafe installed helper permissions.")
        }
        try rejectAllowACL(descriptor: fd)
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw WakecupError(message: "Installed helper file is too large.") }
        return data
    }

    // Conservative policy for this small system installation: deny ACLs are
    // preserved; any allow ACE (including inherited grants) is refused.
    static func rejectAllowACL(path: String? = nil, descriptor: Int32? = nil) throws {
        let acl = descriptor.map { acl_get_fd_np($0, ACL_TYPE_EXTENDED) }
            ?? path.map { acl_get_file($0, ACL_TYPE_EXTENDED) } ?? nil
        guard let acl else {
            // Darwin also uses ENOENT for an absent extended ACL. Distinguish
            // that from a missing target using the already retained descriptor.
            if errno == ENOATTR || errno == ENOENT {
                var info = stat()
                if let descriptor, fstat(descriptor, &info) == 0 { return }
                if let path, lstat(path, &info) == 0 { return }
            }
            throw WakecupError(message: "Could not verify system helper access permissions (" + String(errno) + ").")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY
        while acl_get_entry(acl, selector.rawValue, &entry) == 0 {
            guard let entry else { throw WakecupError(message: "Invalid system helper access permissions.") }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw WakecupError(message: "The system helper location has additional access grants. Installation was refused.")
            }
            selector = ACL_NEXT_ENTRY
        }
    }

    static func clearACL(descriptor: Int32) throws {
        guard let acl = acl_init(0) else { throw WakecupError(message: "Could not prepare private helper permissions.") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else {
            throw WakecupError(message: "Could not clear inherited helper access permissions.")
        }
    }

    static func manifest() throws -> HelperManifest? {
        // A missing installation is normal; do not require its parent to exist.
        var info = stat()
        if lstat("/Library/PrivilegedHelperTools", &info) != 0, errno == ENOENT { return nil }
        guard let data = try read(HelperConstants.manifest) else { return nil }
        let value = try JSONDecoder().decode(HelperManifest.self, from: data)
        guard value.ownerUID > 0, HelperPolicy.validHash(value.clientHash), HelperPolicy.validHash(value.helperHash),
              HelperPolicy.validHash(value.helperSHA256, length: 64) else { throw WakecupError(message: "Invalid installed helper identity.") }
        return value
    }
}
