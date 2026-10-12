package com.daycue.android.domain.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// 本文件是 apps/ios/Sources/DayCueCore/DomainModels.swift 在 Kotlin 侧的镜像。
// 规则：枚举的取值（raw）必须与 iOS 的 rawValue、SQLite 的 CHECK 约束三方一致，
// 一旦发布就不能改——它们是已经写进用户设备数据里的字符串。

/** 用户修订优先于任何晚到的机器识别结果。iOS 用 userEdited 承担同一语义。 */
interface UserEditable {
    val userEdited: Boolean
}

// ---------------- 捕获 ----------------

enum class CaptureKind(val raw: String, val displayName: String) {
    TEXT("text", "文字"),
    AUDIO("audio", "录音"),
    IMAGE("image", "图片"),
    ;

    companion object {
        fun fromRaw(raw: String): CaptureKind = entries.first { it.raw == raw }
    }
}

/** 捕获项在本地的处理状态。先显示 local（已保存），随后才是解析中的状态。 */
enum class CaptureStatus(val raw: String, val displayName: String) {
    LOCAL("local", "已保存到本机"),
    EXTRACTING("extracting", "解析中"),
    EXTRACTED("extracted", "解析完成"),
    FAILED("failed", "解析失败"),
    NEEDS_CLARIFICATION("needs_clarification", "需要澄清"),
    ;

    /** 只有这两个状态允许重试解析；已经解析完的重复解析会产生重复候选。 */
    val isRetryable: Boolean get() = this == LOCAL || this == FAILED

    companion object {
        fun fromRaw(raw: String): CaptureStatus = entries.first { it.raw == raw }
    }
}

enum class ProposalStatus(val raw: String, val displayName: String) {
    PENDING("pending", "待确认"),
    ACCEPTED("accepted", "已确认"),
    REJECTED("rejected", "已忽略"),
    NEEDS_CLARIFICATION("needs_clarification", "需要澄清"),
    ;

    companion object {
        fun fromRaw(raw: String): ProposalStatus = entries.first { it.raw == raw }
    }
}

/** 解析模式。fixture 是后端显式启用的模拟结果，UI 必须标注「模拟结果」。 */
@Serializable
enum class ExtractionMode {
    @SerialName("live")
    LIVE,

    @SerialName("fixture")
    FIXTURE,
    ;

    val displayName: String get() = if (this == FIXTURE) "模拟结果" else "真实解析"
}

/** 候选条目类型。只有行动意图才是 task，其余一律是 note。 */
@Serializable
enum class ProposalItemKind {
    @SerialName("task")
    TASK,

    @SerialName("note")
    NOTE,
}

// ---------------- 任务 ----------------

enum class TaskStatus(val raw: String, val displayName: String) {
    OPEN("open", "待办"),
    DONE("done", "已完成"),
    CANCELLED("cancelled", "已取消"),
    ;

    companion object {
        fun fromRaw(raw: String): TaskStatus = entries.first { it.raw == raw }
    }
}

/** 截止时间的形态。date 型只有年月日，绝不能补一个假的 UTC 午夜。 */
@Serializable
enum class DueKind {
    @SerialName("none")
    NONE,

    @SerialName("date")
    DATE,

    @SerialName("datetime")
    DATETIME,
}

/**
 * 外部写入状态机。
 *
 * 写成枚举而不是若干布尔，是因为「等待授权 / 等待写入 / 已写入 / 失败 / 未知 / 待对账」
 * 必须互斥；iOS 侧同名的 ExternalWriteState 是这条状态机的唯一真相来源。
 */
enum class ExternalWriteState(val raw: String, val displayName: String) {
    NOT_REQUESTED("not_requested", "仅保存在 App"),
    WAITING_FOR_PERMISSION("waiting_for_permission", "等待授权"),
    PENDING("pending", "等待写入"),
    WRITTEN("written", "已写入"),
    FAILED("failed", "写入失败"),
    UNKNOWN("unknown", "写入状态未知，待对账"),
    NEEDS_RECONCILIATION("needs_reconciliation", "写入状态待对账"),
    ;

