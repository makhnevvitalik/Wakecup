import Foundation

// At most one normal guard and one recovery for the same immutable session.
// A hung normal guard cannot block the recovery coordinator that replaces it.
struct HelperChildren {
    struct Child {
        let path: String
        let directory: SessionDirectoryIdentity
        let configuration: SessionConfiguration
        let pid: Int32
    }
    private var children: [Bool: Child] = [:]

    func existing(path: String, directory: SessionDirectoryIdentity, configuration: SessionConfiguration,
                  restoreOnly: Bool) throws -> Int32? {
        func matches(_ child: Child) -> Bool {
            child.path == path && child.directory == directory && child.configuration == configuration
        }
        if let current = children[restoreOnly] {
            guard matches(current) else { throw WakecupError(message: "The helper is already processing another session.") }
            return current.pid
        }
        if let other = children[!restoreOnly], !restoreOnly || !matches(other) {
            throw WakecupError(message: "The helper is already processing another session.")
        }
        return nil
    }
    mutating func insert(_ child: Child, restoreOnly: Bool) { children[restoreOnly] = child }
    mutating func remove(pid: Int32, restoreOnly: Bool) {
        if children[restoreOnly]?.pid == pid { children[restoreOnly] = nil }
    }
}
