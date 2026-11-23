package com.iosbox.app.core.network

import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI

/**
 * Classifies a provider Base URL by where its host lives, using the parsed host instead of
 * substring checks (e.g. `api10.example.com` must not count as a private `10.x` address).
 */
object NetworkLocation {
    internal fun isPrivateCleartextAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isMulticastAddress) return false
        if (address.isLoopbackAddress || address.isLinkLocalAddress) return true
        val bytes = address.address.map { it.toInt() and 0xff }
        if (bytes.size == 4) return bytes[0] != 0 && isPrivateIPv4(bytes.toIntArray())
        if (bytes.size != 16) return false
        if ((bytes[0] and 0xfe) == 0xfc) return true
        val mapped = bytes.take(10).all { it == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        return mapped && bytes[12] != 0 && isPrivateIPv4(bytes.drop(12).toIntArray())
    }

    fun isLocalOrPrivate(baseURL: String): Boolean {
        val host = hostOf(baseURL) ?: return false
        return isLocalOrPrivateHost(host)
    }

    fun isPlainHTTPToPublicHost(baseURL: String): Boolean {
        val uri = parseUri(baseURL) ?: return false
        if (!uri.scheme.equals("http", ignoreCase = true)) return false
        val host = extractHost(uri) ?: return false
        return !isLocalOrPrivateHost(normalized(host))
    }

    fun isLocalOrPrivateHost(rawHost: String): Boolean {
        val host = normalized(rawHost)
        if (host.isEmpty()) return false

        if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
            return true
        }
        ipv4Octets(host)?.let { return isPrivateIPv4(it) }

        if (host.contains(":")) {
            ipv6Bytes(host)?.let { return isPrivateIPv6(it) }
            val bare = host.substringBefore('%')
            if (bare == "::" || bare == "::1" || bare.startsWith("fc") || bare.startsWith("fd") || isIPv6LinkLocal(bare)) {
                return true
            }
            if (bare.startsWith("::ffff:")) {
                val mapped = bare.removePrefix("::ffff:")
                return if (ipv4Octets(mapped) != null) isLocalOrPrivateHost(mapped) else true
            }
            return false
        }

        // Unqualified names ("my-mac", "nas") only resolve on the local network.
        return !host.contains(".")
    }

    fun isIPv4Literal(rawHost: String): Boolean = ipv4Octets(normalized(rawHost)) != null

    private fun isPrivateIPv4(octets: IntArray): Boolean {
        val a = octets[0]
        val b = octets[1]
        return when {
            a == 0 || a == 10 || a == 127 -> true
            a == 172 && b in 16..31 -> true
            a == 192 && b == 168 -> true
            a == 169 && b == 254 -> true
            a == 198 && b in 18..19 -> true
            a == 100 && b in 64..127 -> true // CGNAT / Tailscale
            else -> false
        }
    }

    private fun ipv6Bytes(rawHost: String): ByteArray? {
        val stripped = rawHost.substringBefore('%')
        // Guard against arbitrary hostnames hitting DNS: only accept pure IPv6 literal characters.
        if (stripped.isEmpty() || !stripped.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.' }) {
            return null
        }
        return runCatching {
            val addr = InetAddress.getByName("[$stripped]")
            (addr as? Inet6Address)?.address ?: addr.address.takeIf { it.size == 16 }
        }.getOrNull()
    }

    private fun isPrivateIPv6(bytes: ByteArray): Boolean {
        if (bytes.size != 16) return false
        val u = IntArray(16) { bytes[it].toInt() and 0xFF }
        if (u.all { it == 0 }) return true // ::
        if ((0 until 15).all { u[it] == 0 } && u[15] == 1) return true // ::1
        if ((u[0] and 0xFE) == 0xFC) return true // fc00::/7
        if (u[0] == 0xFE && (u[1] and 0xC0) == 0x80) return true // fe80::/10
        // IPv4-mapped IPv6 (::ffff:0:0/96) and IPv4-compatible (::0:0/96)
        if ((0 until 10).all { u[it] == 0 } && u[10] == 0xFF && u[11] == 0xFF) {
            return isPrivateIPv4(intArrayOf(u[12], u[13], u[14], u[15]))
        }
        if ((0 until 12).all { u[it] == 0 }) {
            return isPrivateIPv4(intArrayOf(u[12], u[13], u[14], u[15]))
        }
        // RFC 6052 / RFC 8215 NAT64 prefixes: 64:ff9b::/96 and 64:ff9b:1::/48
        if (u[0] == 0x00 && u[1] == 0x64 && u[2] == 0xFF && u[3] == 0x9B) {
            if (u[4] == 0x00 && u[5] == 0x01) return true
            if ((4 until 12).all { u[it] == 0 }) {
                return isPrivateIPv4(intArrayOf(u[12], u[13], u[14], u[15]))
            }
        }
        return false
    }

    private fun isIPv6LinkLocal(host: String): Boolean {
        val firstSegment = host.substringBefore(':')
        if (firstSegment.length != 4) return false
        val value = firstSegment.toIntOrNull(16) ?: return false
        return (value and 0xFFC0) == 0xFE80
    }

    private fun ipv4Octets(host: String): IntArray? {
        val parts = host.split('.')
        if (parts.isEmpty() || parts.size > 4) return null
        if (parts.size == 4) {
            val std = parts.mapNotNull { seg ->
                if (seg.isEmpty() || !seg.all { it in '0'..'9' }) return@mapNotNull null
                if (seg.length > 1 && seg.startsWith("0")) return@mapNotNull null
                seg.toIntOrNull()?.takeIf { it in 0..255 }
            }
            if (std.size == 4) return std.toIntArray()
        }
        // Handle inet_aton alternate IPv4 forms (octal, hex, shorthand like 127.1 or 0x7f.0.0.1 or integer)
        val parsed = parts.map { parseIPv4Segment(it) ?: return null }
        val value: Long = when (parsed.size) {
            1 -> {
                if (parsed[0] > 0xFFFFFFFFL) return null
                parsed[0]
            }
            2 -> {
                if (parsed[0] > 0xFFL || parsed[1] > 0xFFFFFFL) return null
                (parsed[0] shl 24) or parsed[1]
            }
            3 -> {
                if (parsed[0] > 0xFFL || parsed[1] > 0xFFL || parsed[2] > 0xFFFFL) return null
                (parsed[0] shl 24) or (parsed[1] shl 16) or parsed[2]
            }
            4 -> {
                if (parsed.any { it > 0xFFL }) return null
                (parsed[0] shl 24) or (parsed[1] shl 16) or (parsed[2] shl 8) or parsed[3]
            }
            else -> return null
        }
        return intArrayOf(
            ((value ushr 24) and 0xFFL).toInt(),
            ((value ushr 16) and 0xFFL).toInt(),
            ((value ushr 8) and 0xFFL).toInt(),
            (value and 0xFFL).toInt()
        )
    }

    private fun parseIPv4Segment(seg: String): Long? {
        if (seg.isEmpty()) return null
        return when {
            seg.startsWith("0x", ignoreCase = true) -> {
                val hex = seg.drop(2)
                if (hex.isEmpty()) null else hex.toLongOrNull(16)
            }
            seg.startsWith("0") && seg.length > 1 -> {
                val oct = seg.drop(1)
                if (oct.any { it !in '0'..'7' }) null else oct.toLongOrNull(8)
            }
            else -> {
                if (seg.any { it !in '0'..'9' }) null else seg.toLongOrNull(10)
            }
        }?.takeIf { it >= 0 }
    }

    private fun parseUri(baseURL: String): URI? {
        var trimmed = baseURL.trim()
        if (trimmed.endsWith("#")) trimmed = trimmed.dropLast(1)
        if (trimmed.isEmpty()) return null
        return runCatching { URI(trimmed) }.getOrNull()
    }

    private fun hostOf(baseURL: String): String? {
        val uri = parseUri(baseURL) ?: return null
        val host = extractHost(uri) ?: return null
        return normalized(host)
    }

    private fun extractHost(uri: URI): String? {
        uri.host?.takeIf { it.isNotEmpty() }?.let { return it }
        val authority = uri.rawAuthority?.takeIf { it.isNotEmpty() } ?: return null
        val withoutUserInfo = authority.substringAfterLast('@')
        if (withoutUserInfo.isEmpty()) return null
        return if (withoutUserInfo.startsWith("[")) {
            val endBracket = withoutUserInfo.indexOf(']')
            if (endBracket > 1) withoutUserInfo.substring(1, endBracket) else null
        } else {
            withoutUserInfo.substringBefore(':').takeIf { it.isNotEmpty() }
        }
    }

    private fun normalized(host: String): String =
        host.lowercase().trim('[', ']', '.')
}
