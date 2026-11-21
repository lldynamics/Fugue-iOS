package com.iosbox.app.core.storage

import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookExcerpt
import com.iosbox.app.core.model.BookFriend
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.BookReplyEvidence
import com.iosbox.app.core.model.KnowledgeEvidence
import com.iosbox.app.core.model.KnowledgePassage
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.network.PersonaMaterials
import kotlin.math.ln

data class KnowledgeDocumentInput(
    val id: String,
    val title: String,
    val chaptersProvider: () -> List<BookChapter>
)

object ProjectKnowledgeSearch {
    private const val MAX_CACHED_VOLUMES = 24
    private const val CHUNK_SIZE = 460
    private const val CHUNK_OVERLAP = 70

    private data class Chunk(
        val volumeID: String,
        val documentTitle: String,
        val sectionIndex: Int,
        val sectionTitle: String,
        val text: String,
        val utf16Offset: Int
    )

    private val lock = Any()
    private val chunkCache = LinkedHashMap<String, List<Chunk>>(16, 0.75f, true)

    fun invalidate(volumeID: String) {
        val key = volumeID.uppercase()
        synchronized(lock) {
            chunkCache.remove(key)
        }
    }

    fun clearForTesting() {
        synchronized(lock) {
            chunkCache.clear()
        }
    }

    fun retrieve(
        documents: List<KnowledgeDocumentInput>,
        query: String,
        maxPassages: Int = 5,
        chapterLimits: Map<String, Int> = emptyMap()
    ): KnowledgeEvidence {
        val cleanQuery = query.trim()
        if (maxPassages <= 0 || documents.isEmpty() || cleanQuery.none { it.isLetterOrDigit() }) {
            return KnowledgeEvidence(query = cleanQuery, passages = emptyList())
        }

        val normalizedLimits = HashMap<String, Int>(chapterLimits.size)
        for ((k, v) in chapterLimits) {
            normalizedLimits[k.uppercase()] = v
        }

        val allChunks = mutableListOf<Chunk>()
        for (doc in documents) {
            val key = doc.id.uppercase()
            val docChunks = getOrBuildChunks(key, doc.title, doc.chaptersProvider)
            val limit = normalizedLimits[key]
            if (limit != null) {
                docChunks.filterTo(allChunks) { it.sectionIndex <= limit }
            } else {
                allChunks.addAll(docChunks)
            }
        }

        if (allChunks.isEmpty()) {
            return KnowledgeEvidence(query = cleanQuery, passages = emptyList())
        }

        val searchText = cleanQuery.takeLast(450)
        val idRegex = identifierPattern(searchText)
        val terms = if (cleanQuery.length == 1) {
            listOf(cleanQuery.lowercase())
        } else {
            PersonaMaterials.terms(searchText).sorted().take(32)
        }
        val phrase = cleanQuery.takeLast(120).trim()

        val termDocFreq = HashMap<String, Int>()
        if (terms.isNotEmpty()) {
            for (chunk in allChunks) {
                for (term in terms) {
                    if (chunk.text.contains(term, ignoreCase = true)) {
                        termDocFreq[term] = (termDocFreq[term] ?: 0) + 1
                    }
                }
            }
        }

        val totalChunks = allChunks.size.coerceAtLeast(1).toDouble()
        val scores = DoubleArray(allChunks.size)

        for (i in allChunks.indices) {
            val chunk = allChunks[i]
            var score = 0.0
            if (idRegex != null) {
                if (idRegex.containsMatchIn(chunk.text)) score += 6.0
                if (idRegex.containsMatchIn(chunk.sectionTitle)) score += 2.0
                if (idRegex.containsMatchIn(chunk.documentTitle)) score += 1.0
                if (score <= 0.0) continue
            }

            if (phrase.length >= 4 && chunk.text.contains(phrase, ignoreCase = true)) {
                score += 8.0
            }

            for (term in terms) {
                if (chunk.text.contains(term, ignoreCase = true)) {
                    val df = (termDocFreq[term] ?: 1).coerceAtLeast(1).toDouble()
                    val idf = 1.0 + ln((totalChunks / df).coerceAtLeast(1.0))
                    score += 2.5 * idf
                }
                if (chunk.sectionTitle.contains(term, ignoreCase = true)) {
                    score += 2.0
                }
            }
            scores[i] = score
        }

        val targetCount = minOf(maxPassages, allChunks.size)
        val chosen = mutableListOf<KnowledgePassage>()
        val usedIndices = HashSet<Int>()
        val usedSections = HashSet<String>()
        val usedDocuments = HashSet<String>()

        while (chosen.size < targetCount) {
            var bestIdx = -1
            var bestVal = -1.0
            for (i in allChunks.indices) {
                if (scores[i] <= 0.0 || usedIndices.contains(i)) continue
                val c = allChunks[i]
                val docKey = c.volumeID.uppercase()
                val sectionKey = "$docKey:${c.sectionIndex}"
                val docBonus = if (usedDocuments.contains(docKey)) 0.0 else 1.4
                val secBonus = if (usedSections.contains(sectionKey)) 0.0 else 0.8
                val score = scores[i] + docBonus + secBonus
                if (score > bestVal) {
                    bestVal = score
                    bestIdx = i
                }
            }
            if (bestIdx < 0) break
            usedIndices.add(bestIdx)
            val winner = allChunks[bestIdx]
            usedDocuments.add(winner.volumeID.uppercase())
            usedSections.add("${winner.volumeID.uppercase()}:${winner.sectionIndex}")
            chosen.add(
                KnowledgePassage(
                    id = chosen.size + 1,
                    volumeID = winner.volumeID.uppercase(),
                    documentTitle = winner.documentTitle,
                    sectionTitle = winner.sectionTitle,
                    excerpt = winner.text,
                    chapterIndex = winner.sectionIndex,
                    utf16Offset = winner.utf16Offset
                )
            )
        }

        return KnowledgeEvidence(query = cleanQuery, passages = chosen)
    }

