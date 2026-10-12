package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.data.local.entity.ProactiveMessageRecord
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.domain.model.ProactiveState
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/** memory_item：记忆的查看、复核与删除。删除用软删除，历史来源要能被用户看到。 */
@Dao
interface MemoryDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: MemoryItemRecord)

    @Update
    suspend fun update(record: MemoryItemRecord)

    @Query("SELECT * FROM memory_item WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): MemoryItemRecord?

    @Query("SELECT * FROM memory_item WHERE deleted_at IS NULL ORDER BY created_at DESC")
    fun observeAll(): Flow<List<MemoryItemRecord>>

    @Query("SELECT * FROM memory_item WHERE status = :status AND deleted_at IS NULL ORDER BY created_at DESC")
    suspend fun listByStatus(status: MemoryStatus): List<MemoryItemRecord>

    /** 到点需要复核的记忆（阶段状态默认 30 天）。 */
    @Query("SELECT * FROM memory_item WHERE deleted_at IS NULL AND review_at IS NOT NULL AND review_at <= :now ORDER BY review_at ASC")
    suspend fun listDueForReview(now: Instant): List<MemoryItemRecord>

    @Query("SELECT * FROM memory_item WHERE deleted_at IS NULL AND (statement LIKE :pattern OR kind LIKE :pattern) ORDER BY created_at DESC LIMIT :limit")
    suspend fun search(pattern: String, limit: Int = 50): List<MemoryItemRecord>

    @Query("UPDATE memory_item SET status = :status WHERE id = :id")
    suspend fun updateStatus(id: String, status: MemoryStatus)

    @Query("UPDATE memory_item SET deleted_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)
}

/** place：只保存用户确认过的地点与半径，不记录轨迹。 */
@Dao
interface PlaceDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: PlaceRecord)

    @Update
    suspend fun update(record: PlaceRecord)

    @Query("SELECT * FROM place WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): PlaceRecord?

    @Query("SELECT * FROM place WHERE deleted_at IS NULL ORDER BY name ASC")
    fun observeActive(): Flow<List<PlaceRecord>>

    /** 只有用户确认过的地点才允许参与自动触发。 */
    @Query("SELECT * FROM place WHERE deleted_at IS NULL AND confirmed_by_user = 1 ORDER BY name ASC")
    suspend fun listConfirmed(): List<PlaceRecord>

    @Query("UPDATE place SET deleted_at = :deletedAt, updated_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)
}

/** geo_rule：位置规则。定位能力不可用时，这些规则必须保持 enabled=0 的可见状态而不是静默失效。 */
@Dao
interface GeoRuleDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: GeoRuleRecord)

    @Update
    suspend fun update(record: GeoRuleRecord)

    @Query("SELECT * FROM geo_rule WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): GeoRuleRecord?

    @Query("SELECT * FROM geo_rule WHERE deleted_at IS NULL ORDER BY created_at DESC")
    fun observeAll(): Flow<List<GeoRuleRecord>>

    @Query("SELECT * FROM geo_rule WHERE deleted_at IS NULL AND enabled = 1 AND place_id = :placeId")
    suspend fun listEnabledForPlace(placeId: String): List<GeoRuleRecord>

    @Query("SELECT * FROM geo_rule WHERE deleted_at IS NULL AND enabled = 1")
    suspend fun listEnabled(): List<GeoRuleRecord>

    /** 全部未删除规则（含已暂停的）：定位能力恢复时要把用户原来的开关放回去。 */
    @Query("SELECT * FROM geo_rule WHERE deleted_at IS NULL")
    suspend fun listAll(): List<GeoRuleRecord>

    @Query("UPDATE geo_rule SET enabled = :enabled, updated_at = :updatedAt WHERE id = :id")
    suspend fun setEnabled(id: String, enabled: Boolean, updatedAt: Instant)

    @Query("UPDATE geo_rule SET deleted_at = :deletedAt, updated_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)
}

/**
 * proactive_message：主动消息账本。
 * 写入走 IGNORE：dedupe_key 唯一索引是去重的最后一道防线，重复插入不是错误，是预期内的竞态。
 */
@Dao
interface ProactiveMessageDao {

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertIgnoringDuplicate(record: ProactiveMessageRecord): Long

    @Update
    suspend fun update(record: ProactiveMessageRecord)

    @Query("SELECT * FROM proactive_message WHERE dedupe_key = :dedupeKey")
    suspend fun findByDedupeKey(dedupeKey: String): ProactiveMessageRecord?

    @Query("SELECT * FROM proactive_message WHERE state = 'pending' AND scheduled_at_utc <= :now ORDER BY scheduled_at_utc ASC")
    suspend fun listDuePending(now: Instant): List<ProactiveMessageRecord>

    /** 预算判定要用：取某一时间点之后的所有投递记录。 */
    @Query("SELECT * FROM proactive_message WHERE delivered_at_utc IS NOT NULL AND delivered_at_utc >= :since ORDER BY delivered_at_utc DESC")
    suspend fun listDeliveredSince(since: Instant): List<ProactiveMessageRecord>

    @Query("SELECT * FROM proactive_message ORDER BY scheduled_at_utc DESC LIMIT :limit")
    fun observeRecent(limit: Int = 100): Flow<List<ProactiveMessageRecord>>

    @Query("UPDATE proactive_message SET state = :state, suppress_reason = :suppressReason, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateState(id: String, state: ProactiveState, suppressReason: String?, updatedAt: Instant)

    @Query("UPDATE proactive_message SET state = 'delivered', delivered_at_utc = :deliveredAt, updated_at = :deliveredAt WHERE id = :id")
    suspend fun markDelivered(id: String, deliveredAt: Instant)

    @Query("SELECT * FROM proactive_message WHERE state = 'pending' AND expires_at_utc IS NOT NULL AND expires_at_utc < :now")
    suspend fun listExpiredPending(now: Instant): List<ProactiveMessageRecord>
}
