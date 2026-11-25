package com.iosbox.app.core.backup

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.network.NetworkLocation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.Base64
import java.util.concurrent.TimeUnit

sealed class WebDAVSyncException(override val message: String) : Exception(message) {
    class InvalidUrl : WebDAVSyncException(
        L10n.text(
            "WebDAV 服务器地址无效，请输入完整 URL（如 https://dav.jianguoyun.com/dav/）。",
            "Invalid WebDAV server URL."
        )
    )

    class InsecurePublicHttp : WebDAVSyncException(
        L10n.text(
            "公网 WebDAV 仅支持 HTTPS；局域网 NAS 或本机才允许使用 HTTP。",
            "Public WebDAV servers must use HTTPS. HTTP is restricted to LAN or localhost."
        )
    )

    class InvalidRemotePath : WebDAVSyncException(
        L10n.text(
            "云端文件路径无效，不能包含 .. 或查询参数。",
            "Invalid remote WebDAV file path."
        )
    )

    class MissingCredentials : WebDAVSyncException(
        L10n.text(
            "请完整填写 WebDAV 账号与密码。",
            "Please enter both WebDAV username and password."
        )
    )

    class Unauthorized : WebDAVSyncException(
        L10n.text(
            "WebDAV 身份验证失败，请核对账号或应用专用密码。",
            "WebDAV authentication failed. Check username or app password."
        )
    )

    class RemoteNotFound : WebDAVSyncException(
        L10n.text(
            "云端尚未找到该同步文件，请先加密上传一份备份。",
            "Remote sync file not found. Upload an encrypted backup first."
        )
    )

    class RedirectBlocked : WebDAVSyncException(
        L10n.text(
            "服务器返回了重定向响应，出于凭据安全已拦截。",
            "Redirect blocked to prevent leaking WebDAV credentials."
        )
    )

    class PayloadTooLarge : WebDAVSyncException(
        L10n.text(
            "备份文件超过安全体积上限，无法同步。",
            "Backup payload exceeds safe import/sync memory limit."
        )
    )

    class NotEncryptedBackup : WebDAVSyncException(
        L10n.text(
            "云端文件不是有效的夜奔加密备份格式。",
            "Remote file is not a valid Fugue encrypted backup."
        )
    )

    class ShardedBlobMissing(hash: String) : WebDAVSyncException(
        L10n.text(
            "云端缺少分片资产（${hash.take(12)}），请重新执行一次完整上传。",
            "Remote shard blob (${hash.take(12)}) is missing. Run a full upload."
        )
    )

    class HttpError(code: Int) : WebDAVSyncException(
        L10n.text("WebDAV 请求失败（HTTP $code）。", "WebDAV request failed (HTTP $code).")
    )
}

data class ResolvedWebDAVTarget(
    val serverUrl: String,
    val targetUrl: String,
    val parentDirectoryUrls: List<String>
)

object WebDAVEndpointResolver {
    fun validateServerUrl(rawServerUrl: String): String {
        val trimmed = rawServerUrl.trim()
        if (trimmed.isEmpty()) throw WebDAVSyncException.InvalidUrl()
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: throw WebDAVSyncException.InvalidUrl()
        val scheme = uri.scheme?.lowercase()
        val host = uri.host
        if ((scheme != "https" && scheme != "http") || host.isNullOrBlank()) {
            throw WebDAVSyncException.InvalidUrl()
        }
        if (NetworkLocation.isPlainHTTPToPublicHost(trimmed)) {
            throw WebDAVSyncException.InsecurePublicHttp()
        }
        return if (trimmed.endsWith("/")) trimmed else "$trimmed/"
    }

    fun resolve(rawServerUrl: String, rawRemotePath: String): ResolvedWebDAVTarget {
        val baseUrl = validateServerUrl(rawServerUrl)
        val cleanPath = rawRemotePath.trim()
        if (cleanPath.isEmpty() || cleanPath.contains("?") || cleanPath.contains("#") || cleanPath.contains("\\")) {
            throw WebDAVSyncException.InvalidRemotePath()
        }
        val segments = cleanPath.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) throw WebDAVSyncException.InvalidRemotePath()
        for (segment in segments) {
            if (segment == "." || segment == ".." || segment.trim().isEmpty()) {
                throw WebDAVSyncException.InvalidRemotePath()
            }
        }

