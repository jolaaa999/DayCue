package com.daycue.android.data.local

import androidx.room.TypeConverter
import com.daycue.android.core.DayCueJson
import com.daycue.android.core.DayCueTime
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.CourseInstanceOrigin
import com.daycue.android.domain.model.CoordinateSystem
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.FollowUpReplyKind
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.domain.model.PlaceTrigger
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.domain.model.WeekParity
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/**
 * 枚举与时间在库里的存储形态。
 *
 * 两条不可让步的约定：
 * 1. 枚举一律存 iOS 的 rawValue 字符串（不是 ordinal）。存序号意味着「在枚举中间插一个值」
 *    会把所有历史数据的含义整体挪位；
 * 2. 绝对时刻一律存 RFC3339 UTC 字符串（不是 epoch 毫秒）。双端要能直接比对同一份导出数据，
 *    而 SQLite 里的可读时间串在排障时能省掉一轮换算。
 */
class DayCueConverters {

    // ---- 时间 ----

    @TypeConverter
    fun instantToUtcString(value: Instant?): String? = value?.let { DayCueTime.utcString(it) }

    @TypeConverter
    fun utcStringToInstant(value: String?): Instant? = DayCueTime.parseInstantOrNull(value)

    @TypeConverter
    fun localDateToString(value: LocalDate?): String? = value?.let { DayCueTime.localDateString(it) }

    @TypeConverter
    fun stringToLocalDate(value: String?): LocalDate? = DayCueTime.parseLocalDateOrNull(value)

    @TypeConverter
    fun localTimeToString(value: LocalTime?): String? =
        value?.format(DateTimeFormatter.ISO_LOCAL_TIME)

    @TypeConverter
    fun stringToLocalTime(value: String?): LocalTime? =
        value?.let { runCatching { LocalTime.parse(it, DateTimeFormatter.ISO_LOCAL_TIME) }.getOrNull() }

    // ---- 字符串集合 ----

    @TypeConverter
    fun stringListToJson(value: List<String>): String =
        DayCueJson.encodeToString(ListSerializer(String.serializer()), value)

    @TypeConverter
    fun jsonToStringList(value: String): List<String> =
        runCatching { DayCueJson.decodeFromString(ListSerializer(String.serializer()), value) }.getOrDefault(emptyList())

    @TypeConverter
    fun localDateListToJson(value: List<LocalDate>): String =
        DayCueJson.encodeToString(ListSerializer(String.serializer()), value.map { DayCueTime.localDateString(it) })

    @TypeConverter
    fun jsonToLocalDateList(value: String): List<LocalDate> =
        runCatching { DayCueJson.decodeFromString(ListSerializer(String.serializer()), value) }
            .getOrDefault(emptyList())
            .mapNotNull { DayCueTime.parseLocalDateOrNull(it) }

    @TypeConverter
    fun intListToJson(value: List<Int>): String =
        DayCueJson.encodeToString(ListSerializer(Int.serializer()), value)

    @TypeConverter
    fun jsonToIntList(value: String): List<Int> =
        runCatching { DayCueJson.decodeFromString(ListSerializer(Int.serializer()), value) }.getOrDefault(emptyList())

    // ---- 枚举 ----

    @TypeConverter fun captureKindToRaw(value: CaptureKind): String = value.raw
    @TypeConverter fun rawToCaptureKind(value: String): CaptureKind = CaptureKind.fromRaw(value)

    @TypeConverter fun captureStatusToRaw(value: CaptureStatus): String = value.raw
    @TypeConverter fun rawToCaptureStatus(value: String): CaptureStatus = CaptureStatus.fromRaw(value)

    @TypeConverter fun noteOriginKindToRaw(value: NoteOriginKind): String = value.raw
    @TypeConverter fun rawToNoteOriginKind(value: String): NoteOriginKind = NoteOriginKind.fromRaw(value)

    @TypeConverter fun taskStatusToRaw(value: TaskStatus): String = value.raw
    @TypeConverter fun rawToTaskStatus(value: String): TaskStatus = TaskStatus.fromRaw(value)

