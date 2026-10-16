import Foundation

// Standalone offline authentication checks. Only synthetic credentials are used.
// URLProtocol intercepts the fixed Nutstore URL before any real network request.
// swiftc -D TIMELINE_AUTH_TESTING -warnings-as-errors Timeline/NutstoreCredentials.swift Timeline/NutstoreWebDAV.swift \
//   Tests/NutstoreAuthenticationTests.swift -o /tmp/timeline-auth-tests

#if !TIMELINE_AUTH_TESTING
#error("Compile with -D TIMELINE_AUTH_TESTING to prevent real network access")
#endif

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class AuthenticationProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case accepts, rejects }
    private static let stateLock = NSLock()
    private static var mode: Mode = .accepts
    private static var intercepted = 0
    private static var manualAuthorization = false

    static func reset(_ newMode: Mode) {
        stateLock.lock()
        defer { stateLock.unlock() }
        mode = newMode
        intercepted = 0
        manualAuthorization = false
    }

    static func observations() -> (Int, Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (intercepted, manualAuthorization)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Claim every HTTP request so no test request can leave the process.
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        Self.intercepted += 1
        Self.manualAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        let currentMode = Self.mode
        Self.stateLock.unlock()
        precondition(request.url?.host == "dav.jianguoyun.com")
        let data = Data("offline-response".utf8)
        let status = currentMode == .accepts ? 200 : 401
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main private struct NutstoreAuthenticationTests {
    static let credential = URLCredential(user: "offline@example.invalid", password: "synthetic:not-a-real-secret", persistence: .none)

    static func challenge(host: String = "dav.jianguoyun.com", port: Int = 443,
                          scheme: String = "https", method: String = NSURLAuthenticationMethodHTTPBasic,
                          failures: Int = 0) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(host: host, port: port, protocol: scheme, realm: "offline-fixture", authenticationMethod: method),
            proposedCredential: nil, previousFailureCount: failures, failureResponse: nil,
            error: nil, sender: ChallengeSender())
    }

    static func request(url: String = "https://dav.jianguoyun.com/dav/TimelineSync-v1/") -> URLRequest {
        var result = URLRequest(url: URL(string: url)!)
        result.httpMethod = "PROPFIND"
        // This header is only an in-memory handoff to the HTTPClient seam; the
        // actual URLSession request must have it removed before being submitted.
        result.setValue("Basic " + Data("offline@example.invalid:synthetic:not-a-real-secret".utf8).base64EncodedString(),
                        forHTTPHeaderField: "Authorization")
        return result
    }

    static func main() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://dav.jianguoyun.com/dav/TimelineSync-v1/")!)

        let delegate = NutstoreDownloadGuard(maximumBytes: 1024, credential: credential)
        let first = await delegate.urlSession(session, task: task, didReceive: challenge())
        precondition(first.0 == .useCredential && first.1?.user == credential.user)
        precondition(first.1?.persistence == URLCredential.Persistence.none)
        let failed = await delegate.urlSession(session, task: task, didReceive: challenge(failures: 1))
        precondition(failed.0 == .cancelAuthenticationChallenge && failed.1 == nil)
        precondition(delegate.authenticationRejected)

        let repeated = NutstoreDownloadGuard(maximumBytes: 1024, credential: credential)
        _ = await repeated.urlSession(session, task: task, didReceive: challenge())
        let repeatAnswer = await repeated.urlSession(session, task: task, didReceive: challenge())
        precondition(repeatAnswer.0 == .cancelAuthenticationChallenge && repeatAnswer.1 == nil)

        for untrusted in [challenge(host: "evil.invalid"), challenge(port: 444), challenge(scheme: "http")] {
            let guardDelegate = NutstoreDownloadGuard(maximumBytes: 1024, credential: credential)
            let answer = await guardDelegate.urlSession(session, task: task, didReceive: untrusted)
            precondition(answer.0 == .cancelAuthenticationChallenge && answer.1 == nil)
        }
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPDigest] {
            let guardDelegate = NutstoreDownloadGuard(maximumBytes: 1024, credential: credential)
            let answer = await guardDelegate.urlSession(session, task: task, didReceive: challenge(method: method))
            precondition(answer.0 == .performDefaultHandling && answer.1 == nil)
        }

        let http = NutstoreURLSessionHTTPClient(testingProtocolClasses: [AuthenticationProtocol.self])
        AuthenticationProtocol.reset(.accepts)
        let (data, response) = try await http.send(request(), maximumResponseBytes: 1024)
        precondition(response.statusCode == 200 && String(data: data, encoding: .utf8) == "offline-response")
        let accepted = AuthenticationProtocol.observations()
        precondition(accepted.0 == 1 && !accepted.1)

        AuthenticationProtocol.reset(.rejects)
        let (_, unauthorized) = try await http.send(request(), maximumResponseBytes: 1024)
        precondition(unauthorized.statusCode == 401)
        let rejected = AuthenticationProtocol.observations()
        precondition(rejected.0 == 1 && !rejected.1)

        AuthenticationProtocol.reset(.accepts)
        do {
            _ = try await http.send(request(url: "https://evil.invalid/dav/TimelineSync-v1/"), maximumResponseBytes: 1024)
            fatalError("Untrusted host must be blocked before sending")
        } catch NutstoreWebDAVError.redirectBlocked {}
        precondition(AuthenticationProtocol.observations().0 == 0)
        print("PASS: offline URLSession response handling and header removal; direct delegate first/repeated challenge, fixed host and TLS default policies. Real CFNetwork authentication handshake requires live verification.")
    }
}
