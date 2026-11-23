package com.iosbox.app.core.system

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.iosbox.app.core.network.WebpageReader
import java.net.URI

object WebLinkHandoff {
    fun destination(raw: String, publicHttps: Boolean = false): URI? = runCatching {
        val uri = URI(raw.trim())
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrBlank() ||
            uri.rawUserInfo != null || (uri.port != -1 && uri.port !in 1..65535)) return null
        if (publicHttps) WebpageReader.validate(uri)
        uri
    }.getOrNull()

    fun open(context: Context, raw: String, publicHttps: Boolean = false) {
        val uri = destination(raw, publicHttps) ?: return
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri.toASCIIString()).normalizeScheme())
                .addCategory(Intent.CATEGORY_BROWSABLE))
        }
    }
}
