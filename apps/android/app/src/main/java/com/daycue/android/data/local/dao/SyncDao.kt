package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.AppSettingRecord
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.local.entity.SyncCursorRecord
import com.daycue.android.data.local.entity.SyncTombstoneRecord
import com.daycue.android.domain.model.OutboxState
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/**
 * outbox_operation：本地先提交、后台重试。
 *
 * 「可执行」的定义刻意很窄：只有 pending、且到了重试时刻。
 * running 不在其中——它意味着上一次执行被进程中断，结果未知，必须先去对账，
 * 直接重跑可能让外部多出一条提醒。
 */
@Dao
interface OutboxDao {

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun enqueue(record: OutboxOperationRecord): Long

    @Update
    suspend fun update(record: OutboxOperationRecord)

    @Query("SELECT * FROM outbox_operation WHERE id = :id")
    suspend fun findById(id: String): OutboxOperationRecord?

    @Query("SELECT * FROM outbox_operation WHERE idempotency_key = :key")
    suspend fun findByIdempotencyKey(key: String): OutboxOperationRecord?

    @Query("SELECT * FROM outbox_operation WHERE entity_type = :entityType AND entity_id = :entityId ORDER BY created_at DESC")
    suspend fun listByEntity(entityType: String, entityId: String): List<OutboxOperationRecord>

    @Query("SELECT * FROM outbox_operation WHERE state = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= :now) ORDER BY created_at ASC LIMIT :limit")
    suspend fun listExecutable(now: Instant, limit: Int = 20): List<OutboxOperationRecord>

    @Query("SELECT * FROM outbox_operation WHERE state = :state ORDER BY created_at ASC")
    suspend fun listByState(state: OutboxState): List<OutboxOperationRecord>

    @Query("SELECT COUNT(*) FROM outbox_operation WHERE state IN ('pending', 'running')")
    fun observePendingCount(): Flow<Int>

    @Query("UPDATE outbox_operation SET state = :state, attempt = attempt + 1, last_error = :lastError, next_retry_at = :nextRetryAt, updated_at = :updatedAt WHERE id = :id")
    suspend fun markFailed(id: String, state: OutboxState, lastError: String?, nextRetryAt: Instant?, updatedAt: Instant)

    @Query("UPDATE outbox_operation SET state = 'running', attempt = attempt + 1, updated_at = :updatedAt WHERE id = :id AND state = 'pending'")
    suspend fun markRunning(id: String, updatedAt: Instant): Int

    @Query("UPDATE outbox_operation SET state = 'succeeded', last_error = NULL, next_retry_at = NULL, updated_at = :updatedAt WHERE id = :id")
    suspend fun markSucceeded(id: String, updatedAt: Instant)
}

/** sync_cursor：增量拉取游标。scope 例如 "tasks" / "notes"。 */
@Dao
interface SyncCursorDao {

    @Query("SELECT * FROM sync_cursor WHERE scope = :scope")
    suspend fun find(scope: String): SyncCursorRecord?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(record: SyncCursorRecord)

    @Query("SELECT * FROM sync_cursor")
    suspend fun listAll(): List<SyncCursorRecord>

    @Query("DELETE FROM sync_cursor WHERE scope = :scope")
    suspend fun delete(scope: String)
}

/** sync_tombstone：删除传播。离线设备靠它避免把已删除的数据「复活」。 */
@Dao
interface SyncTombstoneDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun record(record: SyncTombstoneRecord)

    @Query("SELECT * FROM sync_tombstone WHERE entity_type = :entityType AND entity_id = :entityId")
    suspend fun find(entityType: String, entityId: String): SyncTombstoneRecord?

    @Query("SELECT * FROM sync_tombstone WHERE deleted_at >= :since ORDER BY deleted_at ASC")
    suspend fun listSince(since: Instant): List<SyncTombstoneRecord>

    @Query("SELECT * FROM sync_tombstone ORDER BY deleted_at DESC LIMIT :limit")
    suspend fun listRecent(limit: Int = 200): List<SyncTombstoneRecord>

    @Query("DELETE FROM sync_tombstone WHERE deleted_at < :before")
    suspend fun deleteOlderThan(before: Instant)

    @Query("DELETE FROM sync_tombstone WHERE entity_type = :entityType AND entity_id = :entityId")
    suspend fun forget(entityType: String, entityId: String)
}

/**
 * app_setting：非敏感偏好。令牌不进这里，走 Android Keystore。
 * `key` 是 SQLite 关键字，所以查询里用反引号包起来，避免不同 SQLite 版本解析差异。
 */
@Dao
interface AppSettingDao {

    @Query("SELECT value FROM app_setting WHERE `key` = :key")
    suspend fun get(key: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun put(record: AppSettingRecord)

    @Query("SELECT value FROM app_setting WHERE `key` = :key")
    fun observe(key: String): Flow<String?>

    @Query("SELECT * FROM app_setting")
    suspend fun listAll(): List<AppSettingRecord>

    @Query("DELETE FROM app_setting WHERE `key` = :key")
    suspend fun delete(key: String)
}
