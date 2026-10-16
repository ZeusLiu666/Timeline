import Foundation

// Standalone offline test. From this project folder:
// swiftc Timeline/NutstoreCredentials.swift Timeline/NutstoreWebDAV.swift \
//   Tests/NutstoreWebDAVTests.swift -o /tmp/timeline-webdav-tests
// /tmp/timeline-webdav-tests
// No real network, Keychain calls, or user credentials are used.

private struct Reply: Sendable {
    var status: Int
    var data: Data = Data()
    var headers: [String: String] = [:]
}

private actor FakeHTTP: NutstoreHTTPClient {
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        precondition(request.url?.scheme == "https")
        precondition(request.url?.host == "dav.jianguoyun.com")
        precondition(request.url?.path.hasPrefix("/dav/TimelineSync-v1") == true)
        precondition(maximumResponseBytes == 20 * 1024 * 1024)
        requests.append(request)
        precondition(!replies.isEmpty)
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                            httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

@main private struct NutstoreWebDAVTests {
    static let own = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let other = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let credentials = NutstoreCredentials(username: "test@example.invalid", password: "not-a-real-secret")
    static let directory = "/dav/TimelineSync-v1/"

    static func response(_ href: String, collection: Bool = false, length: String? = nil, etag: String? = nil) -> String {
        """
        <d:response><d:href>\(href)</d:href><d:propstat><d:prop>
        <d:resourcetype>\(collection ? "<d:collection/>" : "")</d:resourcetype>
        \(length.map { "<d:getcontentlength>\($0)</d:getcontentlength>" } ?? "")
        \(etag.map { "<d:getetag>\($0)</d:getetag>" } ?? "")
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """
    }
    static func listing(_ content: String) -> Data {
        Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(content)</d:multistatus>".utf8)
    }
    static func client(_ replies: [Reply]) -> (NutstoreWebDAVClient, FakeHTTP) {
        let fake = FakeHTTP(replies)
        return (NutstoreWebDAVClient(deviceID: own, http: fake, minimumRequestInterval: 0), fake)
    }
    static func expect(_ expected: String, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected \(expected)") }
        catch let error as NutstoreWebDAVError {
            let actual = String(describing: error)
            precondition(actual.hasPrefix(expected), "Expected \(expected), got \(actual)")
        } catch { fatalError("Unexpected error type") }
    }

    static func main() async throws {
        let content = Data("{\"test\":1}".utf8)
        let dir = response(directory, collection: true)
        let remote = response(directory + other.uuidString + ".json", length: "10", etag: "&quot;listed&quot;")
        let (reader, readHTTP) = client([
            Reply(status: 405), Reply(status: 207, data: listing(dir + remote + response(directory + "unrelated.txt"))),
            Reply(status: 200, data: content, headers: ["ETag": "\"actual\""])
        ])
        let snapshots = try await reader.fetchSnapshots(credentials: credentials)
        precondition(snapshots.count == 1 && snapshots[0].deviceID == other)
        precondition(snapshots[0].data == content && snapshots[0].eTag == "\"actual\"")
        let readRequests = await readHTTP.requests
        precondition(readRequests.map(\.httpMethod) == ["MKCOL", "PROPFIND", "GET"])
        precondition(readRequests[1].value(forHTTPHeaderField: "Depth") == "1")
        precondition(readRequests[2].url?.lastPathComponent == other.uuidString + ".json")
        precondition(readRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true })

        let (writer, writeHTTP) = client([Reply(status: 201)])
        try await writer.uploadSnapshot(content, credentials: credentials)
        let writeRequests = await writeHTTP.requests
        precondition(writeRequests.count == 1)
        precondition(writeRequests[0].httpMethod == "PUT")
        precondition(writeRequests[0].url?.lastPathComponent == own.uuidString + ".json")
        precondition(writeRequests[0].httpBody == content)

        let (tester, _) = client([Reply(status: 201), Reply(status: 207, data: listing(dir))])
        try await tester.testConnection(credentials: credentials)

        for (status, expected) in [(401, "authenticationFailed"), (403, "permissionDenied"),
                                   (507, "storageFull"), (302, "redirectBlocked")] {
            let (client, _) = client([Reply(status: status)])
            await expect(expected) { try await client.testConnection(credentials: credentials) }
        }
        let (limited, limitedHTTP) = client([Reply(status: 429, headers: ["Retry-After": "120"])])
        await expect("rateLimited") { try await limited.testConnection(credentials: credentials) }
        await expect("rateLimited") { try await limited.testConnection(credentials: credentials) }
        let limitedRequests = await limitedHTTP.requests
        precondition(limitedRequests.count == 1)

        let (largeWrite, noHTTP) = client([])
        await expect("fileTooLarge") {
            try await largeWrite.uploadSnapshot(Data(count: 20 * 1024 * 1024 + 1), credentials: credentials)
        }
        let noRequests = await noHTTP.requests
        precondition(noRequests.isEmpty)
        let (largeHeader, _) = client([Reply(status: 405), Reply(status: 207,
            data: listing(dir + response(directory + other.uuidString + ".json", length: "20971521")))])
        await expect("fileTooLarge") { _ = try await largeHeader.fetchSnapshots(credentials: credentials) }

        for bad in [Data("<d:multistatus xmlns:d=\"DAV:\">".utf8), listing(remote),
                    listing(dir + response("https://evil.invalid/dav/TimelineSync-v1/\(other).json")),
                    listing(dir + response(directory + "../elsewhere/\(other).json")),
                    listing(dir + remote + remote)] {
            let (invalid, _) = client([Reply(status: 405), Reply(status: 207, data: bad)])
            await expect("invalidDirectoryListing") { _ = try await invalid.fetchSnapshots(credentials: credentials) }
        }

        let many = dir + (1...749).map { response(directory + "ignored-\($0).txt") }.joined()
        let (truncated, _) = client([Reply(status: 405), Reply(status: 207, data: listing(many))])
        await expect("directoryTooLarge") { _ = try await truncated.fetchSnapshots(credentials: credentials) }
        let invalidCredentials = NutstoreCredentials(username: "invalid", password: "placeholder")
        let (invalid, invalidHTTP) = client([])
        await expect("invalidCredentials") { try await invalid.testConnection(credentials: invalidCredentials) }
        let invalidRequests = await invalidHTTP.requests
        precondition(invalidRequests.isEmpty)
        print("PASS: WebDAV scope, own-device writes, XML, ETag, limits, HTTP errors, cooldown; no live network or Keychain used")
    }
}
