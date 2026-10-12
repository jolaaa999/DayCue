package com.daycue.android.data.repository

import com.daycue.android.domain.location.ProactiveReceiptStore
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.ProactiveInteractionReceipt
import com.daycue.android.domain.proactive.ProactiveReceiptOutcome

/**
 * 通知交互回执的落库。
 *
 * 谁调用它：通知点击 / 划掉的 BroadcastReceiver（ProactiveReceiptReceiver）。
 * 地点提醒与课后追问共用这一份状态映射，避免两条路径各写一套「点开算已发」。
 */
class ProactiveReceiptService(
    private val store: ProactiveReceiptStore,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    suspend fun apply(receipt: ProactiveInteractionReceipt): ProactiveReceiptOutcome {

        val existing = store.findReceiptRow(receipt.dedupeKey)
            ?: return ProactiveReceiptOutcome(
                dedupeKey = receipt.dedupeKey,
                state = ProactiveState.CANCELLED,
                reason = "账本里没有这条主动提醒，回执被忽略。",
                deliveredAt = null,
                applied = false,
            )

        // 终态不因迟到回执而反转：已经取消 / 过期的提醒被点开，也不能复活成 delivered 再占预算。
        if (existing.state.isTerminal) {
            return ProactiveReceiptOutcome(
                dedupeKey = receipt.dedupeKey,
                state = existing.state,
                reason = "这条主动提醒已经处于终态（" + existing.state.displayName + "），回执不再改变状态。",
                deliveredAt = existing.deliveredAt,
                applied = false,
            )
        }

        val state = receipt.interaction.resultingState

        // deliveredAt 的准确含义是「我们最后一次确认它到达了设备的时刻」，
        // 而不是「系统报告它被展示的时刻」—— Android 与 iOS 都不提供展示回执，那个时刻拿不到。
        // 这里的时间来自用户交互反推（点开 / 回复 / 划掉都证明用户看见过它），
        // 所以只在 provesDeviceReached 为真时写入；系统过期或应用取消一律留空，
        // 否则就等于把「没送到」记成「送到了」。
        val deliveredAt = if (receipt.interaction.provesDeviceReached) receipt.at else null
        store.applyInteraction(
            id = existing.id,
            state = state,
            reason = receipt.interaction.stateReason,
            deliveredAt = deliveredAt,
            at = receipt.at,
        )
        return ProactiveReceiptOutcome(
            dedupeKey = receipt.dedupeKey,
            state = state,
            reason = receipt.interaction.stateReason,
            deliveredAt = deliveredAt,
            applied = true,
        )
    }
}
