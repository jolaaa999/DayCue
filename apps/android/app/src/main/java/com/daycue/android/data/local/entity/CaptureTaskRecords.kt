package com.daycue.android.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.TaskStatus
import java.time.Instant

// 表结构与字段名与 apps/ios/Sources/DayCueCore/Schema.swift 的 v1/v2 段落逐列对齐。
// 对齐不是洁癖：以后要做双端同步时，「同一个字段在两端是不是同一个意思」是唯一能省掉大量对账解释的东西。

/**
 * capture_item：一次记录（文字/录音/图片）。
 *
 * raw_text / transcript / ocr_text 分开存而不是合并成 content，是因为它们的可信度不同：
 * user_edited=1 时 raw_text 是用户亲手改的，晚到的识别结果只能写进 transcript，不能覆盖它。
 */
@Entity(
    tableName = "capture_item",
    indices = [
        Index(value = ["status"]),
        Index(value = ["recorded_at"]),
    ],
)
data class CaptureItemRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "kind") val kind: CaptureKind,
    @ColumnInfo(name = "raw_text") val rawText: String? = null,
    @ColumnInfo(name = "transcript") val transcript: String? = null,
    @ColumnInfo(name = "ocr_text") val ocrText: String? = null,
    @ColumnInfo(name = "user_edited") val userEdited: Boolean = false,
    @ColumnInfo(name = "media_path") val mediaPath: String? = null,
    @ColumnInfo(name = "recorded_at") val recordedAt: Instant,
    /** IANA 时区名，例如 Asia/Shanghai。解析「明晚八点」时必须用它，不能用设备当前时区。 */
    @ColumnInfo(name = "recorded_timezone") val recordedTimezone: String,
    @ColumnInfo(name = "status") val status: CaptureStatus,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/**
 * task：App 内待办。Android 端不假定任何系统级待办 API，这里就是主库。
 *
 * due_local 与 due_utc 并存不是冗余：kind=date 时只有 due_local（YYYY-MM-DD），
 * due_utc 必须为 null——补一个 UTC 午夜会让「周五之前」变成「周五 08:00 提醒」。
 */
@Entity(
    tableName = "task",
    indices = [
        Index(value = ["status"]),
        Index(value = ["external_write_state"]),
        Index(value = ["origin_capture_id"]),
        Index(value = ["due_utc"]),
    ],
)
data class TaskRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "detail") val detail: String? = null,
    @ColumnInfo(name = "status") val status: TaskStatus = TaskStatus.OPEN,
    @ColumnInfo(name = "due_kind") val dueKind: DueKind = DueKind.NONE,
    @ColumnInfo(name = "due_local") val dueLocal: String? = null,
    @ColumnInfo(name = "due_utc") val dueUtc: Instant? = null,
    @ColumnInfo(name = "timezone") val timezone: String,
    @ColumnInfo(name = "remind_local") val remindLocal: String? = null,
    @ColumnInfo(name = "remind_utc") val remindUtc: Instant? = null,
    @ColumnInfo(name = "course_hint") val courseHint: String? = null,
    @ColumnInfo(name = "origin_capture_id") val originCaptureId: String? = null,
    @ColumnInfo(name = "origin_item_id") val originItemId: String? = null,
    @ColumnInfo(name = "external_write_state") val externalWriteState: ExternalWriteState = ExternalWriteState.NOT_REQUESTED,
    @ColumnInfo(name = "last_receipt_at") val lastReceiptAt: Instant? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
    /** 软删除：外部对账期间不能物理删，否则「外部还在、本地没了」无法解释。 */
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
) {
    /** 日期型截止日不允许有 UTC 时刻；这条不变式在写入前由仓储断言。 */
    val hasConsistentDue: Boolean
        get() = dueKind != DueKind.DATE || dueUtc == null
}
