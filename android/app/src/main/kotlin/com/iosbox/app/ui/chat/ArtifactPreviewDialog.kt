package com.iosbox.app.ui.chat

import android.annotation.SuppressLint
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.iosbox.app.core.model.L10n
import com.iosbox.app.ui.theme.DS
import java.io.ByteArrayInputStream

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtifactPreviewDialog(
    language: String,
    code: String,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    var showSource by remember { mutableStateOf(false) }
    val htmlDoc = remember(language, code) { ArtifactDocumentBuilder.htmlDocument(language, code) }
    val jsAllowed = remember(language) { ArtifactDocumentBuilder.allowsJavaScript(language) }

    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/html")
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(htmlDoc.toByteArray(Charsets.UTF_8))
                }
            }
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = L10n.text("关闭", "Close"))
                        }
                    },
                    title = {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilterChip(
                                selected = !showSource,
                                onClick = { showSource = false },
                                label = { Text(L10n.text("预览", "Preview")) }
                            )
                            FilterChip(
                                selected = showSource,
                                onClick = { showSource = true },
                                label = { Text(L10n.text("源码", "Source")) }
                            )
                        }
                    },
                    actions = {
                        IconButton(onClick = {
                            val name = "Fugue-Artifact-${language.trim().lowercase().ifEmpty { "html" }}.html"
                            exportLauncher.launch(name)
                        }) {
                            Icon(
                                imageVector = Icons.Filled.Upload,
                                contentDescription = L10n.text("导出 HTML", "Export HTML")
                            )
                        }
                    }
                )
            }
        ) { padding ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
            ) {
                if (showSource) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .horizontalScroll(rememberScrollState())
                            .padding(DS.Spacing.md)
                    ) {
                        Text(
                            text = code,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                                lineHeight = 19.sp
                            ),
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                } else {
                    SandboxedArtifactWebView(
                        html = htmlDoc,
                        allowsJavaScript = jsAllowed,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun SandboxedArtifactWebView(
    html: String,
    allowsJavaScript: Boolean,
    modifier: Modifier = Modifier
) {
    var activeWebView by remember { mutableStateOf<WebView?>(null) }

    DisposableEffect(Unit) {
        onDispose {
            activeWebView?.stopLoading()
            activeWebView?.destroy()
            activeWebView = null
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            WebView(ctx).apply {
                settings.apply {
                    javaScriptEnabled = allowsJavaScript
                    allowFileAccess = false
                    allowContentAccess = false
                    @Suppress("DEPRECATION")
                    allowFileAccessFromFileURLs = false
                    @Suppress("DEPRECATION")
                    allowUniversalAccessFromFileURLs = false
                    blockNetworkLoads = true
                    blockNetworkImage = true
                    domStorageEnabled = false
                    @Suppress("DEPRECATION")
                    databaseEnabled = false
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    builtInZoomControls = true
                    displayZoomControls = false
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?
                    ): Boolean = true

                    override fun shouldInterceptRequest(
                        view: WebView?,
                        request: WebResourceRequest?
                    ): WebResourceResponse? {
                        val scheme = request?.url?.scheme?.lowercase().orEmpty()
                        if (scheme == "about" || scheme == "data") {
                            return null
                        }
                        return WebResourceResponse(
                            "text/plain",
                            "utf-8",
                            403,
                            "Blocked",
                            emptyMap(),
                            ByteArrayInputStream(ByteArray(0))
                        )
                    }
                }
                loadDataWithBaseURL("about:blank", html, "text/html", "utf-8", null)
                activeWebView = this
            }
        },
        update = { webView ->
            webView.settings.javaScriptEnabled = allowsJavaScript
            val tagKey = "$allowsJavaScript:${html.hashCode()}"
            if (webView.tag != tagKey) {
                webView.tag = tagKey
                webView.loadDataWithBaseURL("about:blank", html, "text/html", "utf-8", null)
            }
        }
    )
}
