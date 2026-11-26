import Foundation

enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidURL
    case insecurePublicHTTP
    case invalidRemotePath
    case missingCredentials
    case unauthorized
    case remoteNotFound
    case preconditionFailed
    case crossHostRedirect
    case payloadTooLarge
    case notEncryptedBackup
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "WebDAV 服务器地址无效，请输入完整 URL（如 https://dav.jianguoyun.com/dav/）。")
        case .insecurePublicHTTP:
            return String(localized: "出于安全考虑，公网 WebDAV 地址仅支持 HTTPS；局域网 NAS / 本机可使用 HTTP。")
        case .invalidRemotePath:
            return String(localized: "云端同步文件路径无效，不能包含 .. 或特殊查询字符。")
        case .missingCredentials:
            return String(localized: "请完整填写 WebDAV 账号与密码。")
        case .unauthorized:
            return String(localized: "WebDAV 身份验证失败，请核对账号或应用专用密码。")
        case .remoteNotFound:
            return String(localized: "云端尚未找到该同步文件，请先上传一份加密备份。")
        case .preconditionFailed:
            return String(localized: "云端备份在本次上传前已被其他设备更新，需要先合并云端最新版本。")
        case .crossHostRedirect:
            return String(localized: "服务器返回了跳转重定向，出于凭据安全已拦截。")
        case .payloadTooLarge:
            return String(localized: "备份文件超过安全体积上限，无法同步。")
        case .notEncryptedBackup:
            return String(localized: "云端文件不是有效的夜奔加密备份格式。")
        case .httpError(let code):
            return String(localized: "WebDAV 请求失败（HTTP \(code)）。")
        }
    }
}

struct WebDAVResolvedTarget: Equatable {
    let serverURL: URL
    let targetURL: URL
    let parentDirectories: [URL]
}

struct WebDAVRemoteMetadata: Equatable, Sendable {
    let exists: Bool
    let etag: String?
    let lastModified: Date?
    let contentLength: Int64?

    static let missing = WebDAVRemoteMetadata(exists: false, etag: nil, lastModified: nil, contentLength: nil)
}

private final class WebDAVRedirectGuardDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static func isSameOriginRedirect(from source: URL?, to next: URL?) -> Bool {
        guard let source,
              let next,
              source.scheme?.lowercased() == next.scheme?.lowercased(),
              source.host?.lowercased() == next.host?.lowercased(),
              effectivePort(of: source) == effectivePort(of: next) else {
            return false
        }
        return true
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if Self.isSameOriginRedirect(from: response.url, to: request.url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

private final class WebDAVBoundedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var httpResponse: HTTPURLResponse?
    private var data = Data()
    private var terminalError: Error?

    init(maxBytes: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        self.maxBytes = maxBytes
        self.continuation = continuation
    }

    func failWithCancellationIfPending() {
        let pending = lock.withLock { () -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
            guard let cont = continuation else { return nil }
            continuation = nil
            data.removeAll(keepingCapacity: false)
            return cont
        }
        pending?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if WebDAVRedirectGuardDelegate.isSameOriginRedirect(from: response.url, to: request.url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { terminalError = WebDAVSyncError.httpError(0) }
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 404 {
            lock.withLock { terminalError = WebDAVSyncError.remoteNotFound }
            completionHandler(.cancel)
            return
        }
        do {
            try WebDAVSyncService.validateStatusCode(http.statusCode, allow207: false)
        } catch {
            lock.withLock { terminalError = error }
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(maxBytes) {
            lock.withLock { terminalError = WebDAVSyncError.payloadTooLarge }
            completionHandler(.cancel)
            return
        }
        lock.withLock {
            httpResponse = http
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), 2 * 1024 * 1024))
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard terminalError == nil else { return true }
            if data.count + chunk.count > maxBytes {
                terminalError = WebDAVSyncError.payloadTooLarge
                data.removeAll(keepingCapacity: false)
                return true
            }
            data.append(chunk)
            return false
        }
        if exceeded {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: (CheckedContinuation<(Data, HTTPURLResponse), Error>?, Result<(Data, HTTPURLResponse), Error>) = lock.withLock {
            guard let cont = continuation else { return (nil, .failure(CancellationError())) }
            continuation = nil
            if let terminalError {
                return (cont, .failure(terminalError))
            }
            if let error {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    return (cont, .failure(CancellationError()))
                }
                return (cont, .failure(error))
            }
            guard let httpResponse else {
                return (cont, .failure(WebDAVSyncError.httpError(0)))
            }
            let payload = data
            data.removeAll(keepingCapacity: false)
            return (cont, .success((payload, httpResponse)))
        }
        guard let cont = outcome.0 else { return }
        switch outcome.1 {
        case .success(let value): cont.resume(returning: value)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}

private final class WebDAVCancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var delegate: WebDAVBoundedDownloadDelegate?
    private var cancelled = false

    func bind(task: URLSessionDataTask, delegate: WebDAVBoundedDownloadDelegate) -> Bool {
        lock.withLock {
            self.task = task
            self.delegate = delegate
            return cancelled
        }
    }

    func cancel() {
        let pair = lock.withLock { () -> (URLSessionDataTask?, WebDAVBoundedDownloadDelegate?) in
            cancelled = true
            return (task, delegate)
        }
        pair.0?.cancel()
        pair.1?.failWithCancellationIfPending()
    }
}

enum WebDAVSyncService {
    static let webDAVPasswordAccount = "webdav/password"
    static let webDAVPassphraseAccount = "webdav/sync-passphrase"

