package com.daycue.android.platform.outbox

/**
 * outbox 操作类型（outbox_operation.op 的取值）的单一真相来源。
 *
 * 为什么需要这张表：执行者以 op 字符串为键注册，如果字符串散落在各处，
 * 很容易出现「排了一条没有任何执行者的操作」，于是这条记录永远停在 pending。
 * 这里把「双端已声明」与「Android 已实现」分成两个集合表达，
 * 处理器据此把未实现的操作一次性推进到终止状态，而不是无限重试。
 */
object OutboxOperationKinds {

    /** 与 iOS OutboxOperationKind.createReminder 的 rawValue 一致。 */
    const val CREATE_REMINDER = "create_reminder"

    const val DELETE_REMINDER = "delete_reminder"

    /** iOS 有 update_reminder；Android 端没有对应的写入方，因此不算已实现。 */
    const val UPDATE_REMINDER = "update_reminder"

    /** 需要后端 /v1/extractions；Android 端尚未接入（见 README 的已知限制）。 */
    const val EXTRACT_CAPTURE = "extract_capture"

    /** Android 端真正注册了执行者的操作。 */
    val supported: Set<String> = setOf(CREATE_REMINDER, DELETE_REMINDER)

    /** 契约/双端已声明、但 Android 端明确未实现的操作：必须终止，不能排队等待。 */
    val declaredButUnavailable: Set<String> = setOf(UPDATE_REMINDER, EXTRACT_CAPTURE)

    fun isSupported(op: String): Boolean = op in supported

    /**
     * 终止原因。把「已声明但没接」和「完全不认识」分开说，
     * 这样看日志的人能立刻分辨是「功能没做」还是「op 字符串写错了」。
     */
    fun describeUnsupported(op: String): String = if (op in declaredButUnavailable) {
        "操作「" + op + "」在当前设备未启用：Android 端没有对应的外部提供方或后端解析能力，已停止重试。"
    } else {
        "操作「" + op + "」不是本机认识的操作类型，已停止重试（不会无限排队）。"
    }
}
