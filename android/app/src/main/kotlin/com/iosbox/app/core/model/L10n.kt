package com.iosbox.app.core.model

import java.util.Locale

internal object L10n {
    fun isChinese(): Boolean = Locale.getDefault().language.equals("zh", ignoreCase = true)

    fun text(zh: String, en: String): String = if (isChinese()) zh else en
}
