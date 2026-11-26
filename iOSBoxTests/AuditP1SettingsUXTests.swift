import Foundation
import SwiftData
import Testing
import UIKit
@testable import iOSBox

private final class AuditTavilyMockURLProtocol: URLProtocol {
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

@Suite("Audit P1 Settings & Image Upload Quality UX Regressions", .serialized)
@MainActor
struct AuditP1SettingsUXTests {

    @Test("AppPreferences imageUploadQuality persists across relaunch and exposes 1600/2400/4096 max dimensions")
    func imageUploadQualityPersistenceAndDimensions() throws {
        #expect(ImageUploadQuality.standard.maxDimension == 1600)
        #expect(ImageUploadQuality.high.maxDimension == 2400)
        #expect(ImageUploadQuality.original.maxDimension == 4096)

        for quality in ImageUploadQuality.allCases {
            #expect(!quality.label.isEmpty)
            #expect(!quality.shortLabel.isEmpty)
        }

        let suiteName = "AuditP1SettingsUXTests.ImageQuality.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.imageUploadQuality == .standard)

        prefs.imageUploadQuality = .high
        #expect(ImageUploadQuality.current(defaults: defaults) == .high)
        #expect(AppPreferences(defaults: defaults).imageUploadQuality == .high)

        prefs.imageUploadQuality = .original
        #expect(ImageUploadQuality.current(defaults: defaults) == .original)
        #expect(AppPreferences(defaults: defaults).imageUploadQuality == .original)

        let sharedPrefs = AppPreferences.shared
        let previousSharedQuality = sharedPrefs.imageUploadQuality
        defer { sharedPrefs.imageUploadQuality = previousSharedQuality }

        sharedPrefs.imageUploadQuality = .high
        #expect(AppPreferences.shared.imageUploadQuality == .high)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let sampleImage = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }

        let standardAttachment = try #require(AttachmentProcessor.processImage(sampleImage, quality: .standard))
        let standardB64 = try #require(standardAttachment.dataBase64)
        let standardData = try #require(Data(base64Encoded: standardB64))
        let standardDecoded = try #require(UIImage(data: standardData))
        #expect(max(standardDecoded.size.width * standardDecoded.scale, standardDecoded.size.height * standardDecoded.scale) == 1600)

        let highAttachment = try #require(AttachmentProcessor.processImage(sampleImage, quality: .high))
        let highB64 = try #require(highAttachment.dataBase64)
        let highData = try #require(Data(base64Encoded: highB64))
        let highDecoded = try #require(UIImage(data: highData))
        #expect(max(highDecoded.size.width * highDecoded.scale, highDecoded.size.height * highDecoded.scale) == 2400)

        let originalAttachment = try #require(AttachmentProcessor.processImage(sampleImage, quality: .original))
        let originalB64 = try #require(originalAttachment.dataBase64)
        let originalData = try #require(Data(base64Encoded: originalB64))
        let originalDecoded = try #require(UIImage(data: originalData))
        #expect(max(originalDecoded.size.width * originalDecoded.scale, originalDecoded.size.height * originalDecoded.scale) == 3000)
    }

    @Test("SearchSettingsKeyManager isolates draft test keys without overwriting saved Keychain secret")
    func searchSettingsTestKeyIsolation() async {
        let testAccount = "test/audit-p1-tavily/\(UUID().uuidString)"
        let manager = SearchSettingsKeyManager(account: testAccount)
        defer {
            AuditTavilyMockURLProtocol.handler = nil
            KeychainService.shared.deleteSecret(account: testAccount)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditTavilyMockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        AuditTavilyMockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer tvly-saved-valid" || auth == "Bearer tvly-temp-candidate" {
                let body = #"{"results":[{"title":"Swift","url":"https://swift.org/documentation","content":"Swift language overview."}],"usage":{"credits":1}}"#
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "Content-Length": "\(body.utf8.count)"]
                )!
                return (response, Data(body.utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data())
        }

        #expect(manager.saveKey("tvly-saved-valid"))
        #expect(manager.loadSavedKey() == "tvly-saved-valid")

        // 1. Testing an invalid draft key must fail AND leave the saved valid key untouched.
        let invalidOutcome = await manager.testDraftKey("tvly-invalid-draft", savedKey: "tvly-saved-valid", session: session)
        #expect(invalidOutcome.isError)
        #expect(manager.loadSavedKey() == "tvly-saved-valid")

