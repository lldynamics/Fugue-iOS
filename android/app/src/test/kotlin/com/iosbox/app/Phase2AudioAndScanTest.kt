package com.iosbox.app

import com.iosbox.app.core.system.AudioMeteringNormalizer
import com.iosbox.app.core.system.DocumentScanFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Phase2AudioAndScanTest {

    @Test
    fun audioMeteringNormalizerMapsDecibelsAndAmplitudesWithinBounds() {
        assertEquals(0.08f, AudioMeteringNormalizer.normalizeDecibels(-100f), 0.001f)
        assertEquals(0.08f, AudioMeteringNormalizer.normalizeDecibels(Float.NaN), 0.001f)
        assertEquals(1.0f, AudioMeteringNormalizer.normalizeDecibels(0f), 0.001f)

        assertEquals(0.08f, AudioMeteringNormalizer.normalizeAmplitude(0), 0.001f)
        assertEquals(1.0f, AudioMeteringNormalizer.normalizeAmplitude(32_767), 0.001f)

        val quiet = AudioMeteringNormalizer.normalizeAmplitude(500)
        val medium = AudioMeteringNormalizer.normalizeAmplitude(4_000)
        val loud = AudioMeteringNormalizer.normalizeAmplitude(24_000)
        assertTrue(medium > quiet)
        assertTrue(loud > medium)

        var history = emptyList<Float>()
        for (i in 1..48) {
            history = AudioMeteringNormalizer.appendSample(i / 48f, history)
        }
        assertEquals(AudioMeteringNormalizer.MAX_SAMPLES, history.size)
        assertEquals(13f / 48f, history.first(), 0.001f)
        assertEquals(1.0f, history.last(), 0.001f)
    }

    @Test
    fun documentScanFilterWhitesOutPaperAndDeepensInk() {
        val offWhitePaper = (0xFF shl 24) or (215 shl 16) or (210 shl 8) or 205
        val enhancedPaper = DocumentScanFilter.enhancePixelLuma(offWhitePaper)
        assertEquals(0xFFFFFFFF.toInt(), enhancedPaper)

        val darkInk = (0x80 shl 24) or (30 shl 16) or (30 shl 8) or 35
        val enhancedInk = DocumentScanFilter.enhancePixelLuma(darkInk)
        assertEquals(0x80, (enhancedInk ushr 24) and 0xFF)
        val r = (enhancedInk ushr 16) and 0xFF
        val g = (enhancedInk ushr 8) and 0xFF
        val b = enhancedInk and 0xFF
        assertEquals(r, g)
        assertEquals(g, b)
        assertTrue(r <= 24)

        var prev = -1
        for (luma in 0..255) {
            val mapped = DocumentScanFilter.enhanceLumaScalar(luma)
            assertTrue(mapped in 0..255)
            assertTrue(mapped >= prev)
            prev = mapped
        }
    }

    @Test
    fun documentScanPromptAvoidsDuplicationAndPreservesUserDraft() {
        val blankPrompt = DocumentScanFilter.buildDocumentScanPrompt("   ")
        assertTrue(blankPrompt.isNotBlank())

        val combined = DocumentScanFilter.buildDocumentScanPrompt("重点核对发票金额")
        assertTrue(combined.contains("重点核对发票金额"))
        assertTrue(combined.contains(blankPrompt))

        val idempotent = DocumentScanFilter.buildDocumentScanPrompt(combined)
        assertEquals(combined, idempotent)
    }
}
