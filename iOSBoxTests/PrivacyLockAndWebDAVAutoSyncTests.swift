import LocalAuthentication
import Security
import SwiftData
import UIKit
import XCTest
@testable import iOSBox

private final class MockWebDAVURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class PrivacyLockAndWebDAVAutoSyncTests: XCTestCase {

    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!
    private var isolatedPreferences: AppPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "PrivacyLockAndWebDAVAutoSyncTests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: suiteName)!
        isolatedPreferences = AppPreferences(defaults: isolatedDefaults)
        MockWebDAVURLProtocol.handler = nil
    }

    override func tearDown() {
        MockWebDAVURLProtocol.handler = nil
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        isolatedPreferences = nil
        isolatedDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAppLockShouldLockRespectsGracePeriodPolicy() {
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        XCTAssertFalse(AppLockController.shouldLock(lockEnabled: false, backgroundedAt: nil, now: now, graceSeconds: 0))
        XCTAssertTrue(AppLockController.shouldLock(lockEnabled: true, backgroundedAt: nil, now: now, graceSeconds: 300))

        XCTAssertTrue(AppLockController.shouldLock(
            lockEnabled: true,
            backgroundedAt: now,
            now: now,
            graceSeconds: 0
        ))
        XCTAssertFalse(AppLockController.shouldLock(
            lockEnabled: true,
            backgroundedAt: now.addingTimeInterval(-120),
            now: now,
            graceSeconds: 300
        ))
        XCTAssertTrue(AppLockController.shouldLock(
            lockEnabled: true,
            backgroundedAt: now.addingTimeInterval(-300),
            now: now,
            graceSeconds: 300
        ))
    }

    func testAppLockControllerLifecycleAndAuthentication() async {
        let controller = AppLockController()
        let start = Date(timeIntervalSince1970: 1_700_010_000)

        // Default off: launch & background do not lock or blur.
        controller.handleLaunch(preferences: isolatedPreferences)
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible)

        // Background blur only without lock.
        isolatedPreferences.privacyBlurOnBackground = true
        controller.handleScenePhaseChange(.inactive, preferences: isolatedPreferences, now: start, autoAuthenticate: false)
        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(controller.isPrivacyShieldVisible)
        controller.handleScenePhaseChange(.active, preferences: isolatedPreferences, now: start, autoAuthenticate: false)
        XCTAssertFalse(controller.isPrivacyShieldVisible)

        // Enabling lock requires verification.
        let denied = await controller.setLockEnabled(true, preferences: isolatedPreferences) { _ in false }
        XCTAssertFalse(denied)
        XCTAssertFalse(isolatedPreferences.appLockEnabled)

        let approved = await controller.setLockEnabled(true, preferences: isolatedPreferences) { _ in true }
        XCTAssertTrue(approved)
        XCTAssertTrue(isolatedPreferences.appLockEnabled)

        // With 5 minute grace, returning after 60s stays unlocked; after 301s locks.
        isolatedPreferences.appLockGracePeriod = .fiveMinutes
        controller.handleScenePhaseChange(.background, preferences: isolatedPreferences, now: start, autoAuthenticate: false)
        XCTAssertTrue(controller.isPrivacyShieldVisible)
        controller.handleScenePhaseChange(.active, preferences: isolatedPreferences, now: start.addingTimeInterval(60), autoAuthenticate: false)
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible)

        controller.handleScenePhaseChange(.background, preferences: isolatedPreferences, now: start, autoAuthenticate: false)
        controller.handleScenePhaseChange(.active, preferences: isolatedPreferences, now: start.addingTimeInterval(301), autoAuthenticate: false)
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(controller.isPrivacyShieldVisible)

        // Cancelling auth surfaces friendly error without clearing lock.
        let cancelled = await controller.authenticate { _ in throw LAError(.userCancel) }
        XCTAssertFalse(cancelled)
        XCTAssertTrue(controller.isLocked)
        XCTAssertNotNil(controller.lastError)

        // Successful auth clears lock and shield.
        let unlocked = await controller.authenticate { _ in true }
        XCTAssertTrue(unlocked)
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(controller.isPrivacyShieldVisible)
        XCTAssertNil(controller.lastError)

        let disabled = await controller.setLockEnabled(false, preferences: isolatedPreferences) { _ in true }
        XCTAssertTrue(disabled)
        XCTAssertFalse(isolatedPreferences.appLockEnabled)
    }

    func testPreferencesPersistSecurityAndWebDAVAutoSyncFields() {
        isolatedPreferences.appLockEnabled = true
        isolatedPreferences.appLockGracePeriod = .fifteenMinutes
        isolatedPreferences.privacyBlurOnBackground = true
        isolatedPreferences.webDAVAutoSyncEnabled = true
        isolatedPreferences.webDAVAutoSyncIntervalMinutes = 42 // invalid -> falls back to 15
        XCTAssertEqual(isolatedPreferences.webDAVAutoSyncIntervalMinutes, 15)
        isolatedPreferences.webDAVAutoSyncIntervalMinutes = 30
        isolatedPreferences.webDAVLastRemoteETag = "\"abc-123\""
        let modified = Date(timeIntervalSince1970: 1_700_020_000)
        isolatedPreferences.webDAVLastRemoteModifiedAt = modified
        isolatedPreferences.webDAVLastAutoSyncSummary = "同步成功"
        isolatedPreferences.webDAVWorkspaceChangeID = "second-edit"

        let reloaded = AppPreferences(defaults: isolatedDefaults)
        XCTAssertTrue(reloaded.appLockEnabled)
        XCTAssertEqual(reloaded.appLockGracePeriod, .fifteenMinutes)
        XCTAssertTrue(reloaded.privacyBlurOnBackground)
        XCTAssertTrue(reloaded.webDAVAutoSyncEnabled)
        XCTAssertEqual(reloaded.webDAVAutoSyncIntervalMinutes, 30)
        XCTAssertEqual(reloaded.webDAVLastRemoteETag, "\"abc-123\"")
        XCTAssertEqual(try XCTUnwrap(reloaded.webDAVLastRemoteModifiedAt).timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.1)
        XCTAssertEqual(reloaded.webDAVLastAutoSyncSummary, "同步成功")
        let coordinator = WebDAVAutoSyncCoordinator()
        coordinator.recordSyncedRemoteMetadata(.missing, uploadedWorkspaceChangeID: "first-edit", preferences: reloaded)
        XCTAssertEqual(reloaded.webDAVWorkspaceChangeID, "second-edit")
        coordinator.recordSyncedRemoteMetadata(.missing, uploadedWorkspaceChangeID: "second-edit", preferences: reloaded)
        XCTAssertEqual(reloaded.webDAVWorkspaceChangeID, "")
    }

    func testWebDAVHTTPDateParsingAndAutoSyncDecisionPolicy() throws {
        let imf = try XCTUnwrap(WebDAVSyncService.parseHTTPDate("Wed, 21 Oct 2026 07:28:00 GMT"))
        let later = try XCTUnwrap(WebDAVSyncService.parseHTTPDate("Wed, 21 Oct 2026 07:35:00 GMT"))
        XCTAssertGreaterThan(later.timeIntervalSince(imf), 400)
        XCTAssertNotNil(WebDAVSyncService.parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT"))
        XCTAssertNotNil(WebDAVSyncService.parseHTTPDate("Sun Nov  6 08:49:37 2026"))
        XCTAssertNil(WebDAVSyncService.parseHTTPDate("invalid-date"))

        let now = Date(timeIntervalSince1970: 1_700_050_000)
        let remoteV2 = WebDAVRemoteMetadata(exists: true, etag: "\"v2\"", lastModified: later, contentLength: 2048)

        // Cooldown skips foreground/background unless manualSmart.
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .foreground,
                remote: remoteV2,
                knownETag: "\"v1\"",
                knownModifiedAt: imf,
                localDirty: false,
                lastSyncAt: now.addingTimeInterval(-60),
                cooldownSeconds: 900,
                now: now
            ),
            .skipCooldown
        )
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .manualSmart,
                remote: remoteV2,
                knownETag: "\"v1\"",
                knownModifiedAt: imf,
                localDirty: false,
                lastSyncAt: now.addingTimeInterval(-60),
                cooldownSeconds: 900,
                now: now
            ),
            .pullThenMerge
        )

        // Remote + local dirty triggers merge before push so neither device overwrites data.
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .foreground,
                remote: remoteV2,
                knownETag: "\"v1\"",
                knownModifiedAt: imf,
                localDirty: true,
                lastSyncAt: now.addingTimeInterval(-1000),
                cooldownSeconds: 900,
                now: now
            ),
            .pullMergeThenPush
        )

        // Remote unchanged + local dirty -> pushOnly; clean -> upToDate.
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .background,
                remote: remoteV2,
                knownETag: "\"v2\"",
                knownModifiedAt: later,
                localDirty: true,
                lastSyncAt: nil,
                cooldownSeconds: 900,
                now: now
            ),
            .pushOnly
        )
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .foreground,
                remote: remoteV2,
                knownETag: "\"v2\"",
                knownModifiedAt: later,
                localDirty: false,
                lastSyncAt: nil,
                cooldownSeconds: 900,
                now: now
            ),
            .upToDate
        )

        // Remote missing + local dirty -> pushOnly.
        XCTAssertEqual(
            WebDAVAutoSyncPolicy.decide(
                trigger: .foreground,
                remote: .missing,
                knownETag: "",
                knownModifiedAt: nil,
                localDirty: true,
                lastSyncAt: nil,
                cooldownSeconds: 900,
                now: now
            ),
            .pushOnly
        )
    }

    func testWebDAVFetchRemoteMetadataAndUploadResponseHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWebDAVURLProtocol.self]
        let session = URLSession(configuration: config)

        MockWebDAVURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "HEAD")
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "ETag": "\"etag-42\"",
                    "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT",
                    "Content-Length": "4096"
                ]
            )!
            return (response, Data())
        }

        let meta = try await WebDAVSyncService.fetchRemoteMetadata(
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "secret",
            session: session
        )
        XCTAssertTrue(meta.exists)
        XCTAssertEqual(meta.etag, "\"etag-42\"")
        XCTAssertEqual(meta.contentLength, 4096)
        XCTAssertNotNil(meta.lastModified)

        MockWebDAVURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let missing = try await WebDAVSyncService.fetchRemoteMetadata(
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/missing.enc.json",
            username: "alice",
            password: "secret",
            session: session
        )
        XCTAssertFalse(missing.exists)

        MockWebDAVURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        do {
            _ = try await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: "https://dav.example.com/dav/",
                remotePath: "Fugue/fugue-sync.enc.json",
                username: "alice",
                password: "wrong",
                session: session
            )
            XCTFail("Expected unauthorized")
        } catch let err as WebDAVSyncError {
            XCTAssertEqual(err, .unauthorized)
        }

        MockWebDAVURLProtocol.handler = { req in
            let code = req.httpMethod == "PUT" ? 201 : 200
            let headers = req.httpMethod == "PUT" ? ["ETag": "\"etag-put-99\""] : nil
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, Data())
        }
        let putMeta = try await WebDAVSyncService.uploadEncryptedData(
            Data("{\"magic\":\"test\"}".utf8),
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "secret",
            session: session
        )
        XCTAssertTrue(putMeta.exists)
        XCTAssertEqual(putMeta.etag, "\"etag-put-99\"")
    }

    func testFaceIDUsageDescriptionIsLocalizedInEnglishAndChinese() throws {
        let enPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let enBundle = try XCTUnwrap(Bundle(path: enPath))
        let enInfoPath = try XCTUnwrap(enBundle.path(forResource: "InfoPlist", ofType: "strings"))
        let enStrings = try XCTUnwrap(NSDictionary(contentsOfFile: enInfoPath) as? [String: String])
        XCTAssertFalse((enStrings["NSFaceIDUsageDescription"] ?? "").isEmpty)

        let zhPath = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let zhBundle = try XCTUnwrap(Bundle(path: zhPath))
        let zhInfoPath = try XCTUnwrap(zhBundle.path(forResource: "InfoPlist", ofType: "strings"))
        let zhStrings = try XCTUnwrap(NSDictionary(contentsOfFile: zhInfoPath) as? [String: String])
        XCTAssertFalse((zhStrings["NSFaceIDUsageDescription"] ?? "").isEmpty)
        XCTAssertNil(enStrings["NSCalendarsWriteOnlyAccessUsageDescription"])
        XCTAssertNil(enStrings["NSRemindersFullAccessUsageDescription"])
        XCTAssertNil(zhStrings["NSCalendarsWriteOnlyAccessUsageDescription"])
        XCTAssertNil(zhStrings["NSRemindersFullAccessUsageDescription"])
    }

    func testWebDAVServerURLRejectsEmbeddedCredentialsQueryAndFragment() throws {
        let valid = try WebDAVSyncService.validatedServerURL("https://dav.example.com/dav")
        XCTAssertEqual(valid.absoluteString, "https://dav.example.com/dav/")

        for bad in [
            "https://alice:secret@dav.example.com/dav/",
            "https://alice@dav.example.com/dav/",
            "https://dav.example.com/dav/?token=1",
            "https://dav.example.com/dav/#section"
        ] {
            XCTAssertThrowsError(try WebDAVSyncService.validatedServerURL(bad), bad) { error in
                XCTAssertEqual(error as? WebDAVSyncError, .invalidURL)
            }
        }
    }

    func testWebDAVConditionalPutHeaders412AndStreamingByteCap() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWebDAVURLProtocol.self]
        let session = URLSession(configuration: config)

        // 1. If-Match header sent and HTTP 412 mapped to .preconditionFailed
        MockWebDAVURLProtocol.handler = { req in
            if req.httpMethod == "PUT" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "If-Match"), "\"etag-v1\"")
                XCTAssertNil(req.value(forHTTPHeaderField: "If-None-Match"))
                return (HTTPURLResponse(url: req.url!, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        do {
            _ = try await WebDAVSyncService.uploadEncryptedData(
                Data("{\"magic\":\"test\"}".utf8),
                serverURL: "https://dav.example.com/dav/",
                remotePath: "Fugue/fugue-sync.enc.json",
                username: "alice",
                password: "secret",
                ifMatchETag: "\"etag-v1\"",
                session: session
            )
            XCTFail("Expected preconditionFailed")
        } catch let err as WebDAVSyncError {
            XCTAssertEqual(err, .preconditionFailed)
        }

        // 2. If-None-Match: * sent for initial creation
        MockWebDAVURLProtocol.handler = { req in
            if req.httpMethod == "PUT" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "*")
                XCTAssertNil(req.value(forHTTPHeaderField: "If-Match"))
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"etag-init\""])!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let created = try await WebDAVSyncService.uploadEncryptedData(
            Data("{\"magic\":\"test\"}".utf8),
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "secret",
            ifNoneMatchStar: true,
            session: session
        )
        XCTAssertEqual(created.etag, "\"etag-init\"")

        // 3. Streaming download enforces hard byte cap even without Content-Length header
        MockWebDAVURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"big\""])!
            return (response, Data(repeating: 0x41, count: 128))
        }
        do {
            _ = try await WebDAVSyncService.downloadRawData(
                serverURL: "https://dav.example.com/dav/",
                remotePath: "Fugue/fugue-sync.enc.json",
                username: "alice",
                password: "secret",
                maxBytes: 64,
                session: session
            )
            XCTFail("Expected payloadTooLarge")
        } catch let err as WebDAVSyncError {
            XCTAssertEqual(err, .payloadTooLarge)
        }

        let (exactData, exactMeta) = try await WebDAVSyncService.downloadRawData(
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "secret",
            maxBytes: 128,
            session: session
        )
        XCTAssertEqual(exactData.count, 128)
        XCTAssertEqual(exactMeta.etag, "\"big\"")
    }

    func testWebDAVCoordinatorRetriesOnceOn412AndRetainsConcurrentLocalChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webdav-412-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let schema = Schema(versionedSchema: CurrentSchema.self)
        let localContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: dir.appendingPathComponent("local.store"))
        )
        let remoteContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )

        let localConv = Conversation(title: "本地新对话")
        localContainer.mainContext.insert(localConv)
        try localContainer.mainContext.save()

        let remoteConv = Conversation(title: "远端并发新对话")
        remoteContainer.mainContext.insert(remoteConv)
        try remoteContainer.mainContext.save()
        let passphrase = "sync-passphrase-412"
        let remoteEncrypted = try EncryptedBackupService.exportEncryptedData(
            context: remoteContainer.mainContext,
            password: passphrase
        )

        let coordinator = WebDAVAutoSyncCoordinator()
        isolatedPreferences.webDAVServerURL = "https://dav.example.com/dav/"
        isolatedPreferences.webDAVUsername = "alice"
        isolatedPreferences.webDAVRemotePath = "Fugue/fugue-sync.enc.json"
        isolatedPreferences.webDAVLastRemoteETag = "\"etag-v1\""
        coordinator.markLocalDataChanged()
        XCTAssertTrue(coordinator.hasLocalChangesPending)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWebDAVURLProtocol.self]
        let session = URLSession(configuration: config)

        let stateLock = NSLock()
        var headCount = 0
        var putCount = 0
        var capturedIfMatches: [String] = []

        MockWebDAVURLProtocol.handler = { req in
            switch req.httpMethod {
            case "HEAD":
                let current = stateLock.withLock { () -> Int in headCount += 1; return headCount }
                let etag = current == 1 ? "\"etag-v1\"" : "\"etag-v2\""
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])!, Data())
            case "MKCOL":
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            case "GET":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"etag-v2\""])!, remoteEncrypted)
            case "PUT":
                let attempt = stateLock.withLock { () -> Int in
                    putCount += 1
                    if let header = req.value(forHTTPHeaderField: "If-Match") {
                        capturedIfMatches.append(header)
                    }
                    return putCount
                }
                if attempt == 1 {
                    return (HTTPURLResponse(url: req.url!, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                }
                // Simulate a concurrent user edit arriving while the retry PUT is in flight.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { coordinator.markLocalDataChanged() }
                } else {
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated { coordinator.markLocalDataChanged() }
                    }
                }
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"etag-v3\""])!, Data())
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
        }

        await coordinator.syncIfNeeded(
            trigger: .manualSmart,
            context: localContainer.mainContext,
            preferences: isolatedPreferences,
            credentials: (password: "dav-secret", passphrase: passphrase),
            session: session
        )

        XCTAssertNil(coordinator.lastSyncError)
        XCTAssertEqual(capturedIfMatches, ["\"etag-v1\"", "\"etag-v2\""])
        XCTAssertEqual(isolatedPreferences.webDAVLastRemoteETag, "\"etag-v3\"")
        // Local edit made while PUT was in flight MUST NOT be lost!
        XCTAssertTrue(coordinator.hasLocalChangesPending)

        let titles = Set(try localContainer.mainContext.fetch(FetchDescriptor<Conversation>()).map(\.title))
        XCTAssertTrue(titles.contains("本地新对话"))
        XCTAssertTrue(titles.contains("远端并发新对话"))
    }

    func testArtifactSVGSanitizationStripsActivePayloadsWhilePreservingLocalFragments() {
        let dirty = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <?xml-stylesheet type="text/xsl" href="https://evil.example/a.xsl"?>
        <svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)">
          <defs><linearGradient id="g1"><stop offset="0%"/></linearGradient></defs>
          <script>alert('xss')</script>
          <svg:script>fetch('https://evil.example')</svg:script>
          <foreignObject width="100" height="100"><body onclick="steal()">hi</body></foreignObject>
          <rect width="80" height="40" fill="url(#g1)" onerror="bad()" />
          <use xlink:href="#g1" />
          <a href="javascript:alert(2)"><text>click</text></a>
          <image xlink:href="https://evil.example/tracker.png" width="10" height="10" />
        </svg>
        """
        let clean = ArtifactDocumentBuilder.sanitizedSVG(dirty)
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("svg:script"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("foreignObject"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("onload="))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("onerror="))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("javascript:"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("evil.example"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("<!DOCTYPE"))
        XCTAssertFalse(clean.localizedCaseInsensitiveContains("xml-stylesheet"))
        XCTAssertTrue(clean.contains("<svg"))
        XCTAssertTrue(clean.contains(#"fill="url(#g1)""#))
        XCTAssertTrue(clean.contains(##"xlink:href="#g1""##))
    }

    func testProjectKnowledgeSearchByteBudgetAndMemoryWarningEviction() async throws {
        let storage = FullTextSearchIndex(databaseURL: nil)
        let search = ProjectKnowledgeSearch(storage: storage, maxCachedTextBytes: 1_200)

        let bodyA = String(repeating: "Alpha nebula protocol specification. ", count: 24)
        let bodyB = String(repeating: "Beta pulsar telemetry documentation. ", count: 24)
        let dataA = try BookManuscript(title: "Book A", chapters: [BookChapter(title: "Ch1", text: bodyA)]).encoded()
        let dataB = try BookManuscript(title: "Book B", chapters: [BookChapter(title: "Ch1", text: bodyB)]).encoded()
        let idA = BookManuscript.identifier(for: dataA)
        let idB = BookManuscript.identifier(for: dataB)

        _ = try await search.retrieve(
            from: [KnowledgeDocumentSnapshot(id: idA, title: "Book A", manuscript: dataA)],
            query: "Alpha nebula"
        )
        let afterA = await search.cachedVolumeCount
        XCTAssertEqual(afterA, 1)
        XCTAssertTrue(search.isCached(idA))

        // Loading Book B pushes combined chunk bytes over the 1,200-byte budget, evicting LRU Book A.
        _ = try await search.retrieve(
            from: [KnowledgeDocumentSnapshot(id: idB, title: "Book B", manuscript: dataB)],
            query: "Beta pulsar"
        )
        let afterB = await search.cachedVolumeCount
        XCTAssertEqual(afterB, 1)
        XCTAssertFalse(search.isCached(idA))
        XCTAssertTrue(search.isCached(idB))

        // Memory warning clears RAM cache completely while SQLite FTS5 still serves queries transparently.
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while await search.cachedVolumeCount > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let afterWarningCount = await search.cachedVolumeCount
        let afterWarningBytes = await search.cachedTextBytes
        XCTAssertEqual(afterWarningCount, 0)
        XCTAssertEqual(afterWarningBytes, 0)

        // Querying with manuscript == nil still succeeds by restoring persisted chunks from SQLite FTS5.
        let restoredEvidence = try await search.retrieve(
            from: [KnowledgeDocumentSnapshot(id: idA, title: "Book A", manuscript: nil)],
            query: "Alpha nebula"
        )
        XCTAssertFalse(restoredEvidence.passages.isEmpty)
        XCTAssertEqual(restoredEvidence.passages.first?.volumeID, idA)
    }

    func testConversationSearchRetainsUnchangedBooksAndPrunesDeletedOrRenamedBooks() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let data1 = try BookManuscript(
            title: "星海手册",
            chapters: [BookChapter(title: "第一章", text: "量子航标用于深空导航定位。")]
        ).encoded()
        let data2 = try BookManuscript(
            title: "山河日志",
            chapters: [BookChapter(title: "序言", text: "渡口渡船在清晨起航。")]
        ).encoded()

        let book1 = BookVolume(id: BookManuscript.identifier(for: data1), title: "星海手册", chapterTitles: ["第一章"], manuscript: data1)
        let book2 = BookVolume(id: BookManuscript.identifier(for: data2), title: "山河日志", chapterTitles: ["序言"], manuscript: data2)
        context.insert(book1)
        context.insert(book2)
        try context.save()

        let index = FullTextSearchIndex(databaseURL: nil)
        let search = ConversationHistorySearch(index: index)

        // First search indexes both books.
        let first = try await search.searchAll(
            for: HistorySearchQuery(text: "量子航标", scope: .books),
            in: container
        )
        XCTAssertEqual(first.books.map(\.volumeID), [book1.id])
        let summaries = try await index.indexedBookVolumeSummaries()
        XCTAssertEqual(summaries.count, 2)

        // Second search retains unchanged books via summary fast path and still hits Book 2.
        let second = try await search.searchAll(
            for: HistorySearchQuery(text: "渡口渡船", scope: .books),
            in: container
        )
        XCTAssertEqual(second.books.map(\.bookTitle), ["山河日志"])

        // Deleting Book 1 prunes it from FTS5; renaming Book 2 re-indexes its updated title.
        context.delete(book1)
        book2.title = "山河新志"
        try context.save()

        let deletedHit = try await search.searchAll(
            for: HistorySearchQuery(text: "量子航标", scope: .books),
            in: container
        )
        XCTAssertTrue(deletedHit.books.isEmpty)

        let renamedHit = try await search.searchAll(
            for: HistorySearchQuery(text: "渡口渡船", scope: .books),
            in: container
        )
        XCTAssertEqual(renamedHit.books.map(\.bookTitle), ["山河新志"])
    }

    func testChatDraftStoreAsyncSaveAndLinearizableSyncOverwrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-async-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ChatDraftStore(directory: dir)
        let id = UUID()
        let firstDraft = ChatDraft(
            text: "异步草稿内容",
            attachments: [MessageAttachment(kind: .document, fileName: "spec.txt", mimeType: "text/plain", extractedText: "hello", byteSize: 5)]
        )
        try await store.saveAsync(firstDraft, for: id)

        let coldReload = try ChatDraftStore(directory: dir).load(id)
        XCTAssertEqual(coldReload, firstDraft)

        // A synchronous save issued while an async save is already in flight must never be clobbered.
        let staleDraft = ChatDraft(text: String(repeating: "stale ", count: 2_000))
        let latestDraft = ChatDraft(text: "最终同步草稿")
        let asyncTask = Task {
            try await store.saveAsync(staleDraft, for: id)
        }
        // Yield once so `saveAsync` begins and queues its background write before synchronous `save` runs.
        await Task.yield()
        try store.save(latestDraft, for: id)
        try await asyncTask.value

        XCTAssertEqual(try store.load(id), latestDraft)
        XCTAssertEqual(try ChatDraftStore(directory: dir).load(id), latestDraft)
    }

    func testKeychainServiceUpgradesLegacyAccessibilityToThisDeviceOnly() throws {
        let serviceName = "com.iosbox.app.provider-keys"
        let legacyAccount = "test/legacy-upgrade/\(UUID().uuidString)"
        let restoredAccount = "test/restore-device-only/\(UUID().uuidString)"
        defer {
            KeychainService.shared.deleteSecret(account: legacyAccount)
            KeychainService.shared.deleteSecret(account: restoredAccount)
        }

        // Seed a legacy kSecAttrAccessibleAfterFirstUnlock item directly.
        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: legacyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data("legacy-api-key".utf8)
        ]
        XCTAssertEqual(SecItemAdd(legacyItem as CFDictionary, nil), errSecSuccess)

        // Reading through KeychainService must return the secret AND upgrade it in-place to ThisDeviceOnly.
        XCTAssertEqual(KeychainService.shared.loadSecret(account: legacyAccount), "legacy-api-key")

        func fetchAccessibility(account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let dict = item as? [String: Any] else { return nil }
            return dict[kSecAttrAccessible as String] as? String
        }

        XCTAssertEqual(fetchAccessibility(account: legacyAccount), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        XCTAssertTrue(KeychainService.shared.saveSecret("updated-api-key", account: legacyAccount))
        XCTAssertEqual(fetchAccessibility(account: legacyAccount), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        XCTAssertTrue(KeychainService.shared.restoreSecretIfMissing("restored-key", account: restoredAccount))
        XCTAssertEqual(fetchAccessibility(account: restoredAccount), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
