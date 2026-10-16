import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct NutstoreRemoteSnapshot: Sendable {
    let deviceID: UUID
    let data: Data
    let eTag: String?
}

protocol NutstoreWebDAVTransport: Sendable {
    func testConnection(credentials: NutstoreCredentials) async throws
    func fetchSnapshots(credentials: NutstoreCredentials) async throws -> [NutstoreRemoteSnapshot]
    func uploadSnapshot(_ data: Data, credentials: NutstoreCredentials) async throws
}

enum NutstoreWebDAVError: LocalizedError {
    case invalidCredentials
    case authenticationFailed
    case permissionDenied
    case rateLimited(Date)
    case storageFull
    case fileTooLarge
    case directoryTooLarge
    case invalidDirectoryListing
    case invalidRemoteFile
    case redirectBlocked
    case unexpectedStatus(Int)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "请填写坚果云账户邮箱和第三方应用密码。"
        case .authenticationFailed:
            return "坚果云账户验证未通过（401）。请确认账户邮箱、应用密码及第三方应用访问权限后重试。"
        case .permissionDenied:
            return "坚果云拒绝访问（403）。请检查第三方应用的 WebDAV 访问权限。"
        case let .rateLimited(date):
            return "坚果云请求过于频繁（429），请在 \(date.formatted(date: .omitted, time: .shortened)) 后重试。"
        case .storageFull:
            return "坚果云空间或流量不足（507）。请检查账户配额后重试。"
        case .fileTooLarge:
            return "同步文件超过 20 MB，已暂停同步。此设备的记录仍保留在本地。"
        case .directoryTooLarge:
            return "同步目录达到坚果云单次列举上限，无法确认目录是否完整，已暂停同步以保护记录。"
        case .invalidDirectoryListing:
            return "坚果云返回的同步目录不完整或格式异常，已暂停本次同步。"
        case .invalidRemoteFile:
            return "坚果云同步文件读取失败，已暂停本次同步。"
        case .redirectBlocked:
            return "坚果云返回了地址重定向。为保护应用密码，已停止连接，请稍后重试。"
        case let .unexpectedStatus(status):
            return "坚果云请求未完成（HTTP \(status)），请稍后重试。"
        case .networkUnavailable:
            return "无法连接坚果云。记录仍保存在本机，网络恢复后可再次同步。"
        }
    }
}

/// A small HTTP seam lets tests supply WebDAV responses without real credentials
/// or network access. The production client never accepts a custom server URL.
protocol NutstoreHTTPClient: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse)
}

struct NutstoreURLSessionHTTPClient: NutstoreHTTPClient {
    #if TIMELINE_AUTH_TESTING
    private let testingProtocolClasses: [AnyClass]
    init(testingProtocolClasses: [AnyClass] = []) { self.testingProtocolClasses = testingProtocolClasses }
    #endif

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "dav.jianguoyun.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else {
            throw NutstoreWebDAVError.redirectBlocked
        }
        let credential = try Self.authenticationCredential(from: request)
        // Authorization is reserved by URLSession. Pass credentials through its
        // authentication challenge instead of relying on a manually supplied header.
        var outboundRequest = request
        outboundRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        #if TIMELINE_AUTH_TESTING
        // Offline tests must explicitly install a protocol fixture. This seam
        // does not exist in application builds and cannot redirect production URLs.
        precondition(!testingProtocolClasses.isEmpty, "Offline authentication tests require a URLProtocol fixture")
        configuration.protocolClasses = testingProtocolClasses
        #endif
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = NutstoreDownloadGuard(maximumBytes: maximumResponseBytes, credential: credential)
        do {
            let (temporaryURL, response) = try await session.download(for: outboundRequest, delegate: delegate)
            guard !delegate.exceededLimit else { throw NutstoreWebDAVError.fileTooLarge }
            guard let response = response as? HTTPURLResponse else { throw NutstoreWebDAVError.networkUnavailable }
            let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumResponseBytes else { throw NutstoreWebDAVError.fileTooLarge }
            let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            guard data.count <= maximumResponseBytes else { throw NutstoreWebDAVError.fileTooLarge }
            return (data, response)
        } catch {
            if delegate.exceededLimit { throw NutstoreWebDAVError.fileTooLarge }
            if Task.isCancelled { throw CancellationError() }
            if delegate.authenticationRejected { throw NutstoreWebDAVError.authenticationFailed }
            if let known = error as? NutstoreWebDAVError { throw known }
            // Do not surface request descriptions, Authorization headers, or
            // server response bodies through errors or logs.
            throw NutstoreWebDAVError.networkUnavailable
        }
    }

    private static func authenticationCredential(from request: URLRequest) throws -> URLCredential {
        guard let header = request.value(forHTTPHeaderField: "Authorization"),
              header.hasPrefix("Basic "), let encoded = Data(base64Encoded: String(header.dropFirst(6))),
              let decoded = String(data: encoded, encoding: .utf8), let separator = decoded.firstIndex(of: ":") else {
            throw NutstoreWebDAVError.invalidCredentials
        }
        let username = String(decoded[..<separator])
        let password = String(decoded[decoded.index(after: separator)...])
        guard NutstoreCredentials(username: username, password: password).isValid else {
            throw NutstoreWebDAVError.invalidCredentials
        }
        return URLCredential(user: username, password: password, persistence: .none)
    }
}