    @TypeConverter fun dueKindToRaw(value: DueKind): String = when (value) {
        DueKind.NONE -> "none"
        DueKind.DATE -> "date"
        DueKind.DATETIME -> "datetime"
    }

    @TypeConverter fun rawToDueKind(value: String): DueKind = when (value) {
        "date" -> DueKind.DATE
        "datetime" -> DueKind.DATETIME
        else -> DueKind.NONE
    }

    @TypeConverter fun externalWriteStateToRaw(value: ExternalWriteState): String = value.raw
    @TypeConverter fun rawToExternalWriteState(value: String): ExternalWriteState = ExternalWriteState.fromRaw(value)

    @TypeConverter fun weekParityToRaw(value: WeekParity): String = value.raw
    @TypeConverter fun rawToWeekParity(value: String): WeekParity = WeekParity.fromRaw(value)

    @TypeConverter fun courseInstanceStatusToRaw(value: CourseInstanceStatus): String = value.raw
    @TypeConverter fun rawToCourseInstanceStatus(value: String): CourseInstanceStatus = CourseInstanceStatus.fromRaw(value)

    @TypeConverter fun courseInstanceOriginToRaw(value: CourseInstanceOrigin): String = value.raw
    @TypeConverter fun rawToCourseInstanceOrigin(value: String): CourseInstanceOrigin = CourseInstanceOrigin.fromRaw(value)

    @TypeConverter fun followUpStateToRaw(value: FollowUpState): String = value.raw
    @TypeConverter fun rawToFollowUpState(value: String): FollowUpState = FollowUpState.fromRaw(value)

    @TypeConverter fun followUpReplyKindToRaw(value: FollowUpReplyKind): String = value.raw
    @TypeConverter fun rawToFollowUpReplyKind(value: String): FollowUpReplyKind = FollowUpReplyKind.fromRaw(value)

    @TypeConverter fun followUpModeToRaw(value: FollowUpMode): String = value.raw
    @TypeConverter fun rawToFollowUpMode(value: String): FollowUpMode = FollowUpMode.fromRaw(value)

    @TypeConverter fun memoryStatusToRaw(value: MemoryStatus): String = value.raw
    @TypeConverter fun rawToMemoryStatus(value: String): MemoryStatus = MemoryStatus.fromRaw(value)

    @TypeConverter fun memorySourceKindToRaw(value: MemorySourceKind): String = value.raw
    @TypeConverter fun rawToMemorySourceKind(value: String): MemorySourceKind = MemorySourceKind.fromRaw(value)

    @TypeConverter fun coordinateSystemToRaw(value: CoordinateSystem): String = value.raw

    /**
     * 解析不出已知坐标系时按 WGS84 处理，而不是抛异常。
     * 地点本身必须能读出来（否则规则与围栏都会失效），坐标系认不出来属于「按最常见的处理并保留原值」。
     */
    @TypeConverter fun rawToCoordinateSystem(value: String): CoordinateSystem =
        CoordinateSystem.fromRawOrDefault(value)

    @TypeConverter fun placeTriggerToRaw(value: PlaceTrigger): String = value.raw
    @TypeConverter fun rawToPlaceTrigger(value: String): PlaceTrigger = PlaceTrigger.fromRaw(value)

    @TypeConverter fun proactiveKindToRaw(value: ProactiveKind): String = value.raw
    @TypeConverter fun rawToProactiveKind(value: String): ProactiveKind = ProactiveKind.fromRaw(value)

    @TypeConverter fun proactiveStateToRaw(value: ProactiveState): String = value.raw
    @TypeConverter fun rawToProactiveState(value: String): ProactiveState = ProactiveState.fromRaw(value)

    @TypeConverter fun outboxStateToRaw(value: OutboxState): String = value.raw
    @TypeConverter fun rawToOutboxState(value: String): OutboxState = OutboxState.fromRaw(value)
}
