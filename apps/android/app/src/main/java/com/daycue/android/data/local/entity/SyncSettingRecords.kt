package com.daycue.android.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.daycue.android.domain.model.OutboxState
import java.time.Instant

/**
 * outbox_operation：本地先提交、后台重试。
 *
 * idempotency_key 上的唯一索引是幂等的最后一道防线：即使应用层逻辑写错、同一个操作被排两次，
 * 数据库也会拒绝第二条，而不是让外部系统出现两个一样的条目。
 */
@Entity(
    tableName = "outbox_operation",
    indices = [
        Index(value = ["idempotency_key"], unique = true),
        Index(value = ["state", "next_retry_at"]),
        Index(value = ["entity_type", "entity_id"]),
    ],
)
data class OutboxOperationRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "entity_type") val entityType: String,
    @ColumnInfo(name = "entity_id") val entityId: String,
    @ColumnInfo(name = "op") val op: String,
    @ColumnInfo(name = "idempotency_key") val idempotencyKey: String,
    @ColumnInfo(name = "payload_json") val payloadJson: String? = null,
    @ColumnInfo(name = "attempt") val attempt: Int = 0,
    @ColumnInfo(name = "state") val state: OutboxState = OutboxState.PENDING,
    @ColumnInfo(name = "next_retry_at") val nextRetryAt: Instant? = null,
    @ColumnInfo(name = "last_error") val lastError: String? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/** sync_cursor：增量拉取的游标。用服务端的单调 cursor，不用时间戳（时间戳会漏掉同秒变更）。 */
@Entity(tableName = "sync_cursor")
data class SyncCursorRecord(
    @PrimaryKey @ColumnInfo(name = "scope") val scope: String,
    @ColumnInfo(name = "cursor") val cursor: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/** sync_tombstone：删除传播。没有它，离线设备会把已删除的旧版本「复活」。 */
@Entity(
    tableName = "sync_tombstone",
    primaryKeys = ["entity_type", "entity_id"],
    indices = [Index(value = ["deleted_at"])],
)
data class SyncTombstoneRecord(
    @ColumnInfo(name = "entity_type") val entityType: String,
    @ColumnInfo(name = "entity_id") val entityId: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant,
    @ColumnInfo(name = "remote_version") val remoteVersion: Int? = null,
)

/**
 * sync_snapshot：上次同步时的字段快照，三方比较（本地/外部/上次快照）靠它。
 *
 * 必须有它：没有基线就分不清「本地改了」和「外部改了」，只能用最后写入者覆盖，
 * 而那会静默吞掉用户在某一次手工修改。
 */
@Entity(
    tableName = "sync_snapshot",
    primaryKeys = ["entity_type", "entity_id", "provider"],
)
data class SyncSnapshotRecord(
    @ColumnInfo(name = "entity_type") val entityType: String,
    @ColumnInfo(name = "entity_id") val entityId: String,
    @ColumnInfo(name = "provider") val provider: String,
    @ColumnInfo(name = "payload_json") val payloadJson: String,
    @ColumnInfo(name = "content_hash") val contentHash: String,
    @ColumnInfo(name = "captured_at") val capturedAt: Instant,
)

/** app_setting：非敏感偏好。令牌不进这里（Android Keystore），见 platform.security.TokenStore。 */
@Entity(tableName = "app_setting")
data class AppSettingRecord(
    @PrimaryKey @ColumnInfo(name = "key") val key: String,
    @ColumnInfo(name = "value") val value: String,
)
