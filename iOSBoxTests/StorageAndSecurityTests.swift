import XCTest
import SwiftData
import SwiftUI
@testable import iOSBox

final class SchemaMigrationTests: XCTestCase {

    /// Simulates an existing install: a store written by the original (unversioned) V1 schema
    /// must open with the current schema + migration plan without losing data.
    func testV1StoreMigratesToCurrentSchemaPreservingData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString).store")
        let attachmentBlob = Data(repeating: 7, count: 300_000)

        do {
            let v1Schema = Schema([
                SchemaV1.ProviderConfig.self,
                SchemaV1.AssistantPreset.self,
                SchemaV1.Conversation.self,
                SchemaV1.ChatMessage.self
            ])
            let container = try ModelContainer(
                for: v1Schema,
                configurations: [ModelConfiguration(schema: v1Schema, url: url)]
            )
            let context = ModelContext(container)
            let conversation = SchemaV1.Conversation()
            conversation.title = "旧对话"
            let message = SchemaV1.ChatMessage()
            message.roleRaw = "assistant"
            message.content = "旧消息"
            message.attachmentsData = attachmentBlob
            message.conversation = conversation
            context.insert(conversation)
            context.insert(message)
            try context.save()
        }

        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try PersistenceController.open(
            schema: schema,
            configuration: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        let messages = try context.fetch(FetchDescriptor<ChatMessage>())

        XCTAssertEqual(messages.count, 1)
        let migrated = try XCTUnwrap(messages.first)
        XCTAssertEqual(migrated.content, "旧消息")
        XCTAssertEqual(migrated.attachmentsData, attachmentBlob)
        XCTAssertNil(migrated.finishReason)
        XCTAssertEqual(migrated.conversation?.title, "旧对话")
    }
}

final class NetworkLocationTests: XCTestCase {

    func testPrivateAndLocalHosts() {
        let local = [
            "http://localhost:11434/v1",
            "http://127.0.0.1:8080",
            "http://192.168.1.100:11434/v1",
            "http://10.0.0.5/v1",
            "http://172.20.1.1/v1",
            "http://100.101.102.103:11434",   // Tailscale
            "http://my-mac.local:1234/v1",
            "http://nas:8000/v1",
            "http://[::1]:11434/v1",
            "http://192.168.1.100:11434/v1#"
        ]
        for url in local {
            XCTAssertTrue(NetworkLocation.isLocalOrPrivate(baseURL: url), url)
        }
    }

    func testPublicHostsAreNotMistakenForPrivate() {
        let publicURLs = [
            "https://api10.example.com/v1",      // contains "10." as a substring
            "https://api.siliconflow.cn/v1",
            "https://172.217.0.1/v1",            // public 172.x outside 16–31
            "https://openrouter.ai/api/v1",
            "https://10.example.com/v1"
        ]
        for url in publicURLs {
            XCTAssertFalse(NetworkLocation.isLocalOrPrivate(baseURL: url), url)
        }
    }

    func testPlainHTTPWarningOnlyForPublicHosts() {
        XCTAssertTrue(NetworkLocation.isPlainHTTPToPublicHost(baseURL: "http://relay.example.com/v1"))
        XCTAssertFalse(NetworkLocation.isPlainHTTPToPublicHost(baseURL: "https://relay.example.com/v1"))
        XCTAssertFalse(NetworkLocation.isPlainHTTPToPublicHost(baseURL: "http://192.168.1.100:11434/v1"))
        XCTAssertFalse(NetworkLocation.isPlainHTTPToPublicHost(baseURL: ""))
    }
}

final class SecretHeaderTests: XCTestCase {

    func testLegacyHeaderJSONWithoutIsSecretStillDecodes() throws {
        let legacy = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","key":"HTTP-Referer","value":"https://x.app","isEnabled":true}]"#
        let headers = try JSONDecoder().decode([CustomHeader].self, from: Data(legacy.utf8))
        XCTAssertEqual(headers.first?.key, "HTTP-Referer")
        XCTAssertEqual(headers.first?.isSecret, false)
    }

    func testSecretHeaderValueLivesInKeychainNotInDatabase() throws {
        let provider = ProviderConfig(name: "Gateway", protocolType: .openAICompatible, baseURL: "https://gw.example.com/v1")
        defer { provider.deleteAllSecrets() }

        provider.addCustomHeader(key: "X-Gateway-Token", value: "secret-123", isSecret: true)

        let stored = try XCTUnwrap(provider.customHeaders.first)
        XCTAssertTrue(stored.isSecret)
        XCTAssertEqual(stored.value, "")
        XCTAssertFalse(String(decoding: provider.headersData, as: UTF8.self).contains("secret-123"))
        XCTAssertEqual(provider.resolvedCustomHeaders.first?.value, "secret-123")

        provider.removeCustomHeader(id: stored.id)
        XCTAssertTrue(provider.customHeaders.isEmpty)
        XCTAssertEqual(
            KeychainService.shared.loadSecret(account: KeychainService.headerAccount(providerID: provider.id, headerID: stored.id)),
            ""
        )
    }

    func testExistingPlaintextCredentialHeadersAreMovedToKeychain() {
        let provider = ProviderConfig(
            name: "Legacy",
            protocolType: .openAICompatible,
            baseURL: "https://gw.example.com/v1",
            customHeaders: [
                CustomHeader(key: "Authorization", value: "Bearer abc"),
                CustomHeader(key: "HTTP-Referer", value: "https://x.app")
            ]
        )
        defer { provider.deleteAllSecrets() }

        XCTAssertTrue(provider.moveSensitiveHeadersToKeychain())
        XCTAssertFalse(String(decoding: provider.headersData, as: UTF8.self).contains("Bearer abc"))

        let resolved = Dictionary(uniqueKeysWithValues: provider.resolvedCustomHeaders.map { ($0.key, $0.value) })
        XCTAssertEqual(resolved["Authorization"], "Bearer abc")
        XCTAssertEqual(resolved["HTTP-Referer"], "https://x.app")
        XCTAssertFalse(provider.moveSensitiveHeadersToKeychain(), "second run is a no-op")
    }
}

final class MarkdownRenderingTests: XCTestCase {

    func testDeepHeadingsAreParsed() {
        let blocks = MarkdownBlockParser.parse("#### 四级标题\n###### 六级\n####### 不是标题\n#没有空格")
        XCTAssertEqual(blocks.first, .heading(4, "四级标题"))
        XCTAssertEqual(blocks.dropFirst().first, .heading(6, "六级"))
        XCTAssertEqual(blocks.last, .paragraph("####### 不是标题\n#没有空格"))
    }

    func testURLInsideStringIsNotHighlightedAsComment() {
        let highlighted = SyntaxHighlighter.highlight(code: #"let url = "https://example.com/path""#)
        let usesCommentColor = highlighted.runs.contains { $0.foregroundColor == .secondary }
        XCTAssertFalse(usesCommentColor)
    }

    func testHashCommentsAreHighlightedButHexColorsAreNot() {
        let python = SyntaxHighlighter.highlight(code: "x = 1  # 注释")
        XCTAssertTrue(python.runs.contains { $0.foregroundColor == .secondary })

        let css = SyntaxHighlighter.highlight(code: "color: #fff;")
        XCTAssertFalse(css.runs.contains { $0.foregroundColor == .secondary })
    }
}
