package com.iosbox.app.core.backup

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Byte-compatible with iOS `WebDAVShardedSyncService.swift`:
 * - Manifest magic: `IOSBOX_SHARDED_MANIFEST_V1`
 * - Blob HKDF domain: `IOSBOX_SYNC_BLOB_V1`, blob AAD: `IOSBOX_SYNC_BLOB_V1:<sha256>`
 * - Vault key fingerprint: HKDF-SHA256(masterKey, salt, "IOSBOX_VAULT_KEY_FINGERPRINT_V1", 16) hex
 * - Layout: `<dir>/<stem>.shards/manifest.enc.json` & `<dir>/<stem>.shards/blobs/<sha256>.enc.bin`
 */
object WebDAVPayloadSharder {
    const val ATTACHMENT_SHARD_THRESHOLD_BYTES: Int = 16 * 1024
    const val BLOB_SENTINEL_PREFIX: String = "\$iosbox-blob:"

    @Serializable
    data class BookBlobRef(
        val id: String,
        val title: String,
        @Serializable(with = Iso8601EpochMillisSerializer::class)
        val importedAt: Long,
        val blobHash: String,
        val byteCount: Int
    )

    @Serializable
    data class ManifestPayload(
        val corePayload: FullEncryptedPayload,
        val bookRefs: List<BookBlobRef> = emptyList(),
        val attachmentBlobSizes: Map<String, Int> = emptyMap()
    )

    data class ExtractedBundle(
        val manifest: ManifestPayload,
        val blobs: Map<String, ByteArray>
    )