    private static let redirectGuard = WebDAVRedirectGuardDelegate()
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }()

    static func validatedServerURL(_ rawServerURL: String) throws -> URL {
        let trimmed = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw WebDAVSyncError.invalidURL
        }
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: trimmed) {
            throw WebDAVSyncError.insecurePublicHTTP
        }
        let normalizedString = trimmed.hasSuffix("/") ? trimmed : "\(trimmed)/"
        guard let url = URL(string: normalizedString) else {
            throw WebDAVSyncError.invalidURL
        }
        return url
    }

    static func resolvedTarget(serverURL rawServerURL: String, remotePath rawPath: String) throws -> WebDAVResolvedTarget {
        let serverURL = try validatedServerURL(rawServerURL)
        let cleanPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty,
              !cleanPath.contains("?"),
              !cleanPath.contains("#"),
              !cleanPath.contains("\\") else {
            throw WebDAVSyncError.invalidRemotePath
        }

        let segments = cleanPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !segments.isEmpty else {
            throw WebDAVSyncError.invalidRemotePath
        }
        for segment in segments {
            if segment == "." || segment == ".." || segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WebDAVSyncError.invalidRemotePath
            }
        }

        var parentDirs: [URL] = []
        var cursor = serverURL
        for idx in 0..<(segments.count - 1) {
            cursor = cursor.appendingPathComponent(segments[idx], isDirectory: true)
            parentDirs.append(cursor)
        }
        let targetURL = cursor.appendingPathComponent(segments[segments.count - 1], isDirectory: false)
        return WebDAVResolvedTarget(serverURL: serverURL, targetURL: targetURL, parentDirectories: parentDirs)
    }

    static func basicAuthHeader(username: String, password: String) -> String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    static func testConnection(
        serverURL rawServerURL: String,
        username: String,
        password: String,
        session: URLSession? = nil
    ) async throws {
        let serverURL = try validatedServerURL(rawServerURL)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }

        var request = URLRequest(url: serverURL)
        request.httpMethod = "OPTIONS"
        request.setValue(basicAuthHeader(username: cleanUser, password: password), forHTTPHeaderField: "Authorization")

        let (_, response) = try await (session ?? defaultSession).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVSyncError.httpError(0)
        }
        try validateStatusCode(http.statusCode, allow207: true)
    }

    static func parseHTTPDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "EEE MMM  d HH:mm:ss yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    static func metadata(from http: HTTPURLResponse, exists: Bool = true) -> WebDAVRemoteMetadata {
        let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastMod = http.value(forHTTPHeaderField: "Last-Modified").flatMap(parseHTTPDate)
        let length = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return WebDAVRemoteMetadata(
            exists: exists,
            etag: (etag?.isEmpty == false) ? etag : nil,
            lastModified: lastMod,
            contentLength: length
        )
    }

    static func fetchRemoteMetadata(
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        let resolved = try resolvedTarget(serverURL: rawServerURL, remotePath: remotePath)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }

        var head = URLRequest(url: resolved.targetURL)
        head.httpMethod = "HEAD"
        head.setValue(basicAuthHeader(username: cleanUser, password: password), forHTTPHeaderField: "Authorization")

        let (_, response) = try await (session ?? defaultSession).data(for: head)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVSyncError.httpError(0)
        }
        if http.statusCode == 404 {
            return .missing
        }
        try validateStatusCode(http.statusCode, allow207: false)
        return metadata(from: http, exists: true)
    }

    @discardableResult
    static func uploadEncryptedData(
        _ data: Data,
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        ifMatchETag: String? = nil,
        ifNoneMatchStar: Bool = false,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        try await uploadRawData(
            data,
            contentType: "application/json; charset=utf-8",
            serverURL: rawServerURL,
            remotePath: remotePath,
            username: username,
            password: password,
            ifMatchETag: ifMatchETag,
            ifNoneMatchStar: ifNoneMatchStar,
            session: session
        )
    }

    @discardableResult
    static func uploadEncryptedFile(
        _ fileURL: URL,
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        ifMatchETag: String? = nil,
        ifNoneMatchStar: Bool = false,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        try await uploadRawFile(
            fileURL,
            contentType: "application/json; charset=utf-8",
            serverURL: rawServerURL,
            remotePath: remotePath,
            username: username,
            password: password,
            ifMatchETag: ifMatchETag,
            ifNoneMatchStar: ifNoneMatchStar,
            session: session
        )
    }

    @discardableResult
    static func uploadRawData(
        _ data: Data,
        contentType: String,
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        ifMatchETag: String? = nil,
        ifNoneMatchStar: Bool = false,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        guard data.count <= BackupService.maximumFileBytes else {
            throw WebDAVSyncError.payloadTooLarge
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-upload-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        return try await uploadRawFile(
            tempURL,
            contentType: contentType,
            serverURL: rawServerURL,
            remotePath: remotePath,
            username: username,
            password: password,
            ifMatchETag: ifMatchETag,
            ifNoneMatchStar: ifNoneMatchStar,
            session: session
        )
    }

    @discardableResult
    static func uploadRawFile(
        _ fileURL: URL,
        contentType: String,
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        ifMatchETag: String? = nil,
        ifNoneMatchStar: Bool = false,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize else {
            throw WebDAVSyncError.httpError(0)
        }
        guard fileSize <= BackupService.maximumFileBytes else {
            throw WebDAVSyncError.payloadTooLarge
        }
        let resolved = try resolvedTarget(serverURL: rawServerURL, remotePath: remotePath)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }

        let auth = basicAuthHeader(username: cleanUser, password: password)
        let activeSession = session ?? defaultSession

        for dirURL in resolved.parentDirectories {
            var mkcol = URLRequest(url: dirURL)
            mkcol.httpMethod = "MKCOL"
            mkcol.setValue(auth, forHTTPHeaderField: "Authorization")
            let (_, mkcolResp) = try await activeSession.data(for: mkcol)
            if let http = mkcolResp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw WebDAVSyncError.unauthorized
                }
                if (300...399).contains(http.statusCode) {
                    throw WebDAVSyncError.crossHostRedirect
                }
            }
        }

        var put = URLRequest(url: resolved.targetURL)
        put.httpMethod = "PUT"
        put.setValue(auth, forHTTPHeaderField: "Authorization")
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        if let etag = ifMatchETag?.trimmingCharacters(in: .whitespacesAndNewlines), !etag.isEmpty {
            put.setValue(etag, forHTTPHeaderField: "If-Match")
        } else if ifNoneMatchStar {
            put.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        let (_, response) = try await activeSession.upload(for: put, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVSyncError.httpError(0)
        }
        if http.statusCode == 412 {
            throw WebDAVSyncError.preconditionFailed
        }
        try validateStatusCode(http.statusCode, allow207: false)
        return metadata(from: http, exists: true)
    }

    static func downloadRawData(
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        maxBytes: Int = BackupService.maximumFileBytes,
        session: URLSession? = nil
    ) async throws -> (Data, WebDAVRemoteMetadata) {
        let resolved = try resolvedTarget(serverURL: rawServerURL, remotePath: remotePath)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }

        var get = URLRequest(url: resolved.targetURL)
        get.httpMethod = "GET"
        get.setValue(basicAuthHeader(username: cleanUser, password: password), forHTTPHeaderField: "Authorization")

        let activeSession = session ?? defaultSession
        let taskBox = WebDAVCancellableTaskBox()
        let (data, http): (Data, HTTPURLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = WebDAVBoundedDownloadDelegate(
                    maxBytes: maxBytes,
                    continuation: continuation
                )
                let task = activeSession.dataTask(with: get)
                task.delegate = delegate
                if taskBox.bind(task: task, delegate: delegate) {
                    task.cancel()
                    delegate.failWithCancellationIfPending()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
        return (data, metadata(from: http, exists: true))
    }

    static func downloadEncryptedData(
        serverURL rawServerURL: String,
        remotePath: String,
        username: String,
        password: String,
        session: URLSession? = nil
    ) async throws -> Data {
        let (data, _) = try await downloadRawData(
            serverURL: rawServerURL,
            remotePath: remotePath,
            username: username,
            password: password,
            session: session
        )
        guard EncryptedBackupService.isEncryptedBackup(data) else {
            throw WebDAVSyncError.notEncryptedBackup
        }
        return data
    }

    fileprivate static func validateStatusCode(_ code: Int, allow207: Bool) throws {
        if code == 401 || code == 403 {
            throw WebDAVSyncError.unauthorized
        }
        if (300...399).contains(code) {
            throw WebDAVSyncError.crossHostRedirect
        }
        if (200...299).contains(code) || (allow207 && code == 207) {
            return
        }
        throw WebDAVSyncError.httpError(code)
    }
}