final class NutstoreDownloadGuard: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let credential: URLCredential
    private let lock = NSLock()
    private var limitExceeded = false
    private var rejectedAuthentication = false
    private var offeredCredential = false
    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitExceeded
    }
    var authenticationRejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedAuthentication
    }

    init(maximumBytes: Int, credential: URLCredential) {
        self.maximumBytes = maximumBytes
        self.credential = credential
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        // Keep platform certificate validation intact; never accept trust objects
        // ourselves. Other non-password challenges also retain system handling.
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
            return (.performDefaultHandling, nil)
        }
        guard !space.isProxy(), space.protocol?.lowercased() == "https",
              space.host.lowercased() == "dav.jianguoyun.com", space.port == 443 else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return authenticationAnswer(previousFailureCount: challenge.previousFailureCount)
    }

    private func authenticationAnswer(previousFailureCount: Int) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        lock.lock()
        defer { lock.unlock() }
        guard previousFailureCount == 0, !offeredCredential else {
            rejectedAuthentication = true
            return (.cancelAuthenticationChallenge, nil)
        }
        offeredCredential = true
        return (.useCredential, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Refuse every redirect, including same-host redirects. Credentials are
        // only ever attached to URLs constructed within the fixed sync directory.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.lock()
            limitExceeded = true
            lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

actor NutstoreWebDAVClient: NutstoreWebDAVTransport {
    static let serverURL = URL(string: "https://dav.jianguoyun.com/dav/")!
    static let directoryURL = serverURL.appendingPathComponent("TimelineSync-v1", isDirectory: true)
    static let maximumSnapshotBytes = 20 * 1_024 * 1_024

    private let deviceID: UUID
    private let http: any NutstoreHTTPClient
    private let minimumRequestInterval: TimeInterval
    private var nextRequestAt = Date.distantPast
    private var cooldownUntil = Date.distantPast

    init(deviceID: UUID, http: any NutstoreHTTPClient = NutstoreURLSessionHTTPClient(),
         minimumRequestInterval: TimeInterval = 3.1) {
        self.deviceID = deviceID
        self.http = http
        self.minimumRequestInterval = max(0, minimumRequestInterval)
    }

    func testConnection(credentials: NutstoreCredentials) async throws {
        try await ensureDirectory(credentials: credentials)
        _ = try await listSnapshots(credentials: credentials)
    }

    func fetchSnapshots(credentials: NutstoreCredentials) async throws -> [NutstoreRemoteSnapshot] {
        try await ensureDirectory(credentials: credentials)
        let files = try await listSnapshots(credentials: credentials)
        var snapshots: [NutstoreRemoteSnapshot] = []
        for file in files.sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            let (data, response) = try await request(method: "GET", filename: file.name, credentials: credentials)
            guard response.statusCode == 200 else { throw NutstoreWebDAVError.invalidRemoteFile }
            snapshots.append(NutstoreRemoteSnapshot(deviceID: file.deviceID, data: data,
                                                    eTag: response.value(forHTTPHeaderField: "ETag") ?? file.eTag))
        }
        return snapshots
    }

    func uploadSnapshot(_ data: Data, credentials: NutstoreCredentials) async throws {
        guard data.count <= Self.maximumSnapshotBytes else { throw NutstoreWebDAVError.fileTooLarge }
        // Only the local device's file can be written. There is intentionally no
        // remote delete method and no API for writing another device's snapshot.
        let (_, response) = try await request(method: "PUT", filename: deviceID.uuidString + ".json",
                                              body: data, credentials: credentials)
        guard [200, 201, 204].contains(response.statusCode) else {
            throw NutstoreWebDAVError.unexpectedStatus(response.statusCode)
        }
    }

    private func ensureDirectory(credentials: NutstoreCredentials) async throws {
        let (_, response) = try await request(method: "MKCOL", credentials: credentials)
        guard response.statusCode == 201 || response.statusCode == 405 else {
            throw NutstoreWebDAVError.unexpectedStatus(response.statusCode)
        }
    }

    private struct RemoteFile {
        let deviceID: UUID
        let name: String
        let eTag: String?
    }

    private func listSnapshots(credentials: NutstoreCredentials) async throws -> [RemoteFile] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await request(method: "PROPFIND", body: body, credentials: credentials)
        guard response.statusCode == 207 else { throw NutstoreWebDAVError.unexpectedStatus(response.statusCode) }
        let listing = NutstoreDirectoryParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = listing
        guard parser.parse(), listing.validMultistatus, !listing.invalid else {
            throw NutstoreWebDAVError.invalidDirectoryListing
        }
        // Nutstore caps a response at 750 files/folders. Count every response,
        // including the collection itself and files this app does not recognize.
        guard listing.responses.count < 750 else { throw NutstoreWebDAVError.directoryTooLarge }
        let directoryPath = Self.directoryURL.path.hasSuffix("/") ? Self.directoryURL.path : Self.directoryURL.path + "/"
        var files: [RemoteFile] = []
        var seen = Set<UUID>()
        var sawDirectory = false
        for entry in listing.responses {
            guard let url = URL(string: entry.href, relativeTo: Self.directoryURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == Self.serverURL.host,
                  url.port == nil || url.port == 443, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else {
                throw NutstoreWebDAVError.invalidDirectoryListing
            }
            let path = url.path
            if path == Self.directoryURL.path || path == directoryPath || path + "/" == directoryPath {
                guard entry.isCollection else { throw NutstoreWebDAVError.invalidDirectoryListing }
                sawDirectory = true
                continue
            }
            guard path.hasPrefix(directoryPath) else { throw NutstoreWebDAVError.invalidDirectoryListing }
            let name = String(path.dropFirst(directoryPath.count))
            // Depth 1 must contain direct children only. We never follow URLs
            // supplied by the server: GETs are rebuilt from the validated name.
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
                throw NutstoreWebDAVError.invalidDirectoryListing
            }
            guard !entry.isCollection, name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))),
                  name.dropLast(5).count == 36 else { continue }
            guard seen.insert(id).inserted else { throw NutstoreWebDAVError.invalidDirectoryListing }
            if let length = entry.contentLength, length > Self.maximumSnapshotBytes {
                throw NutstoreWebDAVError.fileTooLarge
            }
            files.append(RemoteFile(deviceID: id, name: name, eTag: entry.eTag))
        }
        guard sawDirectory else { throw NutstoreWebDAVError.invalidDirectoryListing }
        return files
    }

    private func request(method: String, filename: String? = nil, body: Data? = nil,
                         credentials: NutstoreCredentials) async throws -> (Data, HTTPURLResponse) {
        guard credentials.isValid else { throw NutstoreWebDAVError.invalidCredentials }
        try Task.checkCancellation()
        if cooldownUntil > Date() { throw NutstoreWebDAVError.rateLimited(cooldownUntil) }
        // Reserve the next slot before suspension, so actor reentrancy cannot
        // let simultaneous callers skip the account-friendly request spacing.
        let slot = max(Date(), nextRequestAt)
        nextRequestAt = slot.addingTimeInterval(minimumRequestInterval)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        if cooldownUntil > Date() { throw NutstoreWebDAVError.rateLimited(cooldownUntil) }
        let url = filename.map { Self.directoryURL.appendingPathComponent($0, isDirectory: false) } ?? Self.directoryURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Basic " + Data((credentials.username + ":" + credentials.password).utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("Timeline/1.0", forHTTPHeaderField: "User-Agent")
        if method == "PROPFIND" {
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else if method == "PUT" {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.send(request, maximumResponseBytes: Self.maximumSnapshotBytes)
        guard data.count <= Self.maximumSnapshotBytes else { throw NutstoreWebDAVError.fileTooLarge }
        switch response.statusCode {
        case 401: throw NutstoreWebDAVError.authenticationFailed
        case 403: throw NutstoreWebDAVError.permissionDenied
        case 429:
            cooldownUntil = retryDate(response.value(forHTTPHeaderField: "Retry-After"))
            throw NutstoreWebDAVError.rateLimited(cooldownUntil)
        case 507: throw NutstoreWebDAVError.storageFull
        case 300..<400: throw NutstoreWebDAVError.redirectBlocked
        default: return (data, response)
        }
    }

    private func retryDate(_ value: String?) -> Date {
        if let value, let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return Date().addingTimeInterval(max(60, min(seconds, 86_400)))
        }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(date, Date().addingTimeInterval(60)) }
        }
        return Date().addingTimeInterval(30 * 60)
    }
}

