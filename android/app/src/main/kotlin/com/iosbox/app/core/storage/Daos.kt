package com.iosbox.app.core.storage

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface ProviderDao {
    @Query("SELECT * FROM providers ORDER BY sortOrder ASC, createdAtEpochMs ASC")
    fun observeAll(): Flow<List<ProviderEntity>>

    @Query("SELECT * FROM providers ORDER BY sortOrder ASC, createdAtEpochMs ASC")
    suspend fun getAll(): List<ProviderEntity>

    @Query("SELECT * FROM providers WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): ProviderEntity?

    @Query("SELECT COUNT(*) FROM providers")
    suspend fun count(): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ProviderEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<ProviderEntity>)

    @Query("DELETE FROM providers WHERE id = :id")
    suspend fun deleteById(id: String)
}

@Dao
interface AssistantPresetDao {
    @Query("SELECT * FROM assistant_presets ORDER BY sortOrder ASC, createdAtEpochMs ASC")
    fun observeAll(): Flow<List<AssistantPresetEntity>>

    @Query("SELECT * FROM assistant_presets ORDER BY sortOrder ASC, createdAtEpochMs ASC")
    suspend fun getAll(): List<AssistantPresetEntity>

    @Query("SELECT * FROM assistant_presets WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): AssistantPresetEntity?

    @Query("SELECT COUNT(*) FROM assistant_presets")
    suspend fun count(): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: AssistantPresetEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<AssistantPresetEntity>)

    @Query("DELETE FROM assistant_presets WHERE id = :id")
    suspend fun deleteById(id: String)
}

@Dao
interface ConversationDao {
    @Query("SELECT * FROM conversations ORDER BY isPinned DESC, updatedAtEpochMs DESC")
    fun observeAll(): Flow<List<ConversationEntity>>

    @Query("SELECT * FROM conversations ORDER BY updatedAtEpochMs DESC")
    suspend fun getAll(): List<ConversationEntity>

    @Query("SELECT * FROM conversations WHERE id = :id LIMIT 1")
    fun observeById(id: String): Flow<ConversationEntity?>

    @Query("SELECT * FROM conversations WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): ConversationEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ConversationEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<ConversationEntity>)

    @Query("DELETE FROM conversations WHERE id = :id")
    suspend fun deleteById(id: String)
}

@Dao
interface ChatMessageDao {
    @Query("SELECT * FROM chat_messages WHERE conversationID = :conversationID ORDER BY sortIndex ASC, createdAtEpochMs ASC")
    fun observeByConversation(conversationID: String): Flow<List<ChatMessageEntity>>

    @Query("SELECT * FROM chat_messages WHERE conversationID = :conversationID ORDER BY sortIndex ASC, createdAtEpochMs ASC")
    suspend fun getByConversation(conversationID: String): List<ChatMessageEntity>

    @Query("SELECT * FROM chat_messages")
    suspend fun getAll(): List<ChatMessageEntity>

    @Query("SELECT * FROM chat_messages WHERE comparisonGroupID IS NOT NULL ORDER BY createdAtEpochMs ASC")
    fun observeArenaMessages(): Flow<List<ChatMessageEntity>>

    @Query("SELECT * FROM chat_messages WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): ChatMessageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ChatMessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<ChatMessageEntity>)

    @Update
    suspend fun update(entity: ChatMessageEntity)

    @Query("DELETE FROM chat_messages WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("DELETE FROM chat_messages WHERE conversationID = :conversationID")
    suspend fun deleteByConversation(conversationID: String)

    @Query("UPDATE chat_messages SET isStreaming = 0, errorMessage = COALESCE(errorMessage, :interruptedMsg) WHERE isStreaming = 1")
    suspend fun recoverInterruptedStreams(interruptedMsg: String)
}

@Dao
interface RequestRecordDao {
    @Query("SELECT * FROM request_records ORDER BY startedAtEpochMs DESC")
    fun observeAll(): Flow<List<RequestRecordEntity>>

    @Query("SELECT * FROM request_records ORDER BY startedAtEpochMs ASC")
    suspend fun getAllAsc(): List<RequestRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: RequestRecordEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<RequestRecordEntity>)

    @Query("UPDATE request_records SET statusRaw = 'interrupted' WHERE statusRaw = 'running'")
    suspend fun recoverRunningRecords()
}

@Dao
interface PersonalMemoryDao {
    @Query("SELECT * FROM personal_memories ORDER BY createdAtEpochMs ASC")
    suspend fun getAll(): List<PersonalMemoryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<PersonalMemoryEntity>)
}

@Dao
interface BookVolumeDao {
    @Query("SELECT * FROM book_volumes ORDER BY importedAtEpochMs DESC")
    suspend fun getAll(): List<BookVolumeEntity>

    @Query("SELECT * FROM book_volumes WHERE id = :id LIMIT 1")
    suspend fun getById(id: String): BookVolumeEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: BookVolumeEntity)
}

@Dao
interface PersonaProfileDao {
    @Query("SELECT * FROM persona_profiles")
    suspend fun getAll(): List<PersonaProfileEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<PersonaProfileEntity>)
}

@Dao
interface ShelfReadingStateDao {
    @Query("SELECT * FROM shelf_reading_states")
    suspend fun getAll(): List<ShelfReadingStateEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(entities: List<ShelfReadingStateEntity>)
}