    private fun getOrBuildChunks(
        volumeID: String,
        documentTitle: String,
        chaptersProvider: () -> List<BookChapter>
    ): List<Chunk> {
        synchronized(lock) {
            chunkCache[volumeID]?.let { return it }
        }
        val built = buildChunks(volumeID, documentTitle, chaptersProvider())
        synchronized(lock) {
            chunkCache[volumeID] = built
            while (chunkCache.size > MAX_CACHED_VOLUMES) {
                val eldestKey = chunkCache.keys.firstOrNull() ?: break
                chunkCache.remove(eldestKey)
            }
        }
        return built
    }

    private fun buildChunks(
        volumeID: String,
        documentTitle: String,
        chapters: List<BookChapter>
    ): List<Chunk> {
        val chunks = mutableListOf<Chunk>()
        chapters.forEachIndexed { secIdx, chapter ->
            val raw = chapter.text
            var start = 0
            while (start < raw.length && raw[start].isWhitespace()) start++
            var end = raw.length
            while (end > start && raw[end - 1].isWhitespace()) end--
            if (start >= end) return@forEachIndexed

            var cursor = start
            while (cursor < end) {
                val sliceEnd = minOf(end, cursor + CHUNK_SIZE)
                var bodyStart = cursor
                while (bodyStart < sliceEnd && raw[bodyStart].isWhitespace()) bodyStart++
                var bodyEnd = sliceEnd
                while (bodyEnd > bodyStart && raw[bodyEnd - 1].isWhitespace()) bodyEnd--
                if (bodyStart < bodyEnd) {
                    chunks.add(
                        Chunk(
                            volumeID = volumeID.uppercase(),
                            documentTitle = documentTitle,
                            sectionIndex = secIdx,
                            sectionTitle = chapter.title,
                            text = raw.substring(bodyStart, bodyEnd),
                            utf16Offset = bodyStart
                        )
                    )
                }
                if (sliceEnd >= end) break
                cursor = (sliceEnd - CHUNK_OVERLAP).coerceAtLeast(cursor + 1)
            }
        }
        return chunks
    }

    private fun identifierPattern(query: String): Regex? {
        val tokens = query.split(Regex("[^A-Za-z0-9._-]+"))
            .map { it.trim('-', '_', '.') }
            .filter { token -> token.any { it.isLetter() } && token.any { it.isDigit() } }
        if (tokens.isEmpty()) return null
        val joined = tokens.joinToString("|") { Regex.escape(it) }
        val pattern = "(?<![a-zA-Z0-9])(?<![a-zA-Z0-9][-_.])(?:$joined)(?![a-zA-Z0-9]|[-_.][a-zA-Z0-9])"
        return runCatching { Regex(pattern, RegexOption.IGNORE_CASE) }.getOrNull()
    }
}

object BookReferenceSearch {
    private data class Scene(
        val excerpt: BookExcerpt,
        val voiced: Boolean,
        val chapterIndex: Int
    )

    private const val MAX_SCENE_CHARS = 420
    private const val SCENE_OVERLAP = 62
    private val dialogueOpeners = setOf('“', '「', '『', '"', '—')