        // 2. Testing an empty draft key must fail AND leave the saved valid key untouched.
        let emptyOutcome = await manager.testDraftKey("   ", savedKey: "tvly-saved-valid", session: session)
        #expect(emptyOutcome.isError)
        #expect(manager.loadSavedKey() == "tvly-saved-valid")

        // 3. Testing a different valid candidate key succeeds without overwriting Keychain until explicitly saved.
        let candidateOutcome = await manager.testDraftKey("  tvly-temp-candidate  ", savedKey: "tvly-saved-valid", session: session)
        #expect(!candidateOutcome.isError)
        #expect(manager.loadSavedKey() == "tvly-saved-valid")

        // 4. Explicit save persists the new key; saving empty removes the key.
        #expect(manager.saveKey("  tvly-temp-candidate  "))
        #expect(manager.loadSavedKey() == "tvly-temp-candidate")
        #expect(!manager.hasUnsavedChanges(draftKey: "tvly-temp-candidate", savedKey: manager.loadSavedKey()))

        #expect(manager.saveKey(""))
        #expect(manager.loadSavedKey().isEmpty)
    }

    @Test("WebDAVDraftConfig detects dirty state, validates inputs, and guards auto-save on disappear")
    func webDAVDraftDirtyDetectionAndSaveState() throws {
        let suiteName = "AuditP1SettingsUXTests.WebDAV.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let passwordAccount = "test/audit-p1-webdav-pwd/\(UUID().uuidString)"
        let passphraseAccount = "test/audit-p1-webdav-pass/\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            KeychainService.shared.deleteSecret(account: passwordAccount)
            KeychainService.shared.deleteSecret(account: passphraseAccount)
        }

        let prefs = AppPreferences(defaults: defaults)
        let initialSaved = WebDAVDraftConfig.load(
            from: prefs,
            passwordAccount: passwordAccount,
            passphraseAccount: passphraseAccount
        )
        #expect(!initialSaved.hasAnyConfiguredValue)

        var draft = initialSaved
        #expect(!draft.hasUnsavedChanges(comparedTo: initialSaved))
        #expect(!draft.canSave(comparedTo: initialSaved))
        #expect(!draft.shouldAutoSaveOnDisappear(comparedTo: initialSaved))

        // Valid credential edits mark draft dirty, valid to save, and eligible for non-destructive auto-save.
        draft.serverURL = " https://dav.jianguoyun.com/dav/ "
        draft.username = " alice@example.com "
        draft.password = "app-specific-secret"
        draft.syncPassphrase = "strong-passphrase-2026"

        #expect(draft.canAuthenticate)
        #expect(draft.canSyncEncrypted)
        #expect(draft.validationError == nil)
        #expect(draft.hasUnsavedChanges(comparedTo: initialSaved))
        #expect(draft.canSave(comparedTo: initialSaved))
        #expect(draft.shouldAutoSaveOnDisappear(comparedTo: initialSaved))

        // Invalid public HTTP URL or short passphrase blocks saving and auto-saving.
        var insecureDraft = draft
        insecureDraft.serverURL = "http://dav.example.com/dav/"
        #expect(insecureDraft.validationError != nil)
        #expect(!insecureDraft.canSave(comparedTo: initialSaved))
        #expect(!insecureDraft.shouldAutoSaveOnDisappear(comparedTo: initialSaved))

        var shortPassDraft = draft
        shortPassDraft.syncPassphrase = "short"
        #expect(shortPassDraft.validationError != nil)
        #expect(!shortPassDraft.canSave(comparedTo: initialSaved))
        #expect(!shortPassDraft.shouldAutoSaveOnDisappear(comparedTo: initialSaved))

        // Persisting stores trimmed values and Keychain secrets cleanly.
        draft.persist(to: prefs, passwordAccount: passwordAccount, passphraseAccount: passphraseAccount)
        let persisted = WebDAVDraftConfig.load(
            from: prefs,
            passwordAccount: passwordAccount,
            passphraseAccount: passphraseAccount
        )
        #expect(persisted.serverURL == "https://dav.jianguoyun.com/dav/")
        #expect(persisted.username == "alice@example.com")
        #expect(persisted.password == "app-specific-secret")
        #expect(persisted.syncPassphrase == "strong-passphrase-2026")
        #expect(!draft.hasUnsavedChanges(comparedTo: persisted))
        #expect(!draft.canSave(comparedTo: persisted))

