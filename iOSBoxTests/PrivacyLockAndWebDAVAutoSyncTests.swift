import LocalAuthentication
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

        let reloaded = AppPreferences(defaults: isolatedDefaults)
        XCTAssertTrue(reloaded.appLockEnabled)
        XCTAssertEqual(reloaded.appLockGracePeriod, .fifteenMinutes)
        XCTAssertTrue(reloaded.privacyBlurOnBackground)
        XCTAssertTrue(reloaded.webDAVAutoSyncEnabled)
        XCTAssertEqual(reloaded.webDAVAutoSyncIntervalMinutes, 30)
        XCTAssertEqual(reloaded.webDAVLastRemoteETag, "\"abc-123\"")
        XCTAssertEqual(try XCTUnwrap(reloaded.webDAVLastRemoteModifiedAt).timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.1)
        XCTAssertEqual(reloaded.webDAVLastAutoSyncSummary, "同步成功")
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
    }
}
