package com.iosbox.app.core.storage

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

interface ExternalBlobStore {
    fun readBytes(key: String): ByteArray?
    fun writeBytes(key: String, bytes: ByteArray)
    fun delete(key: String)
    fun keys(): Set<String> = emptySet()

    fun readText(key: String?): String? {
        if (key.isNullOrBlank()) return null
        return readBytes(key)?.toString(Charsets.UTF_8)
    }

    fun writeText(key: String, text: String) {
        writeBytes(key, text.toByteArray(Charsets.UTF_8))
    }
}

class FileExternalBlobStore(private val rootDir: File) : ExternalBlobStore {
    init {
        if (!rootDir.exists()) {
            rootDir.mkdirs()
        }
    }

    override fun readBytes(key: String): ByteArray? {
        val file = resolveSafeFile(key) ?: return null
        if (!file.exists() || !file.isFile) return null
        return runCatching { file.readBytes() }.getOrNull()
    }

    override fun writeBytes(key: String, bytes: ByteArray) {
        val target = resolveSafeFile(key) ?: error("Invalid blob key: $key")
        if (!rootDir.exists()) rootDir.mkdirs()
        val tmp = File(rootDir, "${target.name}.tmp")
        FileOutputStream(tmp).use { output ->
            output.write(bytes)
            if (RestoreBlobBatch.owns(key)) output.fd.sync()
        }
        try {
            Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (_: Exception) {
            Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    override fun delete(key: String) {
        val file = resolveSafeFile(key) ?: return
        if (file.exists()) {
            file.delete()
        }
    }

    override fun keys(): Set<String> = rootDir.listFiles().orEmpty()
        .filter { it.isFile && !Files.isSymbolicLink(it.toPath()) }
        .mapTo(HashSet()) { it.name }

    private fun resolveSafeFile(key: String): File? {
        if (key.isBlank() || key.length > 160) return null
        if (!key.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '_' || it == '-' || it == '.' }) {
            return null
        }
        val candidate = File(rootDir, key)
        val canonicalRoot = rootDir.canonicalFile
        val canonicalCandidate = candidate.canonicalFile
        if (canonicalCandidate.parentFile != canonicalRoot) return null
        return canonicalCandidate
    }
}

class InMemoryBlobStore : ExternalBlobStore {
    private val lock = Any()
    private val map = HashMap<String, ByteArray>()

    override fun readBytes(key: String): ByteArray? = synchronized(lock) {
        map[key]?.copyOf()
    }

    override fun writeBytes(key: String, bytes: ByteArray) {
        synchronized(lock) {
            map[key] = bytes.copyOf()
        }
    }

    override fun delete(key: String) {
        synchronized(lock) {
            map.remove(key)
        }
    }

    override fun keys(): Set<String> = synchronized(lock) { map.keys.toSet() }
}