        // Updating password non-destructively auto-saves on disappear, whereas wiping password to empty does not.
        var updatedPasswordDraft = persisted
        updatedPasswordDraft.password = "rotated-secret-2"
        #expect(updatedPasswordDraft.shouldAutoSaveOnDisappear(comparedTo: persisted))

        var wipedPasswordDraft = persisted
        wipedPasswordDraft.password = ""
        #expect(wipedPasswordDraft.hasUnsavedChanges(comparedTo: persisted))
        #expect(!wipedPasswordDraft.shouldAutoSaveOnDisappear(comparedTo: persisted))
    }

    @Test("Voice language hint persists and resolves locale with zero cloud providers")
    func voiceLanguageHintPersistenceWithoutCloudProviders() throws {
        let sharedPrefs = AppPreferences.shared
        let previousSharedLang = sharedPrefs.audioTranscriptionLanguage
        defer { sharedPrefs.audioTranscriptionLanguage = previousSharedLang }

        let suiteName = "AuditP1SettingsUXTests.Voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Even with zero providers or only non-OpenAI / unconfigured providers, language hint remains usable.
        let anthropicOnly = ProviderConfig(
            name: "Claude Only",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "claude-sonnet-4")]
        )
        #expect(VoiceSettingsView.compatibleTranscriptionProviders(from: []).isEmpty)
        #expect(VoiceSettingsView.compatibleTranscriptionProviders(from: [anthropicOnly]).isEmpty)
        #expect(!AudioTranscriptionService.presetLanguages.isEmpty)
        #expect(AudioTranscriptionService.presetLanguages.contains(where: { $0.code.isEmpty }))

        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.audioTranscriptionLanguage.isEmpty)

        prefs.audioTranscriptionLanguage = "ja"
        #expect(AppPreferences(defaults: defaults).audioTranscriptionLanguage == "ja")
        #expect(VoiceSettingsView.resolvedSpeechLocale(for: prefs).identifier == "ja-JP")

        prefs.audioTranscriptionLanguage = "en"
        #expect(AppPreferences(defaults: defaults).audioTranscriptionLanguage == "en")
        #expect(VoiceSettingsView.resolvedSpeechLocale(for: prefs).identifier == "en-US")

        prefs.audioTranscriptionLanguage = "zh-Hant"
        #expect(AppPreferences(defaults: defaults).audioTranscriptionLanguage == "zh-Hant")
        #expect(VoiceSettingsView.resolvedSpeechLocale(for: prefs).identifier == "zh-TW")

        sharedPrefs.audioTranscriptionLanguage = "ko"
        #expect(AppPreferences.shared.audioTranscriptionLanguage == "ko")
        #expect(VoiceSettingsView.resolvedSpeechLocale(for: sharedPrefs).identifier == "ko-KR")
    }

    @Test("SystemQuickEntryGuideView dismisses Settings sheet cleanly before dispatching quick entry action")
    func quickEntryPreviewDismissesSettingsBeforeRouting() async {
        let previousSharedPending = SystemEntryRouter.shared.pendingQuickAction
        defer { SystemEntryRouter.shared.pendingQuickAction = previousSharedPending }

        let router = SystemEntryRouter()
        var events: [String] = []

        await SystemQuickEntryGuideView.triggerQuickEntryPreview(
            .bookmarks,
            router: router,
            onDismissSettings: {
                #expect(router.pendingQuickAction == nil)
                events.append("dismissSheet")
            },
            popNavigation: {
                events.append("popNav")
            },
            sheetDismissDelay: .milliseconds(10),
            navigationPopDelay: .milliseconds(5)
        )
        #expect(events == ["dismissSheet"])
        #expect(router.pendingQuickAction == .bookmarks)

        router.pendingQuickAction = nil
        events.removeAll()

        await SystemQuickEntryGuideView.triggerQuickEntryPreview(
            .voiceNote,
            router: router,
            onDismissSettings: nil,
            popNavigation: {
                #expect(router.pendingQuickAction == nil)
                events.append("popNav")
            },
            sheetDismissDelay: .milliseconds(10),
            navigationPopDelay: .milliseconds(5)
        )
        #expect(events == ["popNav"])
        #expect(router.pendingQuickAction == .voiceNote)
    }
}
