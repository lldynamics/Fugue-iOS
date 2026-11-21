package com.iosbox.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import com.iosbox.app.core.storage.AccentTheme
import com.iosbox.app.core.storage.ThemeAppearanceMode

val LocalAccentColors = staticCompositionLocalOf {
    DS.colorsFor(AccentTheme.COBALT, dark = false)
}

@Composable
fun FugueTheme(
    accentTheme: AccentTheme = AccentTheme.COBALT,
    appearanceMode: ThemeAppearanceMode = ThemeAppearanceMode.SYSTEM,
    content: @Composable () -> Unit
) {
    val darkTheme = when (appearanceMode) {
        ThemeAppearanceMode.SYSTEM -> isSystemInDarkTheme()
        ThemeAppearanceMode.LIGHT -> false
        ThemeAppearanceMode.DARK -> true
    }
    val accent = DS.colorsFor(accentTheme, darkTheme)

    val colorScheme = if (darkTheme) {
        darkColorScheme(
            primary = accent.tint,
            onPrimary = Color.White,
            primaryContainer = accent.softFill,
            onPrimaryContainer = accent.readableText,
            secondary = accent.readableText,
            background = Color(0xFF0F1115),
            surface = Color(0xFF161920),
            surfaceVariant = Color(0xFF1F242E),
            onBackground = Color(0xFFF3F4F6),
            onSurface = Color(0xFFF3F4F6),
            onSurfaceVariant = Color(0xFF9CA3AF),
            outline = Color.White.copy(alpha = 0.12f)
        )
    } else {
        lightColorScheme(
            primary = accent.tint,
            onPrimary = Color.White,
            primaryContainer = accent.softFill,
            onPrimaryContainer = accent.readableText,
            secondary = accent.readableText,
            background = Color(0xFFF8F9FB),
            surface = Color.White,
            surfaceVariant = Color(0xFFF1F3F6),
            onBackground = Color(0xFF111827),
            onSurface = Color(0xFF111827),
            onSurfaceVariant = Color(0xFF6B7280),
            outline = Color.Black.copy(alpha = 0.08f)
        )
    }

    CompositionLocalProvider(LocalAccentColors provides accent) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = Typography,
            content = content
        )
    }
}
