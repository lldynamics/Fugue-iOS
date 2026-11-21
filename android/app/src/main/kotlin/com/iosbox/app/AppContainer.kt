package com.iosbox.app

import android.content.Context
import com.iosbox.app.core.backup.BackupRepository
import com.iosbox.app.core.network.APIKeyPoolRouter
import com.iosbox.app.core.network.GatewayCapabilityCache
import com.iosbox.app.core.network.LLMClient
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.core.security.TinkSecretStore
import com.iosbox.app.core.storage.AppPreferences
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.DataSeeder
import com.iosbox.app.core.storage.ExternalBlobStore
import com.iosbox.app.core.storage.FileExternalBlobStore
import com.iosbox.app.core.storage.FlashcardRepository
import com.iosbox.app.core.storage.FugueDatabase
import java.io.File

class AppContainer(context: Context) {
    private val appContext = context.applicationContext

    val preferences: AppPreferences = AppPreferences(appContext)
    val secretStore: SecretStore = TinkSecretStore(appContext)
    val blobStore: ExternalBlobStore = FileExternalBlobStore(File(appContext.filesDir, "blobs"))
    val database: FugueDatabase = FugueDatabase.build(appContext)
    val capabilityCache: GatewayCapabilityCache = GatewayCapabilityCache(preferences)
    val keyRouter: APIKeyPoolRouter = APIKeyPoolRouter()

    val llmClient: LLMClient = LLMClient(
        capabilityCache = capabilityCache,
        keyRouter = keyRouter,
        isConsentAccepted = { preferences.isConsentAccepted }
    )

    val chatRepository: ChatRepository = ChatRepository(
        db = database,
        blobStore = blobStore,
        secretStore = secretStore
    )

    val flashcardRepository: FlashcardRepository = FlashcardRepository(blobStore = blobStore)

    val backupRepository: BackupRepository = BackupRepository(
        db = database,
        blobStore = blobStore,
        secretStore = secretStore,
        appVersion = BuildConfig.VERSION_NAME
    )

    val dataSeeder: DataSeeder = DataSeeder(
        db = database,
        preferences = preferences,
        secretStore = secretStore
    )
}
