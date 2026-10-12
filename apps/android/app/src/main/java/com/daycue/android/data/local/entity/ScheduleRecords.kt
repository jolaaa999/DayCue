package com.daycue.android.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.daycue.android.domain.model.CourseInstanceOrigin
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.FollowUpReplyKind
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.WeekParity
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime

/**
 * course：课程。
 *
 * term 是学期标识，便于一学期结束后整体归档而不删数据。
 *
 * 与 iOS Schema v2 的差异（需要主会话裁定，已记入 README）：
 * - excluded_dates：停课日。v2 用 course_instance.status=cancelled 表达已生成的实例，
 *   但「规则层面永久排除某几天」没有落点；Android 先加这一列，重新展开时直接跳过；
 * - follow_up_mode：设计文档 5.3 的「每节 / 每天首次 / 仅我标记困难后」需要存课程级策略，
 *   v2 的 follow_up_enabled 只能表达开关。
 * 两者都写成可空/带默认值，iOS 侧将来加同样的列时不会冲突。
 */
@Entity(
    tableName = "course",
    indices = [
        Index(value = ["term"]),
        Index(value = ["deleted_at"]),
    ],
)
data class CourseRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "teacher") val teacher: String? = null,
    @ColumnInfo(name = "location") val location: String? = null,
    @ColumnInfo(name = "term") val term: String? = null,
    @ColumnInfo(name = "color") val color: String? = null,
    @ColumnInfo(name = "follow_up_enabled") val followUpEnabled: Boolean = false,
    @ColumnInfo(name = "follow_up_delay_minutes") val followUpDelayMinutes: Int = 5,
    @ColumnInfo(name = "follow_up_mode", defaultValue = "every_class") val followUpMode: FollowUpMode = FollowUpMode.EVERY_CLASS,
    @ColumnInfo(name = "excluded_dates") val excludedDates: List<LocalDate> = emptyList(),
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
    @ColumnInfo(name = "deleted_at") val deletedAt: Instant? = null,
)

/**
 * course_schedule_rule：每周重复规则。
 *
 * week_parity 承担单双周，section_start/end 承担节次，两者都是「课表在纸面上长什么样」，
 * 不参与实际发生与否的判断——某次课到底上没上，只能靠 course_instance.status。
 */
@Entity(
    tableName = "course_schedule_rule",
    foreignKeys = [
        ForeignKey(
            entity = CourseRecord::class,
            parentColumns = ["id"],
            childColumns = ["course_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["course_id"]),
        Index(value = ["weekday"]),
    ],
)
data class CourseScheduleRuleRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "course_id") val courseId: String,
    /** 1=周一 .. 7=周日（ISO-8601），与 iOS schema 的 CHECK(weekday BETWEEN 1 AND 7) 一致。 */
    @ColumnInfo(name = "weekday") val weekday: Int,
    @ColumnInfo(name = "section_start") val sectionStart: Int,
    @ColumnInfo(name = "section_end") val sectionEnd: Int,
    @ColumnInfo(name = "start_time_local") val startTimeLocal: LocalTime,
    @ColumnInfo(name = "end_time_local") val endTimeLocal: LocalTime,
    @ColumnInfo(name = "week_parity") val weekParity: WeekParity = WeekParity.ALL,
    @ColumnInfo(name = "week_start") val weekStart: Int = 1,
    @ColumnInfo(name = "week_end") val weekEnd: Int = 30,
    @ColumnInfo(name = "effective_from") val effectiveFrom: LocalDate? = null,
    @ColumnInfo(name = "effective_to") val effectiveTo: LocalDate? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/**
 * course_instance：每次课一行。调课改时间，停课置 cancelled，都是改这一行。
 * 「预计结束」（ends_at_utc）只用于排通知，绝不等于实际下课，更不等于出勤。
 */
@Entity(
    tableName = "course_instance",
    foreignKeys = [
        ForeignKey(
            entity = CourseRecord::class,
            parentColumns = ["id"],
            childColumns = ["course_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["starts_at_utc"]),
        Index(value = ["course_id"]),
        Index(value = ["rule_id", "starts_at_utc"]),
    ],
)
data class CourseInstanceRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "course_id") val courseId: String,
    @ColumnInfo(name = "rule_id") val ruleId: String? = null,
    @ColumnInfo(name = "starts_at_utc") val startsAtUtc: Instant,
    @ColumnInfo(name = "ends_at_utc") val endsAtUtc: Instant,
    @ColumnInfo(name = "timezone") val timezone: String,
    @ColumnInfo(name = "status") val status: CourseInstanceStatus = CourseInstanceStatus.SCHEDULED,
    @ColumnInfo(name = "location") val location: String? = null,
    @ColumnInfo(name = "note") val note: String? = null,
    @ColumnInfo(name = "origin") val origin: CourseInstanceOrigin = CourseInstanceOrigin.RULE,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/**
 * follow_up：课后追问。一个课程实例最多一条（UNIQUE 索引兜底），避免重复打扰。
 */
@Entity(
    tableName = "follow_up",
    foreignKeys = [
        ForeignKey(
            entity = CourseInstanceRecord::class,
            parentColumns = ["id"],
            childColumns = ["course_instance_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["course_instance_id"], unique = true),
        Index(value = ["state", "scheduled_at_utc"]),
        Index(value = ["course_id"]),
    ],
)
data class FollowUpRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "course_instance_id") val courseInstanceId: String,
    @ColumnInfo(name = "course_id") val courseId: String,
    @ColumnInfo(name = "state") val state: FollowUpState = FollowUpState.SCHEDULED,
    @ColumnInfo(name = "scheduled_at_utc") val scheduledAtUtc: Instant,
    @ColumnInfo(name = "delivered_at_utc") val deliveredAtUtc: Instant? = null,
    @ColumnInfo(name = "snooze_until_utc") val snoozeUntilUtc: Instant? = null,
    @ColumnInfo(name = "attempt") val attempt: Int = 0,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "updated_at") val updatedAt: Instant,
)

/** follow_up_reply：课后回复。归档时必须能顺着 note_id / task_id 找回关联。 */
@Entity(
    tableName = "follow_up_reply",
    foreignKeys = [
        ForeignKey(
            entity = FollowUpRecord::class,
            parentColumns = ["id"],
            childColumns = ["follow_up_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [
        Index(value = ["follow_up_id"]),
        Index(value = ["course_id"]),
    ],
)
data class FollowUpReplyRecord(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "follow_up_id") val followUpId: String,
    @ColumnInfo(name = "course_id") val courseId: String,
    @ColumnInfo(name = "kind") val kind: FollowUpReplyKind,
    @ColumnInfo(name = "text") val text: String? = null,
    @ColumnInfo(name = "transcript") val transcript: String? = null,
    @ColumnInfo(name = "media_path") val mediaPath: String? = null,
    @ColumnInfo(name = "note_id") val noteId: String? = null,
    @ColumnInfo(name = "task_id") val taskId: String? = null,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
)