    fun sha256Hex(data: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun isValidBlobHash(raw: String): Boolean =
        raw.length == 64 && raw.all { it in '0'..'9' || it in 'a'..'f' }

    fun blobHashFromSentinel(value: String?): String? {
        if (value == null || !value.startsWith(BLOB_SENTINEL_PREFIX)) return null
        val hash = value.removePrefix(BLOB_SENTINEL_PREFIX)
        return if (isValidBlobHash(hash)) hash else null
    }

    fun split(payload: FullEncryptedPayload): ExtractedBundle {
        val blobs = LinkedHashMap<String, ByteArray>()
        val bookRefs = ArrayList<BookBlobRef>()
        val attachmentSizes = LinkedHashMap<String, Int>()

        val books = payload.archive.books.orEmpty()
        for (book in books) {
            val rawChapters = BackupJson.codec.encodeToString(
                ListSerializer(BookChapterSnapshot.serializer()),
                book.chapters
            ).toByteArray(Charsets.UTF_8)
            val hash = sha256Hex(rawChapters)
            blobs[hash] = rawChapters
            bookRefs.add(
                BookBlobRef(
                    id = book.id,
                    title = book.title,
                    importedAt = book.importedAt,
                    blobHash = hash,
                    byteCount = rawChapters.size
                )
            )
        }

        fun shardAttachment(att: MessageAttachment): MessageAttachment {
            val b64 = att.dataBase64 ?: return att
            val raw = b64.toByteArray(Charsets.UTF_8)
            if (raw.size < ATTACHMENT_SHARD_THRESHOLD_BYTES || b64.startsWith(BLOB_SENTINEL_PREFIX)) {
                return att
            }
            val hash = sha256Hex(raw)
            blobs[hash] = raw
            attachmentSizes[hash] = raw.size
            return att.copy(dataBase64 = BLOB_SENTINEL_PREFIX + hash)
        }

        fun shardMetadataRevisions(meta: JsonElement?): JsonElement? {
            val obj = meta as? JsonObject ?: return meta
            val revisions = obj["revisions"] as? JsonArray ?: return meta
            var changed = false
            val newRevs = revisions.map { revEl ->
                val revObj = revEl as? JsonObject ?: return@map revEl
                val atts = revObj["attachments"] as? JsonArray ?: return@map revEl
                var revChanged = false
                val newAtts = atts.map { attEl ->
                    val attObj = attEl as? JsonObject ?: return@map attEl
                    val b64 = (attObj["dataBase64"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    if (b64 != null && !b64.startsWith(BLOB_SENTINEL_PREFIX)) {
                        val raw = b64.toByteArray(Charsets.UTF_8)
                        if (raw.size >= ATTACHMENT_SHARD_THRESHOLD_BYTES) {
                            val hash = sha256Hex(raw)
                            blobs[hash] = raw
                            attachmentSizes[hash] = raw.size
                            revChanged = true
                            changed = true
                            return@map JsonObject(attObj + ("dataBase64" to JsonPrimitive(BLOB_SENTINEL_PREFIX + hash)))
                        }
                    }
                    attEl
                }
                if (revChanged) JsonObject(revObj + ("attachments" to JsonArray(newAtts))) else revEl
            }
            return if (changed) JsonObject(obj + ("revisions" to JsonArray(newRevs))) else meta
        }

        val shardedConversations = payload.archive.conversations.map { chat ->
            chat.copy(
                messages = chat.messages.map { msg ->
                    msg.copy(
                        attachments = msg.attachments.map(::shardAttachment),
                        assistanceMetadata = shardMetadataRevisions(msg.assistanceMetadata)
                    )
                }
            )
        }

        val coreArchive = payload.archive.copy(
            books = if (books.isEmpty()) payload.archive.books else emptyList(),
            conversations = shardedConversations
        )
        return ExtractedBundle(
            manifest = ManifestPayload(
                corePayload = payload.copy(archive = coreArchive),
                bookRefs = bookRefs,
                attachmentBlobSizes = attachmentSizes
            ),
            blobs = blobs
        )
    }

    fun referencedAttachmentHashes(manifest: ManifestPayload): Set<String> {
        val hashes = LinkedHashSet<String>(manifest.attachmentBlobSizes.keys)
        for (chat in manifest.corePayload.archive.conversations) {
            for (msg in chat.messages) {
                for (att in msg.attachments) {
                    blobHashFromSentinel(att.dataBase64)?.let { hashes.add(it) }
                }
                val revisions = (msg.assistanceMetadata as? JsonObject)?.get("revisions") as? JsonArray
                if (revisions != null) {
                    for (revEl in revisions) {
                        val atts = (revEl as? JsonObject)?.get("attachments") as? JsonArray ?: continue
                        for (attEl in atts) {
                            val b64 = ((attEl as? JsonObject)?.get("dataBase64") as? JsonPrimitive)
                                ?.takeIf { it.isString }?.content
                            blobHashFromSentinel(b64)?.let { hashes.add(it) }
                        }
                    }
                }
            }
        }
        return hashes
    }

    fun reassemble(
        manifest: ManifestPayload,
        blobs: Map<String, ByteArray>,
        existingBooks: Map<String, BookVolumeSnapshot> = emptyMap()
    ): FullEncryptedPayload {
        val restoredBooks = if (manifest.bookRefs.isEmpty()) {
            manifest.corePayload.archive.books
        } else {
            manifest.bookRefs.map { ref ->
                val existing = existingBooks[ref.id.uppercase()]
                if (existing != null) {
                    existing
                } else {
                    val raw = blobs[ref.blobHash]
                    if (raw == null || sha256Hex(raw) != ref.blobHash) {
                        throw WebDAVSyncException.ShardedBlobMissing(ref.blobHash)
                    }
                    val chapters = BackupJson.codec.decodeFromString(
                        ListSerializer(BookChapterSnapshot.serializer()),
                        raw.toString(Charsets.UTF_8)
                    )
                    BookVolumeSnapshot(
                        id = ref.id,
                        title = ref.title,
                        chapters = chapters,
                        importedAt = ref.importedAt
                    )
                }
            }
        }

        fun restoreAttachment(att: MessageAttachment): MessageAttachment {
            val hash = blobHashFromSentinel(att.dataBase64) ?: return att
            val raw = blobs[hash]
            if (raw == null || sha256Hex(raw) != hash) {
                throw WebDAVSyncException.ShardedBlobMissing(hash)
            }
            return att.copy(dataBase64 = raw.toString(Charsets.UTF_8))
        }

        fun restoreMetadataRevisions(meta: JsonElement?): JsonElement? {
            val obj = meta as? JsonObject ?: return meta
            val revisions = obj["revisions"] as? JsonArray ?: return meta
            var changed = false
            val newRevs = revisions.map { revEl ->
                val revObj = revEl as? JsonObject ?: return@map revEl
                val atts = revObj["attachments"] as? JsonArray ?: return@map revEl
                var revChanged = false
                val newAtts = atts.map { attEl ->
                    val attObj = attEl as? JsonObject ?: return@map attEl
                    val b64 = (attObj["dataBase64"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    val hash = blobHashFromSentinel(b64)
                    if (hash != null) {
                        val raw = blobs[hash]
                        if (raw == null || sha256Hex(raw) != hash) {
                            throw WebDAVSyncException.ShardedBlobMissing(hash)
                        }
                        revChanged = true
                        changed = true
                        return@map JsonObject(attObj + ("dataBase64" to JsonPrimitive(raw.toString(Charsets.UTF_8))))
                    }
                    attEl
                }
                if (revChanged) JsonObject(revObj + ("attachments" to JsonArray(newAtts))) else revEl
            }
            return if (changed) JsonObject(obj + ("revisions" to JsonArray(newRevs))) else meta
        }

        val restoredConversations = manifest.corePayload.archive.conversations.map { chat ->
            chat.copy(
                messages = chat.messages.map { msg ->
                    msg.copy(
                        attachments = msg.attachments.map(::restoreAttachment),
                        assistanceMetadata = restoreMetadataRevisions(msg.assistanceMetadata)
                    )
                }
            )
        }

        return manifest.corePayload.copy(
            archive = manifest.corePayload.archive.copy(
                books = restoredBooks,
                conversations = restoredConversations
            )
        )
    }
}

object WebDAVShardCrypto {
    const val MANIFEST_MAGIC = "IOSBOX_SHARDED_MANIFEST_V1"
    const val BLOB_DOMAIN = "IOSBOX_SYNC_BLOB_V1"
    private const val FINGERPRINT_INFO = "IOSBOX_VAULT_KEY_FINGERPRINT_V1"
    private const val DEFAULT_ITERATIONS = 600_000
    private const val GCM_NONCE_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val GCM_TAG_BYTES = 16

    @Serializable
    data class ManifestEnvelope(
        val magic: String,
        val iterations: Int,
        val saltBase64: String,
        val keyFingerprint: String,
        val presentBlobs: List<String> = emptyList(),
        val combinedCiphertextBase64: String
    )

    @Serializable
    private data class MagicProbe(val magic: String)

    data class DerivedVaultKey(
        val masterKeyBytes: ByteArray,
        val salt: ByteArray,
        val saltBase64: String,
        val iterations: Int,
        val keyFingerprint: String
    )

    fun isShardedManifest(data: ByteArray): Boolean {
        if (data.isEmpty() || data.size > EncryptedBackupCrypto.MAXIMUM_FILE_BYTES) return false
        val probe = runCatching {
            BackupJson.codec.decodeFromString<MagicProbe>(data.toString(Charsets.UTF_8))
        }.getOrNull() ?: return false
        return probe.magic == MANIFEST_MAGIC
    }

    /** RFC 5869 HKDF-SHA256 matching Apple CryptoKit `HKDF<SHA256>.deriveKey` byte-for-byte. */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, outputLength: Int): ByteArray {
        val actualSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val prk = hmacSha256(actualSalt, ikm)
        val out = ByteArray(outputLength)
        var t = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < outputLength) {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val copyLen = minOf(t.size, outputLength - offset)
            System.arraycopy(t, 0, out, offset, copyLen)
            offset += copyLen
            counter++
        }
        return out
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun deriveVaultKey(
        password: String,
        salt: ByteArray? = null,
        iterations: Int = DEFAULT_ITERATIONS
    ): DerivedVaultKey {
        if (salt == null && !EncryptedBackupCrypto.isValidExportPassword(password)) {
            throw BackupException.EmptyPassword()
        }
        val resolvedSalt = salt ?: ByteArray(16).also { SecureRandom().nextBytes(it) }
        if (resolvedSalt.size < 16) throw BackupException.InvalidEnvelope()
        val masterKey = EncryptedBackupCrypto.deriveKey(password, resolvedSalt, iterations).encoded
        val fpBytes = hkdfSha256(masterKey, resolvedSalt, FINGERPRINT_INFO.toByteArray(Charsets.UTF_8), 16)
        val fingerprint = fpBytes.joinToString("") { "%02x".format(it) }
        return DerivedVaultKey(
            masterKeyBytes = masterKey,
            salt = resolvedSalt,
            saltBase64 = Base64.getEncoder().encodeToString(resolvedSalt),
            iterations = iterations,
            keyFingerprint = fingerprint
        )
    }

    fun encryptBlob(plaintext: ByteArray, hash: String, masterKeyBytes: ByteArray): ByteArray {
        if (!WebDAVPayloadSharder.isValidBlobHash(hash)) throw WebDAVSyncException.InvalidRemotePath()
        val keyBytes = hkdfSha256(
            masterKeyBytes,
            hash.toByteArray(Charsets.UTF_8),
            BLOB_DOMAIN.toByteArray(Charsets.UTF_8),
            32
        )
        val nonce = ByteArray(GCM_NONCE_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD("$BLOB_DOMAIN:$hash".toByteArray(Charsets.UTF_8))
        val ctAndTag = cipher.doFinal(plaintext)
        return ByteArray(nonce.size + ctAndTag.size).also { combined ->
            System.arraycopy(nonce, 0, combined, 0, nonce.size)
            System.arraycopy(ctAndTag, 0, combined, nonce.size, ctAndTag.size)
        }
    }

    fun decryptBlob(ciphertext: ByteArray, hash: String, masterKeyBytes: ByteArray): ByteArray {
        if (!WebDAVPayloadSharder.isValidBlobHash(hash)) throw WebDAVSyncException.InvalidRemotePath()
        if (ciphertext.size < GCM_NONCE_BYTES + GCM_TAG_BYTES) throw BackupException.WrongPasswordOrCorrupted()
        val keyBytes = hkdfSha256(
            masterKeyBytes,
            hash.toByteArray(Charsets.UTF_8),
            BLOB_DOMAIN.toByteArray(Charsets.UTF_8),
            32
        )
        val nonce = ciphertext.copyOfRange(0, GCM_NONCE_BYTES)
        val ctAndTag = ciphertext.copyOfRange(GCM_NONCE_BYTES, ciphertext.size)
        val plaintext = runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
            cipher.updateAAD("$BLOB_DOMAIN:$hash".toByteArray(Charsets.UTF_8))
            cipher.doFinal(ctAndTag)
        }.getOrElse { throw BackupException.WrongPasswordOrCorrupted() }

        if (WebDAVPayloadSharder.sha256Hex(plaintext) != hash) {
            throw BackupException.WrongPasswordOrCorrupted()
        }
        return plaintext
    }

    fun encryptManifest(
        manifest: WebDAVPayloadSharder.ManifestPayload,
        presentBlobs: List<String>,
        vaultKey: DerivedVaultKey
    ): ByteArray {
        val plaintext = BackupJson.codec.encodeToString(
            WebDAVPayloadSharder.ManifestPayload.serializer(),
            manifest
        ).toByteArray(Charsets.UTF_8)
        val nonce = ByteArray(GCM_NONCE_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(vaultKey.masterKeyBytes, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, nonce)
        )
        cipher.updateAAD(MANIFEST_MAGIC.toByteArray(Charsets.UTF_8))
        val ctAndTag = cipher.doFinal(plaintext)
        val combined = ByteArray(nonce.size + ctAndTag.size).also {
            System.arraycopy(nonce, 0, it, 0, nonce.size)
            System.arraycopy(ctAndTag, 0, it, nonce.size, ctAndTag.size)
        }
        val envelope = ManifestEnvelope(
            magic = MANIFEST_MAGIC,
            iterations = vaultKey.iterations,
            saltBase64 = vaultKey.saltBase64,
            keyFingerprint = vaultKey.keyFingerprint,
            presentBlobs = presentBlobs.toSet().sorted(),
            combinedCiphertextBase64 = Base64.getEncoder().encodeToString(combined)
        )
        return BackupJson.codec.encodeToString(ManifestEnvelope.serializer(), envelope)
            .toByteArray(Charsets.UTF_8)
    }

    fun decryptManifest(
        data: ByteArray,
        password: String
    ): Triple<WebDAVPayloadSharder.ManifestPayload, ManifestEnvelope, DerivedVaultKey> {
        EncryptedBackupCrypto.requireImportSize(data.size)
        if (password.isEmpty()) throw BackupException.WrongPasswordOrCorrupted()
        val envelope = runCatching {
            BackupJson.codec.decodeFromString<ManifestEnvelope>(data.toString(Charsets.UTF_8))
        }.getOrNull() ?: throw BackupException.InvalidEnvelope()
        if (envelope.magic != MANIFEST_MAGIC || envelope.iterations !in 10_000..2_000_000) {
            throw BackupException.InvalidEnvelope()
        }
        val salt = runCatching { Base64.getDecoder().decode(envelope.saltBase64) }.getOrNull()
            ?: throw BackupException.InvalidEnvelope()
        val combined = runCatching { Base64.getDecoder().decode(envelope.combinedCiphertextBase64) }.getOrNull()
            ?: throw BackupException.InvalidEnvelope()
        if (salt.size < 16 || combined.size < GCM_NONCE_BYTES + GCM_TAG_BYTES) {
            throw BackupException.InvalidEnvelope()
        }
        val vaultKey = deriveVaultKey(password, salt, envelope.iterations)
        val nonce = combined.copyOfRange(0, GCM_NONCE_BYTES)
        val ctAndTag = combined.copyOfRange(GCM_NONCE_BYTES, combined.size)
        val plaintext = runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(vaultKey.masterKeyBytes, "AES"),
                GCMParameterSpec(GCM_TAG_BITS, nonce)
            )
            cipher.updateAAD(MANIFEST_MAGIC.toByteArray(Charsets.UTF_8))
            cipher.doFinal(ctAndTag)
        }.getOrElse { throw BackupException.WrongPasswordOrCorrupted() }

        val manifest = runCatching {
            BackupJson.codec.decodeFromString<WebDAVPayloadSharder.ManifestPayload>(plaintext.toString(Charsets.UTF_8))
        }.getOrElse { throw BackupException.UnrecognizedFormat() }

        return Triple(manifest, envelope, vaultKey)
    }
}

data class WebDAVShardedSyncStats(
    val uploadedBlobs: Int = 0,
    val skippedUploadBlobs: Int = 0,
    val downloadedBlobs: Int = 0,
    val skippedLocalBlobs: Int = 0,
    val manifestBytes: Int = 0
) {
    val pushSummaryText: String
        get() = if (uploadedBlobs == 0 && skippedUploadBlobs == 0) {
            L10n.text("已分片同步清单。", "Synced sharded manifest.")
        } else {
            L10n.text(
                "已分片同步：新增分片 $uploadedBlobs 个，复用云端分片 $skippedUploadBlobs 个。",
                "Sharded sync: uploaded $uploadedBlobs new shards, reused $skippedUploadBlobs remote shards."
            )
        }

    val pullSummaryText: String
        get() = if (downloadedBlobs == 0 && skippedLocalBlobs == 0) {
            L10n.text("已拉取分片清单。", "Pulled sharded manifest.")
        } else {
            L10n.text(
                "已分片拉取：下载新分片 $downloadedBlobs 个，跳过本机已有分片 $skippedLocalBlobs 个。",
                "Sharded pull: downloaded $downloadedBlobs new shards, skipped $skippedLocalBlobs local shards."
            )
        }
}

data class WebDAVShardedPushResult(
    val stats: WebDAVShardedSyncStats,
    val saltBase64: String,
    val keyFingerprint: String,
    val presentBlobs: List<String>
)

data class WebDAVShardedPullResult(
    val payload: FullEncryptedPayload,
    val stats: WebDAVShardedSyncStats,
    val saltBase64: String,
    val keyFingerprint: String,
    val presentBlobs: List<String>
)

data class WebDAVOrphanGCReport(
    val scannedRemoteBlobs: Int,
    val referencedBlobs: Int,
    val orphanHashes: List<String>,
    val deletedCount: Int,
    val failedCount: Int
) {
    val summaryText: String
        get() = when {
            orphanHashes.isEmpty() -> L10n.text(
                "云端共 $scannedRemoteBlobs 个分片，全部有效，无需清理。",
                "$scannedRemoteBlobs cloud shards checked; no orphans to prune."
            )
            failedCount > 0 -> L10n.text(
                "已清理 $deletedCount 个孤儿分片，$failedCount 个失败。",
                "Pruned $deletedCount orphan shards ($failedCount failed)."
            )
            else -> L10n.text(
                "已安全清理 $deletedCount 个未引用的孤儿分片（保留 $referencedBlobs 个有效分片）。",
                "Pruned $deletedCount orphan shards ($referencedBlobs active shards kept)."
            )
        }
}

class WebDAVShardedSyncService(
    private val client: WebDAVSyncClient = WebDAVSyncClient()
) {
    companion object {
        fun shardRootPath(remotePath: String): String {
            val clean = remotePath.trim().ifEmpty { "Fugue/fugue-sync.enc.json" }
            val segments = clean.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty()) return "Fugue/fugue-sync.shards"
            var stem = segments.last()
            for (suffix in listOf(".enc.json", ".json")) {
                if (stem.lowercase().endsWith(suffix)) {
                    stem = stem.dropLast(suffix.length)
                    break
                }
            }
            if (stem.isEmpty()) stem = "fugue-sync"
            val shardDir = "$stem.shards"
            return if (segments.size <= 1) shardDir else (segments.dropLast(1) + shardDir).joinToString("/")
        }

        fun manifestPath(remotePath: String): String = "${shardRootPath(remotePath)}/manifest.enc.json"

        fun blobsDirectoryPath(remotePath: String): String = "${shardRootPath(remotePath)}/blobs"

        fun blobPath(remotePath: String, hash: String): String {
            if (!WebDAVPayloadSharder.isValidBlobHash(hash)) throw WebDAVSyncException.InvalidRemotePath()
            return "${blobsDirectoryPath(remotePath)}/$hash.enc.bin"
        }
    }

    suspend fun pushSharded(
        payload: FullEncryptedPayload,
        passphrase: String,
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String,
        knownSaltBase64: String? = null,
        knownKeyFingerprint: String? = null,
        knownRemoteBlobs: Set<String> = emptySet()
    ): WebDAVShardedPushResult = withContext(Dispatchers.IO) {
        if (!EncryptedBackupCrypto.isValidExportPassword(passphrase)) {
            throw BackupException.EmptyPassword()
        }
        val bundle = WebDAVPayloadSharder.split(payload)

        var reuseSalt: ByteArray? = null
        var usableBlobs = emptySet<String>()
        if (!knownSaltBase64.isNullOrBlank() && !knownKeyFingerprint.isNullOrBlank()) {
            val decoded = runCatching { Base64.getDecoder().decode(knownSaltBase64) }.getOrNull()
            if (decoded != null && decoded.size >= 16) {
                val probe = WebDAVShardCrypto.deriveVaultKey(passphrase, decoded)
                if (probe.keyFingerprint == knownKeyFingerprint) {
                    reuseSalt = decoded
                    usableBlobs = knownRemoteBlobs
                }
            }
        }
        val vaultKey = WebDAVShardCrypto.deriveVaultKey(passphrase, reuseSalt)
        val confirmed = LinkedHashSet<String>(usableBlobs)

        var uploaded = 0
        var skipped = 0
        val allHashes = bundle.blobs.keys.sorted()

        for (hash in allHashes) {
            if (confirmed.contains(hash)) {
                skipped++
                continue
            }
            val bPath = blobPath(remotePath, hash)
            if (reuseSalt != null && client.exists(serverUrl, bPath, username, password).getOrDefault(false)) {
                confirmed.add(hash)
                skipped++
                continue
            }
            val plaintext = bundle.blobs[hash] ?: continue
            val encrypted = WebDAVShardCrypto.encryptBlob(plaintext, hash, vaultKey.masterKeyBytes)
            client.uploadRawBytes(serverUrl, bPath, username, password, encrypted, "application/octet-stream")
                .getOrThrow()
            confirmed.add(hash)
            uploaded++
        }

        val present = allHashes.filter { confirmed.contains(it) }
        val manifestBytes = WebDAVShardCrypto.encryptManifest(bundle.manifest, present, vaultKey)
        client.uploadRawBytes(
            serverUrl,
            manifestPath(remotePath),
            username,
            password,
            manifestBytes,
            "application/json; charset=utf-8"
        ).getOrThrow()

        WebDAVShardedPushResult(
            stats = WebDAVShardedSyncStats(
                uploadedBlobs = uploaded,
                skippedUploadBlobs = skipped,
                manifestBytes = manifestBytes.size
            ),
            saltBase64 = vaultKey.saltBase64,
            keyFingerprint = vaultKey.keyFingerprint,
            presentBlobs = present
        )
    }

    suspend fun pullSharded(
        passphrase: String,
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String,
        existingBooks: Map<String, BookVolumeSnapshot> = emptyMap(),
        existingAttachmentBlobs: Map<String, ByteArray> = emptyMap()
    ): WebDAVShardedPullResult = withContext(Dispatchers.IO) {
        val manifestData = client.downloadRawBytes(serverUrl, manifestPath(remotePath), username, password).getOrThrow()
        if (!WebDAVShardCrypto.isShardedManifest(manifestData)) {
            throw WebDAVSyncException.NotEncryptedBackup()
        }
        val (manifest, envelope, vaultKey) = WebDAVShardCrypto.decryptManifest(manifestData, passphrase)

        val resolved = LinkedHashMap<String, ByteArray>(existingAttachmentBlobs)
        val needed = LinkedHashSet<String>()
        var skippedLocal = 0

        for (ref in manifest.bookRefs) {
            if (existingBooks.containsKey(ref.id.uppercase())) {
                skippedLocal++
            } else {
                needed.add(ref.blobHash)
            }
        }
        for (hash in WebDAVPayloadSharder.referencedAttachmentHashes(manifest)) {
            if (resolved.containsKey(hash)) {
                skippedLocal++
            } else {
                needed.add(hash)
            }
        }

        var downloaded = 0
        for (hash in needed.sorted()) {
            val cipherBytes = client.downloadRawBytes(
                serverUrl,
                blobPath(remotePath, hash),
                username,
                password
            ).getOrThrow()
            resolved[hash] = WebDAVShardCrypto.decryptBlob(cipherBytes, hash, vaultKey.masterKeyBytes)
            downloaded++
        }

        val fullPayload = WebDAVPayloadSharder.reassemble(manifest, resolved, existingBooks)
        WebDAVShardedPullResult(
            payload = fullPayload,
            stats = WebDAVShardedSyncStats(
                downloadedBlobs = downloaded,
                skippedLocalBlobs = skippedLocal,
                manifestBytes = manifestData.size
            ),
            saltBase64 = envelope.saltBase64,
            keyFingerprint = envelope.keyFingerprint,
            presentBlobs = envelope.presentBlobs
        )
    }

    suspend fun pruneOrphanBlobs(
        passphrase: String,
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String,
        dryRun: Boolean = false
    ): WebDAVOrphanGCReport = withContext(Dispatchers.IO) {
        val manifestData = client.downloadRawBytes(serverUrl, manifestPath(remotePath), username, password).getOrThrow()
        if (!WebDAVShardCrypto.isShardedManifest(manifestData)) {
            throw WebDAVSyncException.NotEncryptedBackup()
        }
        val (manifest, _, _) = WebDAVShardCrypto.decryptManifest(manifestData, passphrase)

        val referenced = LinkedHashSet<String>()
        manifest.bookRefs.forEach { referenced.add(it.blobHash) }
        referenced.addAll(WebDAVPayloadSharder.referencedAttachmentHashes(manifest))

        val names = client.listDirectoryFilenames(serverUrl, blobsDirectoryPath(remotePath), username, password).getOrThrow()
        val remoteHashes = names.mapNotNull { name ->
            if (!name.endsWith(".enc.bin")) return@mapNotNull null
            val hash = name.removeSuffix(".enc.bin")
            if (WebDAVPayloadSharder.isValidBlobHash(hash)) hash else null
        }

        val orphans = remoteHashes.filter { it !in referenced }.sorted()
        var deleted = 0
        var failed = 0
        if (!dryRun) {
            for (hash in orphans) {
                val res = client.deleteFile(serverUrl, blobPath(remotePath, hash), username, password)
                if (res.isSuccess) deleted++ else failed++
            }
        }
        WebDAVOrphanGCReport(
            scannedRemoteBlobs = remoteHashes.size,
            referencedBlobs = remoteHashes.size - orphans.size,
            orphanHashes = orphans,
            deletedCount = deleted,
            failedCount = failed
        )
    }
}
