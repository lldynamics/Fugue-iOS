package com.iosbox.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.ui.MainScreen
import com.iosbox.app.ui.theme.FugueTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as FugueApplication).container
        container.externalEntryRouter.ingestIntent(intent, this)

        setContent {
            val prefs by container.preferences.state.collectAsStateWithLifecycle()
            FugueTheme(
                accentTheme = prefs.accentTheme,
                appearanceMode = prefs.appearanceMode
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    MainScreen(container = container)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        (application as FugueApplication).container.externalEntryRouter.ingestIntent(intent, this)
    }
}
