package com.daycue.android.platform.outbox

import com.daycue.android.domain.model.OutboxState

/**
 * 终止态兜底。
 *
 * dead_letter / cancelled 是本次为 Android 端补的语义（需要主会话在 DomainModels.kt
 * 的 OutboxState 里加两个取值，见报告）。在枚举还没有这两个取值时退回既有的 failed：
 * failed 在 Android 的可执行查询（只认 pending）里同样不是待执行状态，
 * 因此**不会**被无限重试，原因也照样写进 last_error。
 *
 * 这样即使枚举改动没有落地，也不会出现「写入了枚举不认识的 raw 字符串 →
 * 下次 fromRaw 抛异常」这种读库崩溃。
 */
object OutboxTerminalStates {

    const val DEAD_LETTER_RAW = "dead_letter"
    const val CANCELLED_RAW = "cancelled"

    val deadLetter: OutboxState =
        OutboxState.entries.firstOrNull { it.raw == DEAD_LETTER_RAW } ?: OutboxState.FAILED

    val cancelled: OutboxState =
        OutboxState.entries.firstOrNull { it.raw == CANCELLED_RAW } ?: OutboxState.FAILED
}
