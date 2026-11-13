import Foundation

// Only an authenticated, well-formed start reply can create this error. It
// rejects one operation without revoking the daemon's confirmed availability.
struct HelperOperationRejection: LocalizedError {
    let message: String
    fileprivate init(message: String) { self.message = message }
    var errorDescription: String? { message }
}

// One request per connection; timeout/invalidation/reply race through a single
// completion gate. A lost reply is never replayed, since the guard may be live.
final class HelperClient {
    private let hash: String
    init(hash: String) { self.hash = hash }

    func information(completion: @escaping (Result<HelperManifest, Error>) -> Void) {
        status { result in completion(result.map { $0.manifest }) }
    }
    func status(completion: @escaping (Result<HelperInformation, Error>) -> Void) {
        request(completion: completion) { proxy, finish in
            proxy.information(version: HelperConstants.protocolVersion) { data, error in
                do {
                    if let error { throw WakecupError(message: error) }
                    guard let data, data.count <= 16_384 else { throw WakecupError(message: "Invalid helper response.") }
                    finish(.success(try JSONDecoder().decode(HelperInformation.self, from: data)))
                } catch { finish(.failure(error)) }
            }
        }
    }
    func start(path: String, restoreOnly: Bool, completion: @escaping (Result<Int32, Error>) -> Void) {
        request(timeout: restoreOnly ? 45 : 10, completion: completion) { proxy, finish in
            proxy.startSession(version: HelperConstants.protocolVersion, path: path, restoreOnly: restoreOnly) { pid, error in
                finish(Self.startResult(pid: pid, error: error))
            }
        }
    }
    static func startResult(pid: Int32, error: String?) -> Result<Int32, Error> {
        if let error {
            guard pid == 0, !error.isEmpty, error.utf8.count <= 16_384 else {
                return .failure(WakecupError(message: "Invalid helper guard response."))
            }
            return .failure(HelperOperationRejection(message: error))
        }
        if pid > 1 { return .success(pid) }
        return .failure(WakecupError(message: "Invalid helper guard response."))
    }
    private func request<T>(timeout: TimeInterval = 10, completion: @escaping (Result<T, Error>) -> Void,
                            send: @escaping (WakecupHelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) {
        let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
        let lock = NSLock()
        var completed = false
        let finish: (Result<T, Error>) -> Void = { result in
            lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock()
            connection.invalidationHandler = nil; connection.interruptionHandler = nil
            connection.invalidate()
            DispatchQueue.main.async { completion(result) }
        }
        do { connection.setCodeSigningRequirement(try HelperPolicy.requirement(identifier: HelperConstants.label, hash: hash)) }
        catch { finish(.failure(error)); return }
        connection.remoteObjectInterface = NSXPCInterface(with: WakecupHelperProtocol.self)
        connection.invalidationHandler = { finish(.failure(WakecupError(message: "The helper connection ended. Check the session status before trying again."))) }
        connection.interruptionHandler = { finish(.failure(WakecupError(message: "The helper connection was interrupted. Check the session status before trying again."))) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? WakecupHelperProtocol else {
            finish(.failure(WakecupError(message: "Could not connect to the Wakecup helper."))); return
        }
        send(proxy, finish)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(WakecupError(message: "The helper did not reply. Check the session status before trying again.")))
        }
    }
}
