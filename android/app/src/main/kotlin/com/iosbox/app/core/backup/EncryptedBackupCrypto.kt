package com.iosbox.app.core.backup

import kotlinx.serialization.Serializable
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Byte-compatible with iOS `EncryptedBackupService.swift`:
 * - Envelope magic: `IOSBOX_ENCRYPTED_BACKUP_V1`
 * - KDF: `PBKDF2WithHmacSHA256`, 600,000 iterations, 16-byte random salt, 256-bit key
 * - Cipher: `AES/GCM/NoPadding`, 12-byte random nonce, 128-bit tag, AAD = magic UTF-8 bytes
 * - Combined payload layout: `12B nonce || ciphertext || 16B GCM tag`
 */
object EncryptedBackupCrypto {
    const val ENVELOPE_MAGIC = "IOSBOX_ENCRYPTED_BACKUP_V1"
    const val MINIMUM_PASSWORD_CHARACTERS = 8
    const val DEFAULT_PBKDF2_ITERATIONS = 600_000
    const val MAXIMUM_FILE_BYTES = 256 * 1024 * 1024
    private const val GCM_NONCE_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val GCM_TAG_BYTES = 16

    @Serializable
    private data class MagicProbe(val magic: String)

    fun isValidExportPassword(password: String): Boolean =
        password.length >= MINIMUM_PASSWORD_CHARACTERS && password.trim().isNotEmpty()

    fun isEncryptedBackup(data: ByteArray): Boolean {
        if (data.isEmpty() || data.size > MAXIMUM_FILE_BYTES) return false
        val magicBytes = ENVELOPE_MAGIC.toByteArray(Charsets.UTF_8)
        val headEnd = minOf(data.size, 4096)
        val tailStart = maxOf(0, data.size - 4096)
        val hasMagicInHead = indexOfBytes(data, magicBytes, 0, headEnd) >= 0
        val hasMagicInTail = tailStart > 0 && indexOfBytes(data, magicBytes, tailStart, data.size) >= 0
        if (!hasMagicInHead && !hasMagicInTail) return false

        val text = data.toString(Charsets.UTF_8)
        val probe = runCatching { BackupJson.codec.decodeFromString<MagicProbe>(text) }.getOrNull() ?: return false
        return probe.magic == ENVELOPE_MAGIC
    }

    fun encryptPayload(
        payload: FullEncryptedPayload,
        password: String,
        iterations: Int = DEFAULT_PBKDF2_ITERATIONS
    ): ByteArray {
        if (!isValidExportPassword(password)) throw BackupException.EmptyPassword()
        val maximumPlaintext = (MAXIMUM_FILE_BYTES / 4) * 3
        val plaintext = BackupJson.codec.encodeToString(FullEncryptedPayload.serializer(), payload)
            .toByteArray(Charsets.UTF_8)
        if (plaintext.size > maximumPlaintext) throw BackupException.FileTooLarge()

        val rng = SecureRandom()
        val salt = ByteArray(16).also { rng.nextBytes(it) }
        val nonce = ByteArray(GCM_NONCE_BYTES).also { rng.nextBytes(it) }

        val key = deriveKey(password, salt, iterations)
        val aad = ENVELOPE_MAGIC.toByteArray(Charsets.UTF_8)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val ciphertextAndTag = cipher.doFinal(plaintext)

        val combined = ByteArray(nonce.size + ciphertextAndTag.size)
        System.arraycopy(nonce, 0, combined, 0, nonce.size)
        System.arraycopy(ciphertextAndTag, 0, combined, nonce.size, ciphertextAndTag.size)

        val envelope = EncryptedBackupEnvelope(
            magic = ENVELOPE_MAGIC,
            iterations = iterations,
            saltBase64 = Base64.getEncoder().encodeToString(salt),
            combinedCiphertextBase64 = Base64.getEncoder().encodeToString(combined)
        )
        val encoded = BackupJson.codec.encodeToString(EncryptedBackupEnvelope.serializer(), envelope)
            .toByteArray(Charsets.UTF_8)
        if (encoded.size > MAXIMUM_FILE_BYTES) throw BackupException.FileTooLarge()
        return encoded
    }

    fun decryptPayload(data: ByteArray, password: String): FullEncryptedPayload {
        if (data.size > MAXIMUM_FILE_BYTES) throw BackupException.FileTooLarge()
        if (password.isEmpty()) throw BackupException.WrongPasswordOrCorrupted()

        val envelope = runCatching {
            BackupJson.codec.decodeFromString<EncryptedBackupEnvelope>(data.toString(Charsets.UTF_8))
        }.getOrNull() ?: throw BackupException.InvalidEnvelope()

        if (envelope.magic != ENVELOPE_MAGIC || envelope.iterations !in 10_000..2_000_000) {
            throw BackupException.InvalidEnvelope()
        }
        val salt = runCatching { Base64.getDecoder().decode(envelope.saltBase64) }.getOrNull()
            ?: throw BackupException.InvalidEnvelope()
        val combined = runCatching { Base64.getDecoder().decode(envelope.combinedCiphertextBase64) }.getOrNull()
            ?: throw BackupException.InvalidEnvelope()
        if (salt.size < 16 || combined.size < GCM_NONCE_BYTES + GCM_TAG_BYTES) {
            throw BackupException.InvalidEnvelope()
        }

        val nonce = combined.copyOfRange(0, GCM_NONCE_BYTES)
        val cipherAndTag = combined.copyOfRange(GCM_NONCE_BYTES, combined.size)
        val aad = ENVELOPE_MAGIC.toByteArray(Charsets.UTF_8)

        val plaintext = tryOpen(password, salt, envelope.iterations, nonce, cipherAndTag, aad)
            ?: run {
                val trimmed = password.trim()
                if (trimmed != password && trimmed.isNotEmpty()) {
                    tryOpen(trimmed, salt, envelope.iterations, nonce, cipherAndTag, aad)
                } else {
                    null
                }
            }
            ?: throw BackupException.WrongPasswordOrCorrupted()

        return runCatching {
            BackupJson.codec.decodeFromString<FullEncryptedPayload>(plaintext.toString(Charsets.UTF_8))
        }.getOrElse {
            throw BackupException.UnrecognizedFormat()
        }
    }

    private fun tryOpen(
        password: String,
        salt: ByteArray,
        iterations: Int,
        nonce: ByteArray,
        cipherAndTag: ByteArray,
        aad: ByteArray
    ): ByteArray? = runCatching {
        val key = deriveKey(password, salt, iterations)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        cipher.doFinal(cipherAndTag)
    }.getOrNull()

    fun deriveKey(password: String, salt: ByteArray, iterations: Int): SecretKeySpec {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, 256)
        return try {
            val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
        } finally {
            spec.clearPassword()
        }
    }

    private fun indexOfBytes(haystack: ByteArray, needle: ByteArray, from: Int, to: Int): Int {
        if (needle.isEmpty() || to - from < needle.size) return -1
        outer@ for (i in from..(to - needle.size)) {
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}
