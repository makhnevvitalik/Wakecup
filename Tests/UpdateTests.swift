import Foundation

private final class FakeRequest: UpdateRequestTask {
    var resumed = false
    var cancelled = false
    func resume() { resumed = true }
    func cancel() { cancelled = true }
}

@main
struct UpdateTests {
    @MainActor static func main() {
        var count = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures.append(name) }
        }
        expect(AppVersion("1.2") == AppVersion("v1.2.0"), "equivalent padded versions compare equal")
        expect(AppVersion("1.10")! > AppVersion("1.9.9")!, "numeric comparison")
        expect(AppVersion(" V2.0 \n") == AppVersion("2"), "optional prefix and outer whitespace")
        for value in ["", "v", ".1", "1.", "1..0", "-1", "+1", "1.-2", "1.0-beta", "1.2.3.4", "1.a", "１.0", "999999999999999999999999"] {
            expect(AppVersion(value) == nil, "reject malformed version: \(value)")
        }
        func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: UpdateChecker.latestReleaseAPIURL, statusCode: status,
                            httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        func payload(_ tag: String, url: String = "https://github.com/makhnevvitalik/Wakecup/releases/tag/v1.0.0",
                     prerelease: Bool = false, draft: Bool = false) -> Data {
            try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url,
                                                        "prerelease": prerelease, "draft": draft])
        }
        func evaluate(_ data: Data? = nil, status: Int = 200, current: String? = "0.2.7") -> UpdateCheckResult {
            UpdateChecker.evaluate(data: data, response: response(status), error: nil, currentVersion: current)
        }
        let releaseURL = URL(string: "https://github.com/makhnevvitalik/Wakecup/releases/tag/v1.0.0")!
        expect(evaluate(payload("v1.0.0")) == .updateAvailable(tag: "v1.0.0", url: releaseURL), "new release")
        expect(evaluate(payload("0.2.7")) == .upToDate, "same release")
        expect(evaluate(payload("0.1")) == .upToDate, "older release")
        expect(evaluate(status: 404) == .notPublished, "404 is not up-to-date")
        expect(evaluate(status: 429) == .failure(.rateLimited), "429 rate limit")
        expect(UpdateChecker.evaluate(data: nil, response: response(403, headers: ["X-RateLimit-Remaining": "0"]),
                                      error: nil, currentVersion: "1") == .failure(.rateLimited), "403 exhausted quota")
        expect(UpdateChecker.evaluate(data: nil, response: response(403, headers: ["Retry-After": "60"]),
                                      error: nil, currentVersion: "1") == .failure(.rateLimited), "403 secondary rate limit")
        expect(evaluate(status: 403) == .failure(.http(403)), "403 not automatically rate limit")
        expect(evaluate(status: 500) == .failure(.http(500)), "server error")
        expect(evaluate(status: 204) == .failure(.invalidRelease), "empty success")
        expect(evaluate(Data("{}".utf8)) == .failure(.invalidRelease), "missing tag")
        expect(evaluate(Data("not json".utf8)) == .failure(.invalidRelease), "malformed JSON")
        expect(evaluate(Data(repeating: 32, count: 1_048_577)) == .failure(.invalidRelease), "oversized response rejected")
        expect(evaluate(Data("{\"tag_name\":123}".utf8)) == .failure(.invalidRelease), "wrong tag type rejected")
        expect(evaluate(payload("nonsense")) == .failure(.invalidRelease), "invalid release version")
        expect(evaluate(payload("1"), current: nil) == .failure(.currentVersion), "missing installed version")
        expect(evaluate(payload("1"), current: "bad") == .failure(.currentVersion), "invalid installed version")
        expect(evaluate(payload("1", prerelease: true)) == .failure(.invalidRelease), "unexpected prerelease")
        expect(evaluate(payload("1", draft: true)) == .failure(.invalidRelease), "unexpected draft")
        expect(UpdateChecker.evaluate(data: nil, response: nil, error: URLError(.notConnectedToInternet), currentVersion: "1")
               == .failure(.network), "network failure")
        expect(UpdateChecker.evaluate(data: nil, response: nil, error: nil, currentVersion: "1")
               == .failure(.invalidResponse), "missing HTTP response")
        for url in ["http://github.com/makhnevvitalik/Wakecup/releases/tag/v1", "https://evil.example/release", "https://github.com/other/Wakecup/releases/tag/v1", "https://github.com/makhnevvitalik/Wakecup-evil/releases/tag/v1", "https://github.com@evil.example/makhnevvitalik/Wakecup/releases/tag/v1", "https://github.com/makhnevvitalik/Wakecup/releases/tag/v1?next=evil", "file:///tmp/test"] {
            expect(evaluate(payload("1", url: url)) == .updateAvailable(tag: "1", url: UpdateChecker.latestReleaseURL),
                   "untrusted release URL falls back to expected repository: \(url)")
        }
        var requests: [FakeRequest] = []
        var completions: [UpdateChecker.Completion] = []
        var captured: URLRequest?
        let checker = UpdateChecker(currentVersion: { "0.2.7" }) { request, completion in
            captured = request
            let task = FakeRequest()
            requests.append(task)
            completions.append(completion)
            return task
        }
        checker.check()
        expect(checker.state == .checking && requests.count == 1 && requests[0].resumed, "starts a request")
        expect(captured?.url == UpdateChecker.latestReleaseAPIURL && captured?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "expected endpoint and JSON accept header")
        checker.check()
        expect(requests.count == 1, "no overlapping requests")
        completions[0](payload("1", url: "https://example.org/release"), response(200), nil)
        drainMainQueue()
        expect(checker.state == .finished(.updateAvailable(tag: "1", url: UpdateChecker.latestReleaseURL)),
               "first request finishes")
        checker.check()
        completions[0](nil, response(404), nil)
        drainMainQueue()
        expect(checker.state == .checking, "old callback cannot replace new request")
        completions[1](payload("0.2.7"), response(200), nil)
        drainMainQueue()
        expect(checker.state == .finished(.upToDate), "current callback updates state")
        completions[1](nil, response(404), nil)
        drainMainQueue()
        expect(checker.state == .finished(.upToDate), "duplicate completed callback ignored")
        checker.check()
        expect(requests.count == 3, "check again after completion")
        let cancelled = FakeRequest()
        var disposable: UpdateChecker? = UpdateChecker(transport: { _, _ in cancelled })
        disposable?.check()
        disposable = nil
        expect(cancelled.cancelled, "an in-flight request is cancelled when the checker is released")
        print("Update checks: \(count), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor private static func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}