    /** 需要出现在「同步异常」分区：不是「没请求过」，也不是「写好了」。 */
    val needsAttention: Boolean
        get() = this != NOT_REQUESTED && this != WRITTEN

    /** 只有 pending 允许被启动恢复流程自动重试；unknown 必须走对账，不能直接重写。 */
    val isRetryable: Boolean get() = this == PENDING

    companion object {
        fun fromRaw(raw: String): ExternalWriteState = entries.first { it.raw == raw }
    }
}

// ---------------- 笔记 ----------------

enum class NoteOriginKind(val raw: String, val displayName: String) {
    CAPTURE("capture", "记录"),
    FOLLOW_UP("follow_up", "课后回复"),
    MANUAL("manual", "手动创建"),
    MEMORY("memory", "记忆"),
    ;

    companion object {
        fun fromRaw(raw: String): NoteOriginKind = entries.first { it.raw == raw }
    }
}

// ---------------- 课表 ----------------

/** 单双周。week_parity 只描述纸面规则，不代表某次课真的上了。 */
enum class WeekParity(val raw: String, val displayName: String) {
    ALL("all", "每周"),
    ODD("odd", "单周"),
    EVEN("even", "双周"),
    ;

    /** 第 week 周是否命中本规则。week 从 1 开始。 */
    fun matchesWeek(week: Int): Boolean = when (this) {
        ALL -> true
        ODD -> week % 2 == 1
        EVEN -> week % 2 == 0
    }

    companion object {
        fun fromRaw(raw: String): WeekParity = entries.first { it.raw == raw }
    }
}

enum class CourseInstanceStatus(val raw: String, val displayName: String) {
    SCHEDULED("scheduled", "正常"),
    CANCELLED("cancelled", "停课"),
    RESCHEDULED("rescheduled", "调课"),
    ;

    companion object {
        fun fromRaw(raw: String): CourseInstanceStatus = entries.first { it.raw == raw }
    }
}

enum class CourseInstanceOrigin(val raw: String, val displayName: String) {
    RULE("rule", "由课表生成"),
    MANUAL("manual", "手动添加"),
    ICS("ics", "ICS 导入"),
    OCR("ocr", "图片识别"),
    ;

    companion object {
        fun fromRaw(raw: String): CourseInstanceOrigin = entries.first { it.raw == raw }
    }
}

// ---------------- 课后追问 ----------------

enum class FollowUpState(val raw: String, val displayName: String) {
    SCHEDULED("scheduled", "已安排"),
    DELIVERED("delivered", "已发出"),
    SNOOZED("snoozed", "稍后提醒"),
    SKIPPED("skipped", "已跳过"),
    ANSWERED("answered", "已回复"),
    EXPIRED("expired", "已过期"),
    CANCELLED("cancelled", "已取消"),
    ;

    /**
     * 终态不允许再被调度器拾取。
     * 少了这条判断就会出现「用户点了跳过后又被追问」——设计文档第 5.3 节明确禁止。
     */
    val isTerminal: Boolean
        get() = this == ANSWERED || this == SKIPPED || this == EXPIRED || this == CANCELLED

    /**
     * 是不是「已经打扰过用户」。
     * 用来判断每天最多一次的课后追问预算是否已被消耗——仅 scheduled 不算消耗，
     * 否则一旦提前排出明天的追问，今天就再也排不了。
     */
    val countsAsDelivered: Boolean get() = this == DELIVERED || this == ANSWERED

    companion object {
        fun fromRaw(raw: String): FollowUpState = entries.first { it.raw == raw }
    }
}

enum class FollowUpReplyKind(val raw: String, val displayName: String) {
    TEXT("text", "文字"),
    AUDIO("audio", "语音"),
    ;

