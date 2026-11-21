package com.iosbox.app.core.storage

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        ProviderEntity::class,
        AssistantPresetEntity::class,
        ConversationEntity::class,
        ChatMessageEntity::class,
        RequestRecordEntity::class,
        PersonalMemoryEntity::class,
        BookVolumeEntity::class,
        PersonaProfileEntity::class,
        ShelfReadingStateEntity::class
    ],
    version = 1,
    exportSchema = true
)
abstract class FugueDatabase : RoomDatabase() {
    abstract fun providerDao(): ProviderDao
    abstract fun assistantPresetDao(): AssistantPresetDao
    abstract fun conversationDao(): ConversationDao
    abstract fun chatMessageDao(): ChatMessageDao
    abstract fun requestRecordDao(): RequestRecordDao
    abstract fun personalMemoryDao(): PersonalMemoryDao
    abstract fun bookVolumeDao(): BookVolumeDao
    abstract fun personaProfileDao(): PersonaProfileDao
    abstract fun shelfReadingStateDao(): ShelfReadingStateDao

    companion object {
        fun build(context: Context): FugueDatabase =
            Room.databaseBuilder(
                context.applicationContext,
                FugueDatabase::class.java,
                "fugue.db"
            ).build()
    }
}