private final class NutstoreDirectoryParser: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var isCollection = false
        var eTag: String?
        var contentLength: Int?
    }

    var responses: [Response] = []
    var validMultistatus = false
    var invalid = false
    private var elements: [String] = []
    private var texts: [String] = []
    private var current: Response?
    private var properties = Response()
    private var propertyStatus = ""
    private var sawValidProperties = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard namespaceURI == "DAV:" else { invalid = true; parser.abortParsing(); return }
        if elements.isEmpty { validMultistatus = elementName == "multistatus" }
        elements.append(elementName)
        texts.append("")
        if elementName == "response" {
            guard current == nil, elements.count == 2 else { invalid = true; parser.abortParsing(); return }
            current = Response()
            sawValidProperties = false
        } else if elementName == "propstat", current != nil {
            properties = Response()
            propertyStatus = ""
        } else if elementName == "collection", elements.suffix(3) == ["prop", "resourcetype", "collection"] {
            properties.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !texts.isEmpty else { return }
        texts[texts.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let text = texts.popLast(), elements.last == elementName else { invalid = true; return }
        let parent = elements.dropLast().last
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "href", parent == "response" { current?.href = value }
        if elementName == "status", parent == "propstat" { propertyStatus = value }
        if elementName == "status", parent == "response", !value.contains(" 200 ") {
            invalid = true
        }
        if elementName == "getetag", parent == "prop" { properties.eTag = value.isEmpty ? nil : value }
        if elementName == "getcontentlength", parent == "prop", !value.isEmpty {
            guard let length = Int(value), length >= 0 else { invalid = true; return }
            properties.contentLength = length
        }
        if elementName == "propstat", propertyStatus.contains(" 200 ") {
            let collection = properties.isCollection || (current?.isCollection ?? false)
            current?.isCollection = collection
            if let etag = properties.eTag { current?.eTag = etag }
            if let length = properties.contentLength { current?.contentLength = length }
            sawValidProperties = true
        }
        if elementName == "response" {
            guard let current, !current.href.isEmpty, sawValidProperties else {
                invalid = true
                return
            }
            responses.append(current)
            self.current = nil
        }
        elements.removeLast()
    }
}
