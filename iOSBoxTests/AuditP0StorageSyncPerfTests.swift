import Foundation
import SQLite3
import SwiftData
import Testing
import ZIPFoundation
@testable import iOSBox

private final class AuditWebDAVMockURLProtocol: URLProtocol {
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

    static func readUploadedBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                collected.append(buffer, count: count)
            } else {
                break
            }
        }
        return collected
    }
}

@Suite("Audit P0 Storage, Sync & Performance Regressions", .serialized)
@MainActor
struct AuditP0StorageSyncPerfTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeOnDiskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
    }

    private func executeSQL(_ db: OpaquePointer?, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            Issue.record("Unexpected SQLite error: \(detail)")
        }
    }

    private func makeZip(_ entries: [(String, String)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, content) in entries {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { offset, size in
                let start = Int(offset)
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        guard let zipData = archive.data else {
            throw BookImportError.invalidBook
        }
        return zipData
    }

    // MARK: - 1. PersistenceController SQLite Corruption Verification

    @Test("PersistenceController verifies on-disk SQLite integrity before rebuilding generic SwiftData errors")
    func sqliteCorruptionVerificationDistinguishesHealthyLockedAndCorruptFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let genericSwiftDataError = NSError(domain: "SwiftData.SwiftDataError", code: 1, userInfo: nil)

        // 1. Healthy SQLite database wrapped in opaque SwiftData error must NOT be treated as corrupt.
        let healthyURL = tempDir.appendingPathComponent("healthy.store")
        do {
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(healthyURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
            defer { if let db { sqlite3_close_v2(db) } }
            try executeSQL(db, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, 'safe');")
        }
        #expect(PersistenceController.isSQLiteStoreCorrupted(at: healthyURL) == false)
        #expect(
            PersistenceController.shouldRebuildCorruptedStore(
                after: genericSwiftDataError,
                storeURL: healthyURL,
                isProtectedDataAvailable: true
            ) == false
        )

        // 2. Exclusively locked SQLite database (simulating extension contention) must NOT be treated as corrupt.
        do {
            var lockConn: OpaquePointer?
            #expect(sqlite3_open_v2(healthyURL.path, &lockConn, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer {
                if let lockConn {
                    _ = sqlite3_exec(lockConn, "ROLLBACK;", nil, nil, nil)
                    sqlite3_close_v2(lockConn)
                }
            }
            try executeSQL(lockConn, "BEGIN EXCLUSIVE; INSERT INTO notes VALUES (2, 'locked');")
            #expect(PersistenceController.isSQLiteStoreCorrupted(at: healthyURL) == false)
            #expect(
                PersistenceController.shouldRebuildCorruptedStore(
                    after: genericSwiftDataError,
                    storeURL: healthyURL,
                    isProtectedDataAvailable: true
                ) == false
            )
        }

        // 3. Invalid SQLite header is detected as corrupt.
        let badHeaderURL = tempDir.appendingPathComponent("bad-header.store")
        try Data("not-a-valid-sqlite-header-at-all".utf8).write(to: badHeaderURL)
        #expect(PersistenceController.isSQLiteStoreCorrupted(at: badHeaderURL) == true)
        #expect(
            PersistenceController.shouldRebuildCorruptedStore(
                after: genericSwiftDataError,
                storeURL: badHeaderURL,
                isProtectedDataAvailable: true
            ) == true
        )

        // 4. Valid 16-byte SQLite header with damaged B-tree root page is caught by PRAGMA quick_check(1).
        let damagedBTreeURL = tempDir.appendingPathComponent("damaged-btree.store")
        try FileManager.default.copyItem(at: healthyURL, to: damagedBTreeURL)
        var rawBytes = try Data(contentsOf: damagedBTreeURL)
        #expect(rawBytes.count >= 512)
        for offset in 100..<min(256, rawBytes.count) {
            rawBytes[offset] = 0xFF
        }
        try rawBytes.write(to: damagedBTreeURL)
        #expect(PersistenceController.isSQLiteStoreCorrupted(at: damagedBTreeURL) == true)
        #expect(
            PersistenceController.shouldRebuildCorruptedStore(
                after: genericSwiftDataError,
                storeURL: damagedBTreeURL,
                isProtectedDataAvailable: true
            ) == true
        )
        #expect(
            PersistenceController.shouldRebuildCorruptedStore(
                after: genericSwiftDataError,
                storeURL: damagedBTreeURL,
                isProtectedDataAvailable: false
            ) == false
        )
    }

    // MARK: - 2. WebDAV Dirty Flag Persistence, Missing-ETag Refresh, & File-Backed Streaming Upload

    @Test("WebDAVAutoSyncCoordinator persists dirty state across relaunch, refreshes missing PUT ETag, and orders lastSyncAt")
    func webDAVDirtyFlagPersistenceMissingETagAndSyncTimestampOrdering() async throws {
        let suiteName = "audit.webdav.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            AuditWebDAVMockURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suiteName)
        }
        let prefs = AppPreferences(defaults: defaults)
        prefs.webDAVAutoSyncEnabled = true
        prefs.webDAVServerURL = "https://dav.example.com/dav/"
        prefs.webDAVUsername = "alice"
        prefs.webDAVRemotePath = "Fugue/fugue-sync.enc.json"
        prefs.webDAVLastRemoteETag = "\"etag-old\""

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-webdav-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localContainer = try makeOnDiskContainer(at: tempDir.appendingPathComponent("local.store"))
        let conv = Conversation(title: "待同步离线草稿")
        localContainer.mainContext.insert(conv)
        try localContainer.mainContext.save()

        // Mark dirty on first coordinator instance, then simulate app termination & relaunch.
        do {
            let firstCoordinator = WebDAVAutoSyncCoordinator(defaults: defaults)
            #expect(firstCoordinator.hasLocalChangesPending == false)
            firstCoordinator.markLocalDataChanged()
            #expect(firstCoordinator.hasLocalChangesPending == true)
        }

        let relaunchedCoordinator = WebDAVAutoSyncCoordinator(defaults: defaults)
        #expect(relaunchedCoordinator.hasLocalChangesPending == true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditWebDAVMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let passphrase = "Audit-Sync-Passphrase!"

        final class ServerState: @unchecked Sendable {
            let lock = NSLock()
            var currentETag = "\"etag-old\""
            var lastModified = "Wed, 25 Nov 2026 10:00:00 GMT"
            var storedPayload = Data()
            var getCount = 0
            var putCount = 0
            var headCount = 0
            var sawStreamingBody = false
            var failPut = false
        }
        let server = ServerState()

        AuditWebDAVMockURLProtocol.handler = { req in
            switch req.httpMethod {
            case "HEAD":
                let (etag, lastMod) = server.lock.withLock { () -> (String, String) in
                    server.headCount += 1
                    return (server.currentETag, server.lastModified)
                }
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": etag, "Last-Modified": lastMod]
                )!
                return (resp, Data())

            case "MKCOL":
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())

            case "PUT":
                let shouldFail = server.lock.withLock { server.failPut }
                if shouldFail {
                    return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                }
                let streamed = (req.httpBody == nil && req.httpBodyStream != nil)
                let body = AuditWebDAVMockURLProtocol.readUploadedBody(from: req)
                let updatedLastMod = "Wed, 25 Nov 2026 10:05:00 GMT"
                server.lock.withLock {
                    server.putCount += 1
                    server.sawStreamingBody = streamed
                    server.storedPayload = body
                    server.currentETag = "\"etag-after-put\""
                    server.lastModified = updatedLastMod
                }
                // Deliberately omit ETag on PUT (only Last-Modified returned, like Nextcloud/Nginx WebDAV).
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Last-Modified": updatedLastMod]
                )!
                return (resp, Data())

            case "GET":
                let (etag, payload) = server.lock.withLock { () -> (String, Data) in
                    server.getCount += 1
                    return (server.currentETag, server.storedPayload)
                }
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": etag]
                )!
                return (resp, payload)

            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
        }

        // First foreground sync pushes the persisted dirty change, streams from file, and refreshes ETag via HEAD.
        await relaunchedCoordinator.syncIfNeeded(
            trigger: .foreground,
            context: localContainer.mainContext,
            preferences: prefs,
            credentials: (password: "dav-secret", passphrase: passphrase),
            session: session
        )

        #expect(relaunchedCoordinator.lastSyncError == nil)
        #expect(relaunchedCoordinator.hasLocalChangesPending == false)
        #expect(server.lock.withLock { server.putCount } == 1)
        #expect(server.lock.withLock { server.sawStreamingBody } == true)
        #expect(prefs.webDAVLastRemoteETag == "\"etag-after-put\"")
        #expect(prefs.webDAVLastSyncAt != nil)

        // Immediate follow-up manualSmart sync with clean local state must NOT falsely re-download!
        prefs.webDAVLastSyncAt = Date(timeIntervalSince1970: 1_000)
        await relaunchedCoordinator.syncIfNeeded(
            trigger: .foreground,
            context: localContainer.mainContext,
            preferences: prefs,
            credentials: (password: "dav-secret", passphrase: passphrase),
            session: session
        )
        #expect(server.lock.withLock { server.getCount } == 0)

        // Verify pullMergeThenPush does NOT advance webDAVLastSyncAt if push fails after pull succeeds.
        let remoteContainer = try makeInMemoryContainer()
        let remoteConv = Conversation(title: "远端新增对话")
        remoteContainer.mainContext.insert(remoteConv)
        try remoteContainer.mainContext.save()
        let remoteBytes = try EncryptedBackupService.exportEncryptedData(
            context: remoteContainer.mainContext,
            password: passphrase
        )
        let priorSyncDate = Date(timeIntervalSince1970: 2_000)
        prefs.webDAVLastSyncAt = priorSyncDate
        relaunchedCoordinator.markLocalDataChanged()
        server.lock.withLock {
            server.storedPayload = remoteBytes
            server.currentETag = "\"etag-remote-v3\""
            server.failPut = true
        }

        await relaunchedCoordinator.syncIfNeeded(
            trigger: .foreground,
            context: localContainer.mainContext,
            preferences: prefs,
            credentials: (password: "dav-secret", passphrase: passphrase),
            session: session
        )
        #expect(relaunchedCoordinator.lastSyncError != nil)
        #expect(relaunchedCoordinator.hasLocalChangesPending == true)
        #expect(prefs.webDAVLastSyncAt == priorSyncDate)
    }

    // MARK: - 3. EncryptedBackupService Disabled Provider & Sync Config Updates

    @Test("EncryptedBackupService preserves disabled provider state and syncs updated configs")
    func encryptedBackupPreservesDisabledProviderAndSyncsUpdatedConfigs() throws {
        let srcContainer = try makeInMemoryContainer()
        let srcCtx = srcContainer.mainContext
        let srcKB = PresetKnowledgeStore(fileURL: nil)

        let disabledProvider = ProviderConfig(
            name: "Disabled Relay",
            protocolType: .openAICompatible,
            baseURL: "https://disabled.example.com/v1",
            isEnabled: false,
            models: [ModelSpec(id: "gpt-4.1-mini")]
        )
        let enabledProvider = ProviderConfig(
            name: "Enabled Relay",
            protocolType: .openAICompatible,
            baseURL: "https://enabled.example.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "gpt-4.1")]
        )
        let preset = AssistantPreset(name: "初始助手", systemPrompt: "v1")
        srcCtx.insert(disabledProvider)
        srcCtx.insert(enabledProvider)
        srcCtx.insert(preset)
        try srcCtx.save()

        let disabledID = disabledProvider.id
        let enabledID = enabledProvider.id
        defer {
            _ = srcContainer
            disabledProvider.deleteAllSecrets()
            enabledProvider.deleteAllSecrets()
        }
        #expect(KeychainService.shared.saveAPIKey("sk-disabled-key", for: disabledProvider.credentialID))
        #expect(KeychainService.shared.saveAPIKey("sk-enabled-key", for: enabledProvider.credentialID))

        let password = "Audit-Password-2026!"
        let encrypted = try EncryptedBackupService.exportEncryptedData(
            context: srcCtx,
            password: password,
            knowledgeStore: srcKB
        )

        // 1. Manual encrypted restore keeps disabled providers disabled (and new providers disabled for review).
        let manualDest = try makeInMemoryContainer()
        let manualKB = PresetKnowledgeStore(fileURL: nil)
        _ = try EncryptedBackupService.decryptAndApply(
            data: encrypted,
            password: password,
            to: manualDest.mainContext,
            knowledgeStore: manualKB,
            tombstonePolicy: .ignore
        )
        let manualProviders = try manualDest.mainContext.fetch(FetchDescriptor<ProviderConfig>())
        defer {
            _ = manualDest
            manualProviders.forEach { $0.deleteAllSecrets() }
        }
        let manualDisabled = try #require(manualProviders.first { $0.id == disabledID })
        #expect(manualDisabled.isEnabled == false)
        #expect(manualDisabled.apiKey == "sk-disabled-key")

        // 2. WebDAV sync (.enforce) enables active providers with valid credentials while keeping disabled providers disabled!
        let syncDest = try makeInMemoryContainer()
        let syncKB = PresetKnowledgeStore(fileURL: nil)
        let tombstones = SyncTombstoneStore(fileURL: nil)
        _ = try EncryptedBackupService.decryptAndApply(
            data: encrypted,
            password: password,
            to: syncDest.mainContext,
            knowledgeStore: syncKB,
            tombstonePolicy: .enforce(tombstones)
        )
        let syncedProviders = try syncDest.mainContext.fetch(FetchDescriptor<ProviderConfig>())
        defer {
            _ = syncDest
            syncedProviders.forEach { $0.deleteAllSecrets() }
        }
        let syncedDisabled = try #require(syncedProviders.first { $0.id == disabledID })
        let syncedEnabled = try #require(syncedProviders.first { $0.id == enabledID })
        #expect(syncedDisabled.isEnabled == false)
        #expect(syncedEnabled.isEnabled == true)

        // 3. Subsequent sync propagates disabling an enabled provider, updating models, and editing presets.
        enabledProvider.isEnabled = false
        enabledProvider.name = "Renamed Relay"
        enabledProvider.models = [ModelSpec(id: "gpt-4.1"), ModelSpec(id: "o4-mini")]
        enabledProvider.updatedAt = Date().addingTimeInterval(120)
        preset.name = "更新后的助手"
        preset.systemPrompt = "v2"
        try srcCtx.save()

        let updatedEncrypted = try EncryptedBackupService.exportEncryptedData(
            context: srcCtx,
            password: password,
            knowledgeStore: srcKB
        )
        _ = try EncryptedBackupService.decryptAndApply(
            data: updatedEncrypted,
            password: password,
            to: syncDest.mainContext,
            knowledgeStore: syncKB,
            tombstonePolicy: .enforce(tombstones)
        )

        #expect(syncedEnabled.isEnabled == false)
        #expect(syncedEnabled.name == "Renamed Relay")
        #expect(syncedEnabled.models.map(\.id) == ["gpt-4.1", "o4-mini"])
        let syncedPreset = try #require(try syncDest.mainContext.fetch(FetchDescriptor<AssistantPreset>()).first)
        #expect(syncedPreset.name == "更新后的助手")
        #expect(syncedPreset.systemPrompt == "v2")
    }

    // MARK: - 4. XLSX Shared-String Expansion Bomb OOM Guard

    @Test("OfficeDocumentReader aborts crafted XLSX shared-string amplification bomb within text byte cap")
    func xlsxSharedStringAmplificationBombAbortsQuickly() throws {
        // One 512 KB shared string referenced across 200 rows x 32 cols (~3.2 GB expanded if unguarded, ~140 KB XML).
        let sharedPayload = String(repeating: "S", count: 524_288)
        let sharedStringsXML = """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">
          <si><t>\(sharedPayload)</t></si>
        </sst>
        """

        var sheetXML = "<worksheet><sheetData>"
        let rowCells = (0..<32).map { _ in "<c t=\"s\"><v>0</v></c>" }.joined()
        for r in 1...200 {
            sheetXML += "<row r=\"\(r)\">\(rowCells)</row>"
        }
        sheetXML += "</sheetData></worksheet>"

        let bombData = try makeZip([
            ("xl/sharedStrings.xml", sharedStringsXML),
            ("xl/worksheets/sheet1.xml", sheetXML)
        ])

        do {
            _ = try OfficeDocumentReader.extractChapters(from: bombData, ext: "xlsx", fallbackTitle: "Bomb")
            Issue.record("Expected BookImportError.textLimit to be thrown")
        } catch BookImportError.textLimit {
            // Expected fast abort within byte budget
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    // MARK: - 5. FullTextSearchIndex Backup Exclusion & Cross-Locale PDF OCR Search/Merge

    @Test("FullTextSearchIndex excludes SQLite cache from backup and indexes progressive/cross-locale PDF OCR")
    func ftsDatabaseExcludedFromBackupAndCrossLocalePDFOCRMergesCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-fts5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("fugue-search-fts5.sqlite")
        let index = FullTextSearchIndex(databaseURL: dbURL)

        try await index.syncDocuments(
            entityType: .conversation,
            documents: [
                FTSIndexedDocument(
                    docKey: "chat:test",
                    entityType: .conversation,
                    parentID: "test",
                    itemID: "test",
                    title: "备份排除校验",
                    subtitle: "",
                    rawBody: "验证索引库不会进入云备份",
                    rawAux: "",
                    folderTag: nil,
                    isBookmarked: false,
                    isOtherBranch: false,
                    role: nil,
                    speaker: nil,
                    chapterIndex: nil,
                    utf16Offset: nil,
                    createdAt: .now,
                    updatedAt: .now,
                    fingerprint: "fp1"
                )
            ]
        )

        let resourceValues = try dbURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)

        // Cross-locale PDF page deduplication ("Page 1" vs "第 1 页") without duplicate chapters or conflictingIDs.
        let englishInitial = [
            BookChapter(title: "Page 1", text: "Introduction to distributed storage"),
            BookChapter(title: "Page 3", text: "Replication invariants")
        ]
        let chineseAdditions = [
            BookChapter(title: "第 1 页", text: "Duplicate page one in Chinese locale"),
            BookChapter(title: "第 2 页", text: "Newly recognized page two via Vision OCR")
        ]
        let mergedChapters = BackgroundPDFOCRQueue.mergeChaptersInPageOrder(
            existing: englishInitial,
            additions: chineseAdditions
        )
        #expect(mergedChapters.map(\.title) == ["Page 1", "Page 2", "Page 3"])
        #expect(mergedChapters[0].text == "Introduction to distributed storage")
        #expect(mergedChapters[1].text == "Newly recognized page two via Vision OCR")

        // Merging PDF snapshots OCR'd in different locales via BackupService must NOT throw conflictingIDs.
        let containerA = try makeInMemoryContainer()
        let containerB = try makeInMemoryContainer()
        let kb = PresetKnowledgeStore(fileURL: nil)

        let prepared = try PreparedBook(BookManuscript(title: "ScannedSpec", chapters: [englishInitial[0]]))
        let bookA = try BookLibrary.store(prepared, in: containerA.mainContext)
        _ = try BookLibrary.store(prepared, in: containerB.mainContext)

        let enrichedZh = [
            BookChapter(title: "第 1 页", text: "Introduction to distributed storage (zh OCR pass)"),
            BookChapter(title: "第 2 页", text: "Second page progressive OCR content")
        ]
        bookA.manuscript = try BookManuscript(title: bookA.title, chapters: enrichedZh).encoded()
        bookA.chapterTitles = enrichedZh.map(\.title)
        bookA.manuscriptByteCount = bookA.manuscript.count
        try containerA.mainContext.save()

        let archiveFromA = try BackupService.makeArchive(context: containerA.mainContext, knowledgeStore: kb)
        _ = try BackupService.apply(.full(archiveFromA), to: containerB.mainContext, knowledgeStore: kb)
        let mergedBookB = try #require(try BookLibrary.find(prepared.id, in: containerB.mainContext))
        #expect(mergedBookB.chapterTitles == ["Page 1", "Page 2"])

        // Progressive OCR enrichment updates global FTS5 book search results cleanly, even after initial indexing.
        let search = ConversationHistorySearch(index: index)
        let firstBookHits = try await search.searchAll(
            for: HistorySearchQuery(text: "Second page progressive", scope: .books),
            in: containerB
        )
        #expect(firstBookHits.books.count == 1)
        #expect(firstBookHits.books.first?.chapterIndex == 1)

        let afterPage3 = BackgroundPDFOCRQueue.mergeChaptersInPageOrder(
            existing: try mergedBookB.snapshot().chapters,
            additions: [BookChapter(title: "第 3 页", text: "Third page background OCR addition")]
        )
        mergedBookB.manuscript = try BookManuscript(title: mergedBookB.title, chapters: afterPage3).encoded()
        mergedBookB.chapterTitles = afterPage3.map(\.title)
        mergedBookB.manuscriptByteCount = mergedBookB.manuscript.count
        try containerB.mainContext.save()

        let enrichedBookHits = try await search.searchAll(
            for: HistorySearchQuery(text: "Third page background", scope: .books),
            in: containerB
        )
        #expect(enrichedBookHits.books.count == 1)
        #expect(enrichedBookHits.books.first?.chapterIndex == 2)
    }
}