    companion object {
        fun fromRaw(raw: String): FollowUpReplyKind = entries.first { it.raw == raw }
    }
}

/** 追问的触发策略。对应设计文档 5.3 的「每节 / 每天首次 / 仅我标记困难后」。 */
enum class FollowUpMode(val raw: String, val displayName: String) {
    EVERY_CLASS("every_class", "每节课后"),
    FIRST_OF_DAY("first_of_day", "每天首次"),
    MANUAL_ONLY("manual_only", "仅我标记困难后"),
    ;

    companion object {
        fun fromRaw(raw: String): FollowUpMode = entries.first { it.raw == raw }
    }
}

// ---------------- 记忆 ----------------

enum class MemoryStatus(val raw: String, val displayName: String) {
    CANDIDATE("candidate", "待确认"),
    CONFIRMED("confirmed", "已确认"),
    RETIRED("retired", "已失效"),
    CONFLICT("conflict", "存在冲突"),
    ;

    companion object {
        fun fromRaw(raw: String): MemoryStatus = entries.first { it.raw == raw }
    }
}

enum class MemorySourceKind(val raw: String, val displayName: String) {
    USER_SETTING("user_setting", "用户设置"),
    USER_STATEMENT("user_statement", "用户表述"),
    INFERRED("inferred", "系统推断"),
    ;

    /** 推断永远不能对外表述成事实，界面必须带「推断」标注。 */
    val isFact: Boolean get() = this != INFERRED

    companion object {
        fun fromRaw(raw: String): MemorySourceKind = entries.first { it.raw == raw }
    }
}

// ---------------- 地点与主动消息 ----------------

enum class PlaceTrigger(val raw: String, val displayName: String) {
    ENTER("enter", "进入时"),
    EXIT("exit", "离开时"),
    DWELL("dwell", "停留一段时间后"),
    ;

    companion object {
        fun fromRaw(raw: String): PlaceTrigger = entries.first { it.raw == raw }
    }
}

enum class ProactiveKind(val raw: String, val displayName: String) {
    FOLLOW_UP("follow_up", "课后追问"),
    GEO("geo", "地点提醒"),
    SCHEDULE("schedule", "课表变化"),
    REVIEW("review", "每日回顾"),
    REMINDER("reminder", "任务提醒"),
    ;

    /**
     * 只有前四类算「自主建议」，计入打扰预算。
     * 用户明确设定时刻的任务提醒不计入——它是用户自己要的，不是 App 主动找上来的。
     */
    val countsTowardBudget: Boolean get() = this != REMINDER

    companion object {
        fun fromRaw(raw: String): ProactiveKind = entries.first { it.raw == raw }
    }
}

enum class ProactiveState(val raw: String, val displayName: String) {
    PENDING("pending", "待发出"),
    DELIVERED("delivered", "已发出"),
    SUPPRESSED("suppressed", "已抑制"),
    EXPIRED("expired", "已过期"),
    CANCELLED("cancelled", "已取消"),
    ;

    /** 已抑制与已取消允许同 dedupe_key 重新建一条（例如用户改回偏好后又想收到）。 */
    val blocksNewCandidate: Boolean
        get() = this == PENDING || this == DELIVERED || this == SUPPRESSED

    companion object {
        fun fromRaw(raw: String): ProactiveState = entries.first { it.raw == raw }
    }
}

// ---------------- Outbox ----------------

enum class OutboxState(val raw: String, val displayName: String) {
    PENDING("pending", "待执行"),
    RUNNING("running", "执行中"),
    SUCCEEDED("succeeded", "已完成"),
    FAILED("failed", "失败"),
    UNKNOWN("unknown", "结果未知，待对账"),
    ;

    /** 只有 pending 能被后台作业重试。running 说明进程上次中断，需要先对账再决定。 */
    val isExecutable: Boolean get() = this == PENDING

    companion object {
        fun fromRaw(raw: String): OutboxState = entries.first { it.raw == raw }
    }
}
