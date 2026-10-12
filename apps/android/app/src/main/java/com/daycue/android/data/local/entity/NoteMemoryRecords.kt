package com.daycue.android.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.domain.model.NoteOriginKind
import java.time.Instant

/**
 * note：可持久化的笔记。
 *
 * v2 之前笔记只藏在 extraction_proposal.payload_json 里，列表和详情都无从谈起。
 * 保留 origin_capture_id / origin_item_id，是为了让「这条笔记从哪来」永远可追溯。
 */
@Entity(
    tableName = "note",
    indices = [
        Index(value = ["created_at"]),
        Index(value = ["course_hint"]),
        Index(value = ["origin_capture_id"]),
    ],
)
data class NoteRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "body") val body: String,
    /** tags 在 SQLite 里是一列 TEXT，用 Converters 做 JSON 序列化；空列表与 null 含义不同（未标注 vs 无标签）。 */
    @ColumnInfo(name = "tags") val tags: List<String> = emptyList(),
    @ColumnInfo(name = "course_hint") val courseHint: String? = null,
    @ColumnInfo(name = "origin_capture_id") val originCaptureId: String? = null,
    @ColumnInfo(name = "origin_item_id") val originItemId: String? = null,
    @ColumnInfo(name = "origin_kind") val originKind: NoteOriginKind = NoteOriginKind.MANUAL,
    /** 用户改过的笔记不允许被重试解析覆盖，与 capture 的 user_edited 同一套规则。 */
    @ColumnInfo(name = "user_edited") val userEdited: Boolean = false,
    @ColumnInfo(name = "occurred_at") val occurredAt: Instant? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
)

/**
 * memory_item：用户确认为事实的记忆条目。
 *
 * 与 iOS Schema v2 的差异（需要主会话裁定，已记入 README）：
 * iOS 在 v2 里把记忆拆成 memory_revision / memory_control / memory_index 三张表；
 * Android 第一版只保留 memory_item 一张表，并把 source_kind 一并放在这里，
 * 因为「推断不得表述为事实」这条规则要求 UI 一眼能看到来源，而单表做不到跨表 join 的轻量读取。
 */
@Entity(
    tableName = "memory_item",
    indices = [
        Index(value = ["status"]),
        Index(value = ["review_at"]),
    ],
)
data class MemoryItemRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    /** 记忆类别，例如 learning_state / preference / goal。自由字符串，后续类别扩展不需要迁移。 */
    @ColumnInfo(name = "kind") val kind: String,
    @ColumnInfo(name = "statement") val statement: String,
    @ColumnInfo(name = "status") val status: MemoryStatus = MemoryStatus.CANDIDATE,
    // defaultValue 不是可选装饰：v1 老库升级时这一列必须靠 DEFAULT 补上，
    // 而 Room 会比对「迁移建出的表」与「实体生成的表」，两边默认值不一致会直接让启动崩溃。
    @ColumnInfo(name = "source_kind", defaultValue = "inferred") val sourceKind: MemorySourceKind = MemorySourceKind.INFERRED,
    @ColumnInfo(name = "source_capture_id") val sourceCaptureId: String? = null,
    /** 复核时间。到点后应出现在「记忆」页顶部，提醒用户确认或作废。 */
    @ColumnInfo(name = "review_at") val reviewAt: Instant? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
)