    fun reference(
        friend: BookFriend,
        chapters: List<BookChapter>,
        question: String
    ): BookReplyEvidence {
        val scenes = buildScenes(chapters, friend)
        if (scenes.isEmpty()) {
            throw BookImportError.NoMatches()
        }

        val nameTerms = (listOf(friend.name) + friend.aliases)
            .flatMap { PersonaMaterials.terms(it) }
            .toSet()
        val questionTerms = PersonaMaterials.terms(question.trim().takeLast(400))
            .minus(nameTerms)
            .sorted()
            .take(28)

        val scores = DoubleArray(scenes.size)
        for (i in scenes.indices) {
            val scene = scenes[i]
            var score = if (scene.voiced) 1.0 else 0.0
            for (term in questionTerms) {
                if (scene.excerpt.text.contains(term, ignoreCase = true)) {
                    score += 4.0
                }
            }
            scores[i] = score
        }

        val target = minOf(3, scenes.size)
        val chosen = mutableListOf<BookExcerpt>()
        val usedChapters = HashSet<Int>()
        val usedIndices = HashSet<Int>()

        while (chosen.size < target) {
            var bestIdx = -1
            var bestVal = -1.0
            for (i in scores.indices) {
                if (usedIndices.contains(i)) continue
                val value = scores[i] * 2.0 + if (usedChapters.contains(scenes[i].chapterIndex)) 0.0 else 1.0
                if (value > bestVal) {
                    bestVal = value
                    bestIdx = i
                }
            }
            if (bestIdx < 0) break
            usedIndices.add(bestIdx)
            usedChapters.add(scenes[bestIdx].chapterIndex)
            chosen.add(scenes[bestIdx].excerpt)
        }

        return BookReplyEvidence(
            name = friend.name,
            title = friend.bookTitle,
            excerpts = chosen
        )
    }

    private fun buildScenes(chapters: List<BookChapter>, friend: BookFriend): List<Scene> {
        val names = (listOf(friend.name) + friend.aliases)
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.length <= 60 }
            .take(9)
        if (names.isEmpty()) throw BookImportError.Name()

        val alternatives = names.joinToString("|") { name ->
            val literal = Regex.escape(name)
            val isAsciiOnly = name.all { it.code < 128 }
            if (isAsciiOnly) "(?<![A-Za-z0-9_])$literal(?![A-Za-z0-9_])" else literal
        }
        val person = "(?:$alternatives)"
        val mentionedRegex = Regex(person, RegexOption.IGNORE_CASE)
        val speechRegex = Regex(
            person + """(?:[：:]|[，,\s]*(?:(?:低声|轻声|笑着|轻轻|又)?[说问答道喊]|said\b|asked\b|replied\b))""",
            RegexOption.IGNORE_CASE
        )

        val last = friend.throughChapter ?: chapters.lastIndex
        if (last !in chapters.indices) throw BookImportError.InvalidBook()

        val scenes = mutableListOf<Scene>()
        for (chapterIdx in 0..last) {
            val raw = chapters[chapterIdx].text
            val lines = splitLinesWithOffsets(raw)
            for (lineIdx in lines.indices) {
                val line = lines[lineIdx]
                var localStart = 0
                while (localStart < line.text.length) {
                    val localEnd = minOf(line.text.length, localStart + MAX_SCENE_CHARS)
                    val isCompleteLine = localEnd == line.text.length
                    val rawSlice = line.text.substring(localStart, localEnd)
                    val leadingWs = rawSlice.indexOfFirst { !it.isWhitespace() }.let { if (it < 0) rawSlice.length else it }
                    val body = rawSlice.trim()
                    if (body.isNotEmpty() && mentionedRegex.containsMatchIn(body)) {
                        var excerpt = body
                        if (isCompleteLine && body.length < 230 && lineIdx + 1 < lines.size) {
                            val nextTrimmed = lines[lineIdx + 1].text.trim()
                            val firstChar = nextTrimmed.firstOrNull()
                            if (firstChar != null && dialogueOpeners.contains(firstChar)) {
                                val remaining = MAX_SCENE_CHARS - body.length - 1
                                if (remaining > 0) {
                                    excerpt += "\n" + nextTrimmed.take(remaining)
                                }
                            }
                        }
                        scenes.add(
                            Scene(
                                excerpt = BookExcerpt(
                                    id = scenes.size,
                                    chapter = chapters[chapterIdx].title,
                                    text = excerpt,
                                    chapterIndex = chapterIdx,
                                    utf16Offset = line.startOffset + localStart + leadingWs
                                ),
                                voiced = speechRegex.containsMatchIn(body),
                                chapterIndex = chapterIdx
                            )
                        )
                    }
                    if (isCompleteLine) break
                    localStart = (localEnd - SCENE_OVERLAP).coerceAtLeast(localStart + 1)
                }
            }
        }
        return scenes
    }
}