        val parents = ArrayList<String>()
        var cursor = baseUrl
        for (i in 0 until segments.size - 1) {
            cursor = "$cursor${encodeSegment(segments[i])}/"
            parents.add(cursor)
        }
        val target = "$cursor${encodeSegment(segments.last())}"
        return ResolvedWebDAVTarget(
            serverUrl = baseUrl,
            targetUrl = target,
            parentDirectoryUrls = parents
        )
    }

    fun basicAuthHeader(username: String, password: String): String {
        val encoded = Base64.getEncoder().encodeToString("$username:$password".toByteArray(Charsets.UTF_8))
        return "Basic $encoded"
    }

    private fun encodeSegment(segment: String): String =
        segment.replace(" ", "%20")
}

class WebDAVSyncClient(
    private val httpClient: OkHttpClient = defaultClient()
) {
    companion object {
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        private val EMPTY_BODY = ByteArray(0).toRequestBody(null)

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(90, TimeUnit.SECONDS)
            .writeTimeout(90, TimeUnit.SECONDS)
            .build()

        internal fun parsePropfindChildNames(xml: String, directoryPath: String): List<String> {
            if (xml.isBlank()) return emptyList()
            val normalizedDir = directoryPath.trim('/').lowercase()
            val regex = Regex("""<(?:[A-Za-z0-9_-]+:)?href[^>]*>([^<]+)</(?:[A-Za-z0-9_-]+:)?href>""", RegexOption.IGNORE_CASE)
            val seen = LinkedHashSet<String>()
            for (match in regex.findAll(xml)) {
                val raw = match.groupValues[1].trim()
                if (raw.isEmpty()) continue
                val path = runCatching { URI(raw).path ?: raw }.getOrDefault(raw).trim('/')
                if (path.isEmpty() || path.lowercase() == normalizedDir) continue
                val leaf = path.substringAfterLast('/')
                if (leaf.isNotEmpty()) seen.add(leaf)
            }
            return seen.sorted()
        }
    }

    suspend fun testConnection(
        serverUrl: String,
        username: String,
        password: String
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val base = WebDAVEndpointResolver.validateServerUrl(serverUrl)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val req = Request.Builder()
                .url(base)
                .method("OPTIONS", null)
                .header("Authorization", WebDAVEndpointResolver.basicAuthHeader(cleanUser, password))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                validateStatus(resp.code, allow207 = true)
            }
        }
    }

    suspend fun uploadEncryptedBytes(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String,
        data: ByteArray
    ): Result<Unit> = uploadRawBytes(serverUrl, remotePath, username, password, data, "application/json; charset=utf-8")

    suspend fun exists(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String
    ): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val resolved = WebDAVEndpointResolver.resolve(serverUrl, remotePath)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val req = Request.Builder()
                .url(resolved.targetUrl)
                .head()
                .header("Authorization", WebDAVEndpointResolver.basicAuthHeader(cleanUser, password))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (resp.code == 404) return@use false
                validateStatus(resp.code, allow207 = false)
                true
            }
        }
    }

    suspend fun uploadRawBytes(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String,
        data: ByteArray,
        contentType: String
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            if (data.size > EncryptedBackupCrypto.MAXIMUM_FILE_BYTES) {
                throw WebDAVSyncException.PayloadTooLarge()
            }
            val resolved = WebDAVEndpointResolver.resolve(serverUrl, remotePath)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val auth = WebDAVEndpointResolver.basicAuthHeader(cleanUser, password)

            for (dirUrl in resolved.parentDirectoryUrls) {
                val mkcol = Request.Builder()
                    .url(dirUrl)
                    .method("MKCOL", EMPTY_BODY)
                    .header("Authorization", auth)
                    .build()
                httpClient.newCall(mkcol).execute().use { resp ->
                    when (resp.code) {
                        401, 403 -> throw WebDAVSyncException.Unauthorized()
                        in 300..399 -> throw WebDAVSyncException.RedirectBlocked()
                    }
                }
            }

            val put = Request.Builder()
                .url(resolved.targetUrl)
                .put(data.toRequestBody(contentType.toMediaType()))
                .header("Authorization", auth)
                .build()
            httpClient.newCall(put).execute().use { resp ->
                validateStatus(resp.code, allow207 = false)
            }
        }
    }

    suspend fun downloadRawBytes(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String
    ): Result<ByteArray> = withContext(Dispatchers.IO) {
        runCatching {
            val resolved = WebDAVEndpointResolver.resolve(serverUrl, remotePath)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val auth = WebDAVEndpointResolver.basicAuthHeader(cleanUser, password)

            val get = Request.Builder()
                .url(resolved.targetUrl)
                .get()
                .header("Authorization", auth)
                .build()
            httpClient.newCall(get).execute().use { resp ->
                if (resp.code == 404) throw WebDAVSyncException.RemoteNotFound()
                validateStatus(resp.code, allow207 = false)
                val body = resp.body ?: throw WebDAVSyncException.HttpError(resp.code)
                val limit = EncryptedBackupCrypto.safeImportBytes
                val declared = body.contentLength()
                if (declared > limit) throw WebDAVSyncException.PayloadTooLarge()

                body.byteStream().use { input ->
                    val buffer = ByteArray(16 * 1024)
                    val out = ByteArrayOutputStream()
                    var total = 0
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        total += read
                        if (total > limit) throw WebDAVSyncException.PayloadTooLarge()
                        out.write(buffer, 0, read)
                    }
                    out.toByteArray()
                }
            }
        }
    }

    suspend fun downloadEncryptedBytes(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String
    ): Result<ByteArray> = withContext(Dispatchers.IO) {
        downloadRawBytes(serverUrl, remotePath, username, password).mapCatching { bytes ->
            if (!EncryptedBackupCrypto.isEncryptedBackup(bytes)) {
                throw WebDAVSyncException.NotEncryptedBackup()
            }
            bytes
        }
    }

    suspend fun listDirectoryFilenames(
        serverUrl: String,
        directoryPath: String,
        username: String,
        password: String
    ): Result<List<String>> = withContext(Dispatchers.IO) {
        runCatching {
            val resolved = WebDAVEndpointResolver.resolve(serverUrl, directoryPath)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val dirUrl = if (resolved.targetUrl.endsWith("/")) resolved.targetUrl else "${resolved.targetUrl}/"
            val bodyXml = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"""
            val req = Request.Builder()
                .url(dirUrl)
                .method("PROPFIND", bodyXml.toRequestBody("application/xml; charset=utf-8".toMediaType()))
                .header("Authorization", WebDAVEndpointResolver.basicAuthHeader(cleanUser, password))
                .header("Depth", "1")
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (resp.code == 404) return@use emptyList()
                validateStatus(resp.code, allow207 = true)
                val xml = resp.body?.string().orEmpty()
                parsePropfindChildNames(xml, URI(dirUrl).path.orEmpty())
            }
        }
    }

    suspend fun deleteFile(
        serverUrl: String,
        remotePath: String,
        username: String,
        password: String
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val resolved = WebDAVEndpointResolver.resolve(serverUrl, remotePath)
            val cleanUser = username.trim()
            if (cleanUser.isEmpty() || password.isEmpty()) throw WebDAVSyncException.MissingCredentials()
            val req = Request.Builder()
                .url(resolved.targetUrl)
                .delete()
                .header("Authorization", WebDAVEndpointResolver.basicAuthHeader(cleanUser, password))
                .build()
            httpClient.newCall(req).execute().use { resp ->
                if (resp.code == 404) return@use
                validateStatus(resp.code, allow207 = false)
            }
        }
    }

    private fun validateStatus(code: Int, allow207: Boolean) {
        if (code == 401 || code == 403) throw WebDAVSyncException.Unauthorized()
        if (code in 300..399) throw WebDAVSyncException.RedirectBlocked()
        if (code in 200..299 || (allow207 && code == 207)) return
        throw WebDAVSyncException.HttpError(code)
    }
}
