package com.daycue.android.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.daycue.android.domain.model.CoordinateSystem
import com.daycue.android.domain.model.PlaceTrigger
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import java.time.Instant
import java.time.LocalTime

/**
 * place：用户确认过的地点。
 *
 * 只保存用户自己确认过的点与半径，不记录轨迹；confirmed_by_user=0 的点不能用于自动触发。
 */
@Entity(
    tableName = "place",
    indices = [Index(value = ["deleted_at"])],
)
data class PlaceRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "latitude") val latitude: Double,
    @ColumnInfo(name = "longitude") val longitude: Double,
    @ColumnInfo(name = "radius_meters") val radiusMeters: Double,
    @ColumnInfo(name = "address") val address: String? = null,
    /**
     * 坐标的坐标系。
     *
     * 建表默认值写 wgs84：Android 的 LocationManager 给的就是 WGS84，v2 时代存下的行也只有这一种可能。
     * 但新建地点时仓储要求显式传入（不依赖默认值），因为一旦接入 GCJ-02 取点来源，
     * 「忘了传」和「确实是 WGS84」在库里会长得一模一样。
     */
    @ColumnInfo(name = "coordinate_system", defaultValue = "wgs84")
    val coordinateSystem: CoordinateSystem = CoordinateSystem.WGS84,
    @ColumnInfo(name = "confirmed_by_user") val confirmedByUser: Boolean = false,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
)

/** geo_rule：位置规则。触发条件 + 生效时段 + 冷却，三者缺一都会变成骚扰。 */
@Entity(
    tableName = "geo_rule",
    foreignKeys = [
        ForeignKey(
            entity = PlaceRecord::class,
            parentColumns = ["id"],
            childColumns = ["place_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index(value = ["place_id"]), Index(value = ["enabled"]), Index(value = ["linked_task_id"])],
)
data class GeoRuleRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "place_id") val placeId: String,
    @ColumnInfo(name = "trigger") val trigger: PlaceTrigger,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "body") val body: String? = null,
    @ColumnInfo(name = "min_dwell_seconds") val minDwellSeconds: Int = 0,
    @ColumnInfo(name = "cooldown_seconds") val cooldownSeconds: Int = 3600,
    @ColumnInfo(name = "active_from_local") val activeFromLocal: LocalTime? = null,
    @ColumnInfo(name = "active_to_local") val activeToLocal: LocalTime? = null,
    /** 生效星期，JSON 数组，取值 1..7；空集合表示每天都生效。 */
    @ColumnInfo(name = "weekdays") val weekdays: List<Int> = emptyList(),
    @ColumnInfo(name = "enabled") val enabled: Boolean = true,
    /**
     * 触发时指向的具体任务（可空）。
     *
     * 刻意不加 FOREIGN KEY：任务在 App 里是软删除（deleted_at），物理行会一直留着，
     * 外键约束带不来任何保护，却会让 MIGRATION_2_3 的 ADD COLUMN 必须写出 Room 认识的外键子句，
     * 写错就是真机升级时抛「Migration didn't properly handle」。
     * 引用完整性由仓储层保证：删任务不删规则，规则只是不再指向任何任务。
     */
    @ColumnInfo(name = "linked_task_id") val linkedTaskId: String? = null,
    @ColumnInfo(name = "expires_at_utc") val expiresAtUtc: Instant? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
)

/**
 * proactive_message：主动消息账本。
 *
 * 预算、冷却、去重全部在这里判，不靠内存状态——进程被系统杀掉之后，
 * 「今天已经打扰过 3 次」这个事实必须还在。
 * cooldownKey 不单开一列：它复用 target_ref（例如 geo_rule 的 id），少一列就少一处双端漂移。
 */
@Entity(
    tableName = "proactive_message",
    indices = [
        Index(value = ["dedupe_key"], unique = true),
        Index(value = ["state", "scheduled_at_utc"]),
        Index(value = ["kind", "delivered_at_utc"]),
    ],
)
data class ProactiveMessageRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "kind") val kind: ProactiveKind,
    @ColumnInfo(name = "dedupe_key") val dedupeKey: String,
    @ColumnInfo(name = "target_ref") val targetRef: String? = null,
    @ColumnInfo(name = "state") val state: ProactiveState = ProactiveState.PENDING,
    @ColumnInfo(name = "suppress_reason") val suppressReason: String? = null,
    @ColumnInfo(name = "scheduled_at_utc") val scheduledAtUtc: Instant,
    @ColumnInfo(name = "delivered_at_utc") val deliveredAtUtc: Instant? = null,
    @ColumnInfo(name = "expires_at_utc") val expiresAtUtc: Instant? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)