data class BookReadingPage(
    val chapterIndex: Int,
    val paragraphs: List<Paragraph>,
    val located: Boolean
) {
    data class Paragraph(
        val id: Int,
        val text: String,
        val highlightRange: IntRange?,
        val endsCitation: Boolean
    )

    fun clampedParagraph(preferred: Int?): Int {
        val lastId = paragraphs.lastOrNull()?.id ?: 0
        return (preferred ?: 0).coerceIn(0, lastId)
    }

    companion object {
        private const val PARAGRAPH_CHUNK = 720

        fun chaptersThrough(chapters: List<BookChapter>, limit: Int?): List<BookChapter> {
            if (chapters.isEmpty()) throw BookImportError.InvalidBook()
            if (limit != null) {
                if (limit !in chapters.indices) throw BookImportError.InvalidBook()
                return chapters.take(limit + 1)
            }
            return chapters
        }

        fun make(
            chapters: List<BookChapter>,
            preferredChapter: Int,
            citation: ReadingCitation?
        ): BookReadingPage {
            if (chapters.isEmpty()) throw BookImportError.InvalidBook()
            var index = preferredChapter.coerceIn(0, chapters.lastIndex)
            val match = citation?.let { locate(it, chapters) }
            if (match != null) {
                index = match.chapter
            }

            val source = chapters[index].text
            val paragraphs = mutableListOf<Paragraph>()
            val lines = splitLinesWithOffsets(source)
            for (line in lines) {
                var offset = 0
                while (offset < line.text.length) {
                    val end = minOf(line.text.length, offset + PARAGRAPH_CHUNK)
                    val pText = line.text.substring(offset, end)
                    val absStart = line.startOffset + offset
                    val absEndExclusive = absStart + pText.length
                    var localRange: IntRange? = null
                    var endsCitation = false
                    if (match != null) {
                        val overlapStart = maxOf(match.range.first, absStart)
                        val overlapEndExclusive = minOf(match.range.last + 1, absEndExclusive)
                        if (overlapStart < overlapEndExclusive) {
                            localRange = (overlapStart - absStart) until (overlapEndExclusive - absStart)
                            endsCitation = (match.range.last + 1) <= absEndExclusive
                        }
                    }
                    paragraphs.add(
                        Paragraph(
                            id = paragraphs.size,
                            text = pText,
                            highlightRange = localRange,
                            endsCitation = endsCitation
                        )
                    )
                    offset = end
                }
            }
            return BookReadingPage(
                chapterIndex = index,
                paragraphs = paragraphs,
                located = match != null
            )
        }

        private data class LocatedCitation(val chapter: Int, val range: IntRange)

        private fun locate(citation: ReadingCitation, chapters: List<BookChapter>): LocatedCitation? {
            val pieces = citation.excerpt.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            if (pieces.isEmpty()) return null
            val pattern = pieces.joinToString("\\s+") { Regex.escape(it) }
            val regex = runCatching { Regex(pattern) }.getOrNull() ?: return null

            var found: LocatedCitation? = null
            for (i in chapters.indices) {
                if (chapters[i].title != citation.chapter) continue
                val exact = citation.chapterIndex
                if (exact != null && exact != i) continue
                val text = chapters[i].text
                val offset = citation.utf16Offset
                if (offset != null) {
                    if (offset !in text.indices) continue
                    val anchored = regex.matchAt(text, offset) ?: continue
                    return LocatedCitation(i, anchored.range)
                }
                val matches = regex.findAll(text).take(2).toList()
                if (matches.size > 1) return null
                if (matches.size == 1) {
                    if (found != null) return null
                    found = LocatedCitation(i, matches[0].range)
                }
            }
            return found
        }
    }
}

private data class LineSpan(val startOffset: Int, val text: String)

private fun splitLinesWithOffsets(source: String): List<LineSpan> {
    val result = mutableListOf<LineSpan>()
    var i = 0
    val n = source.length
    var lineStart = 0
    while (i < n) {
        val c = source[i]
        if (c == '\n' || c == '\r') {
            if (i > lineStart) {
                result.add(LineSpan(lineStart, source.substring(lineStart, i)))
            }
            if (c == '\r' && i + 1 < n && source[i + 1] == '\n') {
                i += 2
            } else {
                i++
            }
            lineStart = i
        } else {
            i++
        }
    }
    if (n > lineStart) {
        result.add(LineSpan(lineStart, source.substring(lineStart, n)))
    }
    return result
}
