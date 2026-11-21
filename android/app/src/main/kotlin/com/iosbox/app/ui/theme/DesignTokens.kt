package com.iosbox.app.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.storage.AccentTheme

object DS {
    object Spacing {
        val xxs = 4.dp
        val xs = 6.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 20.dp
        val xxl = 28.dp
    }

    object Radius {
        val xs = 8.dp
        val sm = 10.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 20.dp
    }

    data class AccentColors(
        val tint: Color,
        val solidFill: Color,
        val solidForeground: Color,
        val readableText: Color,
        val softFill: Color
    )

    fun colorsFor(theme: AccentTheme, dark: Boolean): AccentColors {
        val tint = when (theme) {
            AccentTheme.COBALT -> if (dark) Color(0.294f, 0.514f, 0.969f) else Color(0.145f, 0.388f, 0.922f)
            AccentTheme.GRAPHITE -> if (dark) Color(0.612f, 0.671f, 0.761f) else Color(0.149f, 0.192f, 0.271f)
            AccentTheme.INDIGO -> if (dark) Color(0.490f, 0.467f, 0.965f) else Color(0.294f, 0.255f, 0.816f)
            AccentTheme.TEAL -> if (dark) Color(0.176f, 0.722f, 0.678f) else Color(0.059f, 0.463f, 0.431f)
            AccentTheme.AMBER -> if (dark) Color(0.914f, 0.525f, 0.243f) else Color(0.718f, 0.333f, 0.082f)
        }
        val solidFill = when (theme) {
            AccentTheme.COBALT -> if (dark) Color(0.184f, 0.420f, 0.902f) else Color(0.145f, 0.388f, 0.922f)
            AccentTheme.GRAPHITE -> if (dark) Color(0.239f, 0.275f, 0.341f) else Color(0.149f, 0.192f, 0.271f)
            AccentTheme.INDIGO -> if (dark) Color(0.345f, 0.310f, 0.859f) else Color(0.294f, 0.255f, 0.816f)
            AccentTheme.TEAL -> if (dark) Color(0.075f, 0.514f, 0.478f) else Color(0.059f, 0.463f, 0.431f)
            AccentTheme.AMBER -> if (dark) Color(0.761f, 0.365f, 0.114f) else Color(0.706f, 0.325f, 0.075f)
        }
        val readableText = when (theme) {
            AccentTheme.COBALT -> if (dark) Color(0.486f, 0.698f, 1.0f) else Color(0.114f, 0.306f, 0.847f)
            AccentTheme.GRAPHITE -> if (dark) Color(0.855f, 0.886f, 0.933f) else Color(0.118f, 0.161f, 0.231f)
            AccentTheme.INDIGO -> if (dark) Color(0.647f, 0.631f, 0.992f) else Color(0.263f, 0.220f, 0.792f)
            AccentTheme.TEAL -> if (dark) Color(0.337f, 0.847f, 0.796f) else Color(0.059f, 0.427f, 0.400f)
            AccentTheme.AMBER -> if (dark) Color(0.961f, 0.635f, 0.376f) else Color(0.647f, 0.294f, 0.063f)
        }
        return AccentColors(
            tint = tint,
            solidFill = solidFill,
            solidForeground = Color.White,
            readableText = readableText,
            softFill = tint.copy(alpha = 0.13f)
        )
    }

    fun parseHexColor(hex: String, fallback: Color = Color(0xFF3F6EF6)): Color {
        val cleaned = hex.trim().removePrefix("#")
        val value = cleaned.toLongOrNull(16) ?: return fallback
        return when (cleaned.length) {
            6 -> Color(0xFF000000L or value)
            8 -> Color(value)
            else -> fallback
        }
    }
}
