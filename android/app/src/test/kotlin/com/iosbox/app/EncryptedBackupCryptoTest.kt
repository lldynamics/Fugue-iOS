package com.iosbox.app.core.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class EncryptedBackupCryptoTest {
    @Test
    fun decryptsGenuineIosCryptoKitGoldenVectorWithUnicodePassword() {
        // Generated via Swift CommonCrypto CCKeyDerivationPBKDF + Apple CryptoKit AES.GCM.seal
        // matching iOSBox/Services/EncryptedBackupService.swift byte-for-byte.
        val iosEnvelopeJson = """
            {"combinedCiphertextBase64":"kj1OR5wYmQhRmwN+O7V5YhUxs5GdhpcvXgxOqXK2itV6C+ULyr27LnUKZHAVYfjusDdT4QSWLq6HxBz9VEZMAhzzhuTRuxj1JpI7c\/mZ\/v8ae8IPNOV0DPNf0rooXW\/eECOAD0yKctYmTgYdIVMJs2IQMQcwg2C0q3IQYV+0afQGKvRUd3XbeOXE5pZ1nsK3nhmNuYgO95tLwVIflnHtc2LL4A1ZaDTS75\/Tyf4PT7QshtuoitlZ6TmxldkyBGkNgAAE3hOeeILwzQTpx9mZ5A7MsoqY11tbdNdrpBv3BsfhY0qLNgiWIAyD0T2B4d0bWxbJeienpcrY0LsoWhC2T\/cYKtmYCtobF0z4dZnp6q23knOcreVx7mfNXWkmyOairXcOZmubIVKjluNGEbJNagxDHtv9qCsAlPV4SO08qw+t8U+WEB44z+29+cqyjpljPizjvbetLoaC08\/BUR321\/kA6wszeUmRGPrJ","iterations":12000,"magic":"IOSBOX_ENCRYPTED_BACKUP_V1","saltBase64":"AQIDBAUGBwgJCgsMDQ4PEA=="}
        """.trimIndent().toByteArray(Charsets.UTF_8)

        assertTrue(EncryptedBackupCrypto.isEncryptedBackup(iosEnvelopeJson))
        val payload = EncryptedBackupCrypto.decryptPayload(iosEnvelopeJson, "夜奔TestPass#2026")

        assertEquals(7, payload.archive.formatVersion)
        assertEquals("2.0", payload.archive.appVersion)
        assertEquals(1, payload.providerSecrets.size)
        assertEquals("sk-ios-secret", payload.providerSecrets[0].apiKey)
        assertEquals("https://api.openai.com/v1", payload.providerSecrets[0].rawBaseURL)
        assertEquals("tvly-123", payload.tavilyAPIKey)
    }

    @Test
    fun roundTripEncryptDecryptAndWrongPasswordAndTrimmedFallback() {
        val payload = FullEncryptedPayload(
            archive = BackupArchive(
                formatVersion = 7,
                exportedAt = 1_795_239_000_000L,
                appVersion = "1.0.0"
            ),
            providerSecrets = listOf(
                ProviderSecretBundle(
                    providerID = "11111111-1111-4111-8111-111111111111",
                    rawBaseURL = "https://relay.example.com/custom#",
                    isEnabled = true,
                    apiKey = "sk-android-test",
                    extraAPIKeys = listOf("sk-backup-1"),
                    idleTimeoutSeconds = 90,
                    secretHeaders = mapOf("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" to "hdr-secret")
                )
            ),
            tavilyAPIKey = "tvly-android",
            personaXBearerToken = "x-bearer"
        )

        val encrypted = EncryptedBackupCrypto.encryptPayload(payload, "SecretPass#99", iterations = 10_000)
        assertTrue(EncryptedBackupCrypto.isEncryptedBackup(encrypted))

        val decrypted = EncryptedBackupCrypto.decryptPayload(encrypted, "SecretPass#99")
        assertEquals(payload.providerSecrets, decrypted.providerSecrets)
        assertEquals("tvly-android", decrypted.tavilyAPIKey)
        assertEquals("x-bearer", decrypted.personaXBearerToken)

        // Trimmed-password fallback compatibility
        val padded = EncryptedBackupCrypto.decryptPayload(encrypted, "  SecretPass#99 \n")
        assertEquals("sk-android-test", padded.providerSecrets.first().apiKey)

        // Wrong password fails
        assertThrows(BackupException.WrongPasswordOrCorrupted::class.java) {
            EncryptedBackupCrypto.decryptPayload(encrypted, "WrongPass#99")
        }

        // Plain JSON does not trigger encrypted backup detector
        assertFalse(EncryptedBackupCrypto.isEncryptedBackup("""{"formatVersion":7}""".toByteArray()))
    }
}
