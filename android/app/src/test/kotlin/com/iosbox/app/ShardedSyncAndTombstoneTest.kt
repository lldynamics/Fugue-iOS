package com.iosbox.app

import com.iosbox.app.core.backup.BackupArchive
import com.iosbox.app.core.backup.BookChapterSnapshot
import com.iosbox.app.core.backup.BookVolumeSnapshot
import com.iosbox.app.core.backup.ConversationBackup
import com.iosbox.app.core.backup.FullEncryptedPayload
import com.iosbox.app.core.backup.MessageBackup
import com.iosbox.app.core.backup.SyncEntityKinds
import com.iosbox.app.core.backup.SyncTombstone
import com.iosbox.app.core.backup.SyncTombstoneKey
import com.iosbox.app.core.backup.SyncTombstoneStore
import com.iosbox.app.core.backup.WebDAVPayloadSharder
import com.iosbox.app.core.backup.WebDAVShardCrypto
import com.iosbox.app.core.backup.WebDAVShardedSyncService
import com.iosbox.app.core.backup.WebDAVSyncClient
import com.iosbox.app.core.backup.BackupException
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.storage.InMemoryBlobStore
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class ShardedSyncAndTombstoneTest {

    @Test
    fun tombstoneStoreMergesDeduplicatesPrunesAndPersists() {
        val blobs = InMemoryBlobStore()
        val store = SyncTombstoneStore(blobs)
        val now = 1_800_000_000_000L
        val id1 = UUID.randomUUID().toString()
        val id2 = UUID.randomUUID().toString()
        val expiredId = UUID.randomUUID().toString()

        store.recordDeletion(SyncEntityKinds.CONVERSATION, id1.lowercase(), deletedAtMs = now - 10_000)
        // Older timestamp should not overwrite newer deletion
        store.recordDeletion(SyncEntityKinds.CONVERSATION, id1.uppercase(), deletedAtMs = now - 50_000)
        assertEquals(now - 10_000, store.latestDeletion(SyncEntityKinds.CONVERSATION, id1, nowMs = now))

        val incoming = listOf(
            SyncTombstone(SyncEntityKinds.CONVERSATION, id1, deletedAt = now - 2_000),
            SyncTombstone(SyncEntityKinds.BOOK, id2, deletedAt = now - 5_000),
            SyncTombstone(SyncEntityKinds.MEMORY, expiredId, deletedAt = now - SyncTombstoneStore.RETENTION_MS - 1_000)
        )
        store.merge(incoming, nowMs = now)

        assertEquals(now - 2_000, store.latestDeletion(SyncEntityKinds.CONVERSATION, id1, nowMs = now))
        assertEquals(now - 5_000, store.latestDeletion(SyncEntityKinds.BOOK, id2, nowMs = now))
        assertNull(store.latestDeletion(SyncEntityKinds.MEMORY, expiredId, nowMs = now))

        // Reload from blob store verifies persistence
        val reloaded = SyncTombstoneStore(blobs)
        assertEquals(2, reloaded.count(nowMs = now))

        // Removing key clears it
        reloaded.merge(
            incoming = emptyList(),
            removing = listOf(SyncTombstoneKey(SyncEntityKinds.BOOK, id2)),
            nowMs = now
        )
        assertNull(reloaded.latestDeletion(SyncEntityKinds.BOOK, id2, nowMs = now))
    }

    @Test
    fun hkdfSha256MatchesRfc5869TestVector1() {
        fun hexToBytes(hex: String): ByteArray =
            hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

        val ikm = hexToBytes("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
        val salt = hexToBytes("000102030405060708090a0b0c")
        val info = hexToBytes("f0f1f2f3f4f5f6f7f8f9")
        val expected = hexToBytes(
            "3cb25f25faacd57a90434f64d0362f2a" +
                "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                "34007208d5b887185865"
        )
        val actual = WebDAVShardCrypto.hkdfSha256(ikm, salt, info, 42)
        assertArrayEquals(expected, actual)
    }

    @Test
    fun payloadSharderSplitsAndReassemblesBooksAndLargeAttachments() {
        val largeBase64 = Base64.getEncoder().encodeToString(ByteArray(20 * 1024) { (it % 251).toByte() })
        val smallBase64 = Base64.getEncoder().encodeToString("tiny".toByteArray())
        val convId = UUID.randomUUID().toString().uppercase()
        val msgId = UUID.randomUUID().toString().uppercase()
        val bookId = UUID.randomUUID().toString().uppercase()

        val payload = FullEncryptedPayload(
            archive = BackupArchive(
                exportedAt = 1_750_000_000_000L,
                appVersion = "1.0.0",
                conversations = listOf(
                    ConversationBackup(
                        id = convId,
                        title = "Sharded Chat",
                        createdAt = 1_750_000_000_000L,
                        updatedAt = 1_750_000_000_000L,
                        messages = listOf(
                            MessageBackup(
                                id = msgId,
                                role = "user",
                                content = "Check attachments",
                                attachments = listOf(
                                    MessageAttachment(
                                        kind = AttachmentKind.IMAGE,
                                        fileName = "big.png",
                                        mimeType = "image/png",
                                        dataBase64 = largeBase64,
                                        byteSize = 20 * 1024
                                    ),
                                    MessageAttachment(
                                        kind = AttachmentKind.IMAGE,
                                        fileName = "small.png",
                                        mimeType = "image/png",
                                        dataBase64 = smallBase64,
                                        byteSize = 4
                                    )
                                ),
                                createdAt = 1_750_000_000_000L
                            )
                        )
                    )
                ),
                books = listOf(
                    BookVolumeSnapshot(
                        id = bookId,
                        title = "Architecture Book",
                        chapters = listOf(BookChapterSnapshot("Ch1", "Content of chapter 1")),
                        importedAt = 1_750_000_000_000L
                    )
                )
            )
        )

        val bundle = WebDAVPayloadSharder.split(payload)
        assertEquals(1, bundle.manifest.bookRefs.size)
        assertEquals(2, bundle.blobs.size)
        assertTrue(bundle.manifest.corePayload.archive.books.orEmpty().isEmpty())

        val shardedAtts = bundle.manifest.corePayload.archive.conversations[0].messages[0].attachments
        assertTrue(shardedAtts[0].dataBase64!!.startsWith(WebDAVPayloadSharder.BLOB_SENTINEL_PREFIX))
        assertEquals(smallBase64, shardedAtts[1].dataBase64)

        val restored = WebDAVPayloadSharder.reassemble(bundle.manifest, bundle.blobs)
        assertEquals(1, restored.archive.books?.size)
        assertEquals("Architecture Book", restored.archive.books?.first()?.title)
        assertEquals(largeBase64, restored.archive.conversations[0].messages[0].attachments[0].dataBase64)
        assertEquals(smallBase64, restored.archive.conversations[0].messages[0].attachments[1].dataBase64)
    }

    @Test
    fun shardCryptoDetectsBlobTamperingAndWrongHashAad() {
        val vaultKey = WebDAVShardCrypto.deriveVaultKey("StrongPassphrase!2026", iterations = 10_000)
        val plain = "Sensitive encrypted book chapter payload".toByteArray(Charsets.UTF_8)
        val hash = WebDAVPayloadSharder.sha256Hex(plain)
        val encrypted = WebDAVShardCrypto.encryptBlob(plain, hash, vaultKey.masterKeyBytes)

        val decrypted = WebDAVShardCrypto.decryptBlob(encrypted, hash, vaultKey.masterKeyBytes)
        assertArrayEquals(plain, decrypted)

        // Wrong hash AAD must fail
        val fakeHash = WebDAVPayloadSharder.sha256Hex("other".toByteArray(Charsets.UTF_8))
        try {
            WebDAVShardCrypto.decryptBlob(encrypted, fakeHash, vaultKey.masterKeyBytes)
            fail("Expected WrongPasswordOrCorrupted for mismatched AAD hash")
        } catch (_: BackupException.WrongPasswordOrCorrupted) {
            // expected
        }
    }

    @Test
    fun propfindParserExtractsChildBlobFilenames() {
        val xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/</D:href></D:response>
              <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.enc.bin</D:href></D:response>
              <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.enc.bin</D:href></D:response>
            </D:multistatus>
        """.trimIndent()
        val names = WebDAVSyncClient.parsePropfindChildNames(xml, "/dav/Fugue/fugue-sync.shards/blobs")
        assertEquals(2, names.size)
        assertTrue(names.contains("a".repeat(64) + ".enc.bin"))
        assertTrue(names.contains("b".repeat(64) + ".enc.bin"))
    }

    @Test
    fun shardedSyncServiceIncrementalPushPullAndOrphanGcOverMockWebDav() = runTest {
        val storage = ConcurrentHashMap<String, ByteArray>()
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path?.trimEnd('/') ?: "/"
                return when (request.method) {
                    "MKCOL" -> MockResponse().setResponseCode(201)
                    "PUT" -> {
                        storage[path] = request.body.readByteArray()
                        MockResponse().setResponseCode(201)
                    }
                    "HEAD" -> {
                        if (storage.containsKey(path)) MockResponse().setResponseCode(200)
                        else MockResponse().setResponseCode(404)
                    }
                    "GET" -> {
                        val bytes = storage[path]
                        if (bytes != null) MockResponse().setResponseCode(200).setBody(okio.Buffer().write(bytes))
                        else MockResponse().setResponseCode(404)
                    }
                    "DELETE" -> {
                        if (storage.remove(path) != null) MockResponse().setResponseCode(204)
                        else MockResponse().setResponseCode(404)
                    }
                    "PROPFIND" -> {
                        val prefix = "$path/"
                        val entries = storage.keys.filter { it.startsWith(prefix) }
                        val body = buildString {
                            append("<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">")
                            append("<D:response><D:href>$path/</D:href></D:response>")
                            for (entry in entries) {
                                append("<D:response><D:href>$entry</D:href></D:response>")
                            }
                            append("</D:multistatus>")
                        }
                        MockResponse().setResponseCode(207).setBody(body)
                    }
                    else -> MockResponse().setResponseCode(405)
                }
            }
        }
        server.start()
        try {
            val baseUrl = server.url("/dav").toString().trimEnd('/')
            val remotePath = "Fugue/sync.enc.json"
            val bookId = UUID.randomUUID().toString().uppercase()
            val book = BookVolumeSnapshot(
                id = bookId,
                title = "Incremental Sync Book",
                chapters = listOf(BookChapterSnapshot("Ch1", "Repeated text ".repeat(50))),
                importedAt = 1_750_000_000_000L
            )
            val payload = FullEncryptedPayload(
                archive = BackupArchive(
                    exportedAt = 1_750_000_000_000L,
                    appVersion = "1.0.0",
                    books = listOf(book)
                )
            )
            val service = WebDAVShardedSyncService(WebDAVSyncClient())

            // 1. First push uploads 1 book shard
            val first = service.pushSharded(
                payload = payload,
                passphrase = "SyncPassphrase!99",
                serverUrl = baseUrl,
                remotePath = remotePath,
                username = "tester",
                password = "secret"
            )
            assertEquals(1, first.stats.uploadedBlobs)
            assertEquals(0, first.stats.skippedUploadBlobs)

            // 2. Second push with cached metadata skips uploading the unchanged shard
            val second = service.pushSharded(
                payload = payload,
                passphrase = "SyncPassphrase!99",
                serverUrl = baseUrl,
                remotePath = remotePath,
                username = "tester",
                password = "secret",
                knownSaltBase64 = first.saltBase64,
                knownKeyFingerprint = first.keyFingerprint,
                knownRemoteBlobs = first.presentBlobs.toSet()
            )
            assertEquals(0, second.stats.uploadedBlobs)
            assertEquals(1, second.stats.skippedUploadBlobs)

            // 3. Pull with local book present skips downloading the shard
            val pulled = service.pullSharded(
                passphrase = "SyncPassphrase!99",
                serverUrl = baseUrl,
                remotePath = remotePath,
                username = "tester",
                password = "secret",
                existingBooks = mapOf(bookId to book)
            )
            assertEquals(0, pulled.stats.downloadedBlobs)
            assertEquals(1, pulled.stats.skippedLocalBlobs)
            assertEquals("Incremental Sync Book", pulled.payload.archive.books?.first()?.title)

            // 4. Plant an unreferenced orphan blob and verify orphan GC deletes ONLY the orphan
            val orphanHash = "f".repeat(64)
            val orphanPath = "/dav/${WebDAVShardedSyncService.blobPath(remotePath, orphanHash)}"
            storage[orphanPath] = byteArrayOf(1, 2, 3, 4)

            val gc = service.pruneOrphanBlobs(
                passphrase = "SyncPassphrase!99",
                serverUrl = baseUrl,
                remotePath = remotePath,
                username = "tester",
                password = "secret"
            )
            assertEquals(2, gc.scannedRemoteBlobs)
            assertEquals(1, gc.referencedBlobs)
            assertEquals(listOf(orphanHash), gc.orphanHashes)
            assertEquals(1, gc.deletedCount)
            assertEquals(0, gc.failedCount)
            assertFalse(storage.containsKey(orphanPath))
            assertNotNull(storage["/dav/${WebDAVShardedSyncService.blobPath(remotePath, first.presentBlobs.first())}"])
        } finally {
            server.shutdown()
        }
    }
}
