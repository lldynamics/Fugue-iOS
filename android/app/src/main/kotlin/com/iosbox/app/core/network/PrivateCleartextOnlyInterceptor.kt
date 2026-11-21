package com.iosbox.app.core.network

import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

class BlockedTransportException(val llmError: LLMError) : IOException(llmError.message)

/**
 * Enforces two security invariants at the OkHttp layer:
 * 1. Cleartext `http://` is permitted ONLY for local/LAN hosts (`NetworkLocation.isLocalOrPrivate`);
 *    any `http://` request targeting a public host is rejected before opening a socket.
 * 2. Paired with `followRedirects(false)` and `followSslRedirects(false)`, only same-origin redirects
 *    (matching scheme, host, and effective port) are followed, preventing credential leakage via
 *    301/302/307/308 cross-origin redirects or HTTPS->HTTP downgrades.
 */
class PrivateCleartextOnlyInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        var currentRequest = chain.request()
        validateUrl(currentRequest.url)

        var response = chain.proceed(currentRequest)
        var redirectCount = 0

        while (isRedirect(response.code) && redirectCount < MAX_REDIRECTS) {
            val location = response.header("Location")?.trim()
            if (location.isNullOrEmpty()) return response

            val nextUrl = currentRequest.url.resolve(location)
            if (nextUrl == null || !shouldAllowRedirect(currentRequest.url, nextUrl)) {
                response.close()
                throw BlockedTransportException(
                    LLMError.InvalidURL(nextUrl?.toString() ?: location)
                )
            }
            validateUrl(nextUrl)

            response.close()
            currentRequest = buildRedirectRequest(currentRequest, nextUrl, response.code)
            response = chain.proceed(currentRequest)
            redirectCount++
        }

        return response
    }

    private fun validateUrl(url: HttpUrl) {
        val raw = url.toString()
        if (url.scheme.equals("http", ignoreCase = true) &&
            NetworkLocation.isPlainHTTPToPublicHost(raw)
        ) {
            throw BlockedTransportException(LLMError.InsecurePublicHttp(raw))
        }
    }

    private fun isRedirect(code: Int): Boolean = code in listOf(301, 302, 303, 307, 308)

    private fun buildRedirectRequest(previous: Request, nextUrl: HttpUrl, code: Int): Request {
        val builder = previous.newBuilder().url(nextUrl)
        if (code == 303 || ((code == 301 || code == 302) && previous.method != "GET" && previous.method != "HEAD")) {
            builder.method("GET", null)
            builder.removeHeader("Content-Length")
            builder.removeHeader("Content-Type")
        }
        return builder.build()
    }

    companion object {
        private const val MAX_REDIRECTS = 5

        fun shouldAllowRedirect(source: HttpUrl?, next: HttpUrl?): Boolean {
            if (source == null || next == null) return false
            if (!source.scheme.equals(next.scheme, ignoreCase = true)) return false
            if (!source.host.equals(next.host, ignoreCase = true)) return false
            return source.port == next.port
        }
    }
}
