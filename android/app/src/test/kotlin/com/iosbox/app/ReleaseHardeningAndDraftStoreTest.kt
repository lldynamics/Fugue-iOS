package com.iosbox.app

import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.storage.ChatDraft
import com.iosbox.app.core.storage.ChatDraftStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ReleaseHardeningAndDraftStoreTest {

    @Test
    fun draftStorePersistsAndRestoresTextAttachmentsAndQuote() {
        val dir = Files.createTempDirectory("fugue_drafts_1").toFile()
        try {
            val store = ChatDraftStore(File(dir, "drafts"))
            val attachment = MessageAttachment(
                id = "ATT-1",
                kind = AttachmentKind.DOCUMENT,
                fileName = "notes.txt",
                mimeType = "text/plain",
                extractedText = "Sample extracted content",
                byteSize = 24
            )
            val original = ChatDraft(
                text = "Draft follow-up question",
                attachments = listOf(attachment),
                quotedExcerpt = "Earlier quoted paragraph"
            )

            store.save("conv-abc-123", original)
            val reloaded = store.load("CONV-ABC-123")

            assertEquals("Draft follow-up question", reloaded.text)
            assertEquals("Earlier quoted paragraph", reloaded.quotedExcerpt)
            assertEquals(1, reloaded.attachments.size)
            assertEquals("ATT-1", reloaded.attachments[0].id)
            assertEquals("notes.txt", reloaded.attachments[0].fileName)
            assertEquals("Sample extracted content", reloaded.attachments[0].extractedText)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun draftStoreDeletesFileWhenSavedEmptyOrRemoved() {
        val dir = Files.createTempDirectory("fugue_drafts_2").toFile()
        try {
            val store = ChatDraftStore(dir)
            val draftFile = store.draftFile("conv-clear")

            store.save("conv-clear", ChatDraft(text = "Unsent text"))
            assertTrue(draftFile.exists())

            store.save("conv-clear", ChatDraft())
            assertFalse(draftFile.exists())
            assertTrue(store.load("conv-clear").isEmpty)

            store.save("conv-remove", ChatDraft(text = "Temporary", quotedExcerpt = "Quote"))
            val removeFile = store.draftFile("conv-remove")
            assertTrue(removeFile.exists())

            store.remove("conv-remove")
            assertFalse(removeFile.exists())
            val afterRemove = store.load("conv-remove")
            assertEquals("", afterRemove.text)
            assertTrue(afterRemove.attachments.isEmpty())
            assertNull(afterRemove.quotedExcerpt)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun draftStoreQuarantinesCorruptJsonWithoutCrashing() {
        val dir = Files.createTempDirectory("fugue_drafts_3").toFile()
        try {
            val store = ChatDraftStore(dir)
            val target = store.draftFile("conv-corrupt")
            target.writeText("{not-valid-json", Charsets.UTF_8)
            assertTrue(target.exists())

            val recovered = store.load("conv-corrupt")
            assertTrue(recovered.isEmpty)
            assertFalse(target.exists())

            val quarantinedFiles = dir.listFiles { _, name ->
                name.startsWith("CONV-CORRUPT.corrupt-") && name.endsWith(".json")
            }.orEmpty()
            assertEquals(1, quarantinedFiles.size)
            assertEquals("{not-valid-json", quarantinedFiles[0].readText(Charsets.UTF_8))

            // Saving a valid draft afterward works cleanly
            store.save("conv-corrupt", ChatDraft(text = "Fresh draft"))
            assertEquals("Fresh draft", store.load("conv-corrupt").text)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun draftStoreSanitizesConversationIdsAndOverwritesAtomically() {
        val dir = Files.createTempDirectory("fugue_drafts_4").toFile()
        try {
            val store = ChatDraftStore(dir)
            val maliciousId = "../../etc/passwd"
            val target = store.draftFile(maliciousId)

            assertEquals(dir.canonicalFile, target.parentFile?.canonicalFile)
            assertFalse(target.name.contains("/"))
            assertFalse(target.name.contains(".."))

            store.save(maliciousId, ChatDraft(text = "Version 1"))
            store.save(maliciousId, ChatDraft(text = "Version 2"))

            assertEquals("Version 2", store.load(maliciousId).text)
            val leftoverTmp = dir.listFiles { _, name -> name.endsWith(".tmp") }.orEmpty()
            assertTrue(leftoverTmp.isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }
}
