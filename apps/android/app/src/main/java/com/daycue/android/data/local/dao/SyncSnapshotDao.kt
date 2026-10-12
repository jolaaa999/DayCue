package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.daycue.android.data.local.entity.SyncSnapshotRecord

/** sync_snapshot：三方对账的基线。每次对账结束后要用当时的字段重新拍一张快照。 */
@Dao
interface SyncSnapshotDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(record: SyncSnapshotRecord)

    @Query("SELECT * FROM sync_snapshot WHERE entity_type = :entityType AND entity_id = :entityId AND provider = :provider")
    suspend fun find(entityType: String, entityId: String, provider: String): SyncSnapshotRecord?

    @Query("SELECT * FROM sync_snapshot WHERE entity_type = :entityType AND provider = :provider")
    suspend fun listForEntityType(entityType: String, provider: String): List<SyncSnapshotRecord>

    @Query("DELETE FROM sync_snapshot WHERE entity_type = :entityType AND entity_id = :entityId AND provider = :provider")
    suspend fun forget(entityType: String, entityId: String, provider: String)

    @Query("DELETE FROM sync_snapshot WHERE entity_type = :entityType AND entity_id = :entityId")
    suspend fun forgetEntity(entityType: String, entityId: String)
}
