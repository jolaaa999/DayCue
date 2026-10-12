package com.daycue.android.domain.proactive

import com.daycue.android.domain.model.ProactiveState
import java.time.Instant

/**
 * 用户在主动通知上的动作。镜像 iOS 的 ProactiveInteraction，取值语义必须一致。
 *
 * 回执必须回写账本，否则「发出去了没有、用户看没看到」无从判断，
 * 预算也会因为状态停在 pending 而一直占着当天额度。
 */
enum class ProactiveInteraction(val displayName: String) {

    OPENED("已点开"),
    REPLIED("已回复"),

    /** 用户把通知划掉 / 清掉，没有点开。 */
    DISMISSED("已忽略"),

    /** 系统在通知生效前把它丢掉了（例如设备关机、超时）。 */
    EXPIRED("已过期"),

    /** 被应用主动取消（规则改了、地点删了、时间已过）。 */
    CANCELLED("已取消"),
    ;

    /**
     * 这次交互是否**证明消息确实到达了设备**。
     *
     * OPENED / REPLIED / DISMISSED 都只可能发生在用户已经看到这条通知之后，
     * 因此它们构成「到达设备」的可信证据（来自用户侧的反推，不是猜的）。
     *
     * EXPIRED / CANCELLED 是系统或应用单方面结束，**不构成任何到达证据**：
     * 极可能根本就没显示过，所以绝不能因此写下 deliveredAt。
     */
    val provesDeviceReached: Boolean
        get() = when (this) {
            OPENED, REPLIED, DISMISSED -> true
            EXPIRED, CANCELLED -> false
        }

    /**
     * 对应的账本状态。
     *
     * DISMISSED 必须映射成 DELIVERED，不能映射成 CANCELLED。这两件事完全不同：
     * - DELIVERED 是「消息已经到达设备」（用户看到后才可能划掉），要占预算；
     * - CANCELLED 是「投递前被应用取消」（规则改了、地点删了），根本没发出去，不占预算。
     *
     * 把「用户划掉已收到的通知」记成 CANCELLED 的后果很具体：账本的 deliveredAt 为空，
     * 当日额度会被**退还**，系统于是有额度继续发同类提醒——用户越划越收到，正是他想避免的。
     */
    val resultingState: ProactiveState
        get() = when (this) {
            OPENED, REPLIED, DISMISSED -> ProactiveState.DELIVERED
            EXPIRED -> ProactiveState.EXPIRED
            CANCELLED -> ProactiveState.CANCELLED
        }

    /** 写进账本的中文说明。OPENED / REPLIED 不额外解释，其余给一句可读的原因。 */
    val stateReason: String?
        get() = when (this) {
            OPENED, REPLIED -> null
            DISMISSED -> "用户忽略了这条通知，不再等它。"
            EXPIRED -> "这条主动提醒已经过期，没有发出。"
            CANCELLED -> "这条主动提醒已被取消。"
        }
}

/** 一次交互回执。dedupeKey 是账本的定位键，适配层从通知的 extras 里取。 */
data class ProactiveInteractionReceipt(
    val dedupeKey: String,
    val interaction: ProactiveInteraction,
    /** 交互发生的时刻，由适配层显式传入。 */
    val at: Instant,
)

/** 回执落账的结果。 */
data class ProactiveReceiptOutcome(
    val dedupeKey: String,
    val state: ProactiveState,
    val reason: String?,
    val deliveredAt: Instant?,
    /** 是否真的改了账本。账本里没有这条记录时必须为 false，绝不凭空造一条「已发出」。 */
    val applied: Boolean,
)
