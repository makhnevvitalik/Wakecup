import Combine
import Foundation

protocol UpdateRequestTask: AnyObject {
    func resume()
    func cancel()
}
extension URLSessionDataTask: UpdateRequestTask {}

enum UpdateCheckFailure: Equatable {
    case network, invalidResponse, invalidRelease, currentVersion, rateLimited
    case http(Int)
}

enum UpdateCheckResult: Equatable {
    case upToDate
    case updateAvailable(tag: String, url: URL)
    case notPublished
    case failure(UpdateCheckFailure)
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking
        case finished(UpdateCheckResult)
    }
    typealias Completion = @Sendable (Data?, URLResponse?, Error?) -> Void
    typealias Transport = (URLRequest, @escaping Completion) -> UpdateRequestTask

    nonisolated static let repositoryURL = URL(string: "https://github.com/makhnevvitalik/Wakecup")!
    nonisolated static let latestReleaseURL = URL(string: "https://github.com/makhnevvitalik/Wakecup/releases/latest")!
    nonisolated static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/makhnevvitalik/Wakecup/releases/latest")!

    @Published private(set) var state = State.idle
    private let currentVersion: () -> String?
    private let transport: Transport
    private var task: UpdateRequestTask?
    private var requestID: UUID?

    init(currentVersion: @escaping () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }, transport: @escaping Transport = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion)
    }) {
        self.currentVersion = currentVersion
        self.transport = transport
    }

    func check() {
        guard state != .checking else { return }
        let id = UUID()
        requestID = id
        state = .checking
        let version = currentVersion()
        var request = URLRequest(url: Self.latestReleaseAPIURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wakecup", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        task = transport(request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                self.state = .finished(Self.evaluate(data: data, response: response,
                                                     error: error, currentVersion: version))
            }
        }
        task?.resume()
    }

    deinit { task?.cancel() }

    nonisolated static func evaluate(data: Data?, response: URLResponse?, error: Error?,
                                     currentVersion: String?) -> UpdateCheckResult {
        if error != nil { return .failure(.network) }
        guard let response = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
        if response.statusCode == 404 { return .notPublished }
        if response.statusCode == 429 ||
            (response.statusCode == 403 &&
             (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
              response.value(forHTTPHeaderField: "Retry-After") != nil)) {
            return .failure(.rateLimited)
        }
        guard (200...299).contains(response.statusCode) else { return .failure(.http(response.statusCode)) }
        guard let data, data.count <= 1_048_576,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.prerelease != true, release.draft != true,
              let latest = AppVersion(release.tagName) else { return .failure(.invalidRelease) }
        guard let currentVersion, let current = AppVersion(currentVersion) else { return .failure(.currentVersion) }
        guard latest > current else { return .upToDate }
        let url = release.htmlURL.flatMap(trustedReleaseURL) ?? latestReleaseURL
        return .updateAvailable(tag: release.tagName, url: url)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        let prerelease: Bool?
        let draft: Bool?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", prerelease, draft
        }
    }

    nonisolated private static func trustedReleaseURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/makhnevvitalik/Wakecup/releases/tag/"),
              !parts.path.dropFirst("/makhnevvitalik/Wakecup/releases/tag/".count).isEmpty,
              !parts.path.split(separator: "/").contains("..") else { return nil }
        return url
    }
}
