package com.daycue.android.domain.location

import com.daycue.android.domain.model.ProactiveState
import java.time.Instant
import java.time.ZoneId

/**
 * 主动通知标识的唯一生成处。
 *
 * 主动提醒用独立前缀，与 ReminderScheduler 的任务提醒（task:）与课后追问（follow_up:）互不干扰：
 * 三条路径各自取消自己的通知，不会误删对方排的提醒。
 */
object ProactiveNotificationIdentifier {

    const val PREFIX = "daycue.proactive."

    fun identifierFor(dedupeKey: String): String = PREFIX + dedupeKey
}

/** 一条待安排的主动通知。fireAt 可能是被静默时段顺延后的时刻。 */
data class GeoNotificationRequest(
    val dedupeKey: String,
    val identifier: String,
    val title: String,
    val body: String?,
    val fireAt: Instant,
    val targetRef: String?,
)

/** 安排结果。不能安排时必须给出中文原因，账本要如实记录。 */
sealed interface GeoNotificationScheduleResult {

    data class Scheduled(val identifier: String, val at: Instant) : GeoNotificationScheduleResult

    data class NotScheduled(val reason: String) : GeoNotificationScheduleResult
}

/**
 * 通知安排器。实现方可以是系统 AlarmManager / NotificationManager，也可以是测试替身。
 *
 * 做成接口是为了让「被预算抑制时通知安排环节真的没被调用」这件事可测：
 * 测试注入一个记录调用次数的替身，就能证明抑制不是只算出一个 decision。
 */
interface GeoNotificationScheduler {

    suspend fun schedule(request: GeoNotificationRequest): GeoNotificationScheduleResult

    suspend fun cancel(identifier: String)
}

/**
 * 地点规则的幂等键。
 *
 * Android 的 GeoRuleEvaluator 只返回 ruleId（与 iOS 不同，iOS 连幂等键一起返回），
 * 所以在这里补上「同一次触发场合」的编码：一次进入/停留由「进入时刻」唯一标识，
 * 离开则由「这次离开所结束的那次进入」标识。
 * 用 observedAt 当键会让同一次停留的每次复查都算新事件，重复打扰；用场合键才不会。
 */
object GeoDedupeKey {

    fun forOccasion(ruleId: String, occasionAt: Instant): String =
        "geo:" + ruleId + ":" + occasionAt.epochSecond
}

/** 参与求值的一条规则被跳过的原因。 */
data class GeoTriggerSkip(
    val ruleId: String,
    val reason: String,
    /** true 表示因为位置不可信而静默降级，界面必须与「没到条件」区分开。 */
    val isSilent: Boolean,
)

/** 通过规则求值、尚未过预算的候选。 */
data class GeoTriggerCandidate(
    val rule: GeoRuleSpec,
    val dedupeKey: String,
    val reason: String,
)

/** 停留规则尚未到点，需要到点复查一次。 */
data class GeoTriggerDeferral(
    val ruleId: String,
    val placeId: String,
    val until: Instant,
    val reason: String,
)

/** 纯计算的规则求值结果：哪些进入预算环节、哪些被跳过、哪些需要复查。 */
data class GeoTriggerPlan(
    val candidates: List<GeoTriggerCandidate>,
    val skips: List<GeoTriggerSkip>,
    val deferrals: List<GeoTriggerDeferral>,
)

/**
 * 规则求值的纯逻辑。不碰数据库、不读时钟、不发通知。
 *
 * 触发条件与冷却在 GeoRuleEvaluator；预算、静默、去重由调用方接着用 ProactiveLedger 处理。
 * 两者不重叠：冷却归 GeoRuleEvaluator（它已经按 rule.cooldownSeconds 判），
 * 每日额度 / 静默 / 去重归 ProactiveBudget，一个关注点只有一个负责人。
 */
object GeoTriggerPlanner {

    fun plan(
        event: LocationSemanticEvent,
        rules: List<GeoRuleSpec>,
        placesById: Map<String, GeoPlaceSpec>,
        lastDeliveredByRuleId: Map<String, Instant>,
        now: Instant,
        zone: ZoneId,
    ): GeoTriggerPlan {

        val candidates = ArrayList<GeoTriggerCandidate>()
        val skips = ArrayList<GeoTriggerSkip>()
        val deferrals = ArrayList<GeoTriggerDeferral>()

        for (rule in rules) {
            // 只评估「事件地点上的、且触发条件与事件同类」的规则。
            // 一次进入不该去评估「离开时」规则，否则每类规则都会各判一遍，结论必然错。
            if (rule.placeId != event.placeId) continue
            if (rule.trigger != event.trigger) continue

            val place = placesById[rule.placeId]
            if (place == null) {
                skips += GeoTriggerSkip(rule.id, "规则对应的地点已不存在，先重新选择地点。", isSilent = false)
                continue
            }
            if (place.deleted) {
                skips += GeoTriggerSkip(rule.id, "规则对应的地点已经删除。", isSilent = false)
                continue
            }
            if (!place.confirmedByUser) {
                skips += GeoTriggerSkip(rule.id, "这个地点还没有被确认，规则不会触发。", isSilent = false)
                continue
            }

            val state = GeoState(
                transition = event.transition,
                insideSince = event.insideSince,
                lastTriggeredAt = lastDeliveredByRuleId[rule.id],
            )
            val decision = GeoRuleEvaluator.evaluate(
                rule = rule,
                state = state,
                now = now,
                zone = zone,
                locationUsable = event.capability.isUsable,
            )

            when (decision) {
                is GeoDecision.Trigger ->
                    candidates += GeoTriggerCandidate(
                        rule = rule,
                        dedupeKey = GeoDedupeKey.forOccasion(
                            ruleId = rule.id,
                            occasionAt = event.insideSince ?: event.observedAt,
                        ),
                        reason = decision.reason,
                    )

                is GeoDecision.Defer ->
                    deferrals += GeoTriggerDeferral(
                        ruleId = rule.id,
                        placeId = rule.placeId,
                        until = decision.until,
                        reason = decision.reason,
                    )

                is GeoDecision.Suppress ->
                    skips += GeoTriggerSkip(rule.id, decision.reason, isSilent = false)

                is GeoDecision.Skip ->
                    skips += GeoTriggerSkip(
                        ruleId = rule.id,
                        reason = decision.reason,
                        isSilent = !event.capability.isUsable,
                    )
            }
        }

        return GeoTriggerPlan(candidates = candidates, skips = skips, deferrals = deferrals)
    }
}

/** 一条规则走完整条链路之后的结果，直接给界面 / 日志看。 */
data class GeoTriggerResult(
    val ruleId: String,
    val dedupeKey: String,
    val state: ProactiveState,
    val scheduledAt: Instant,
    val reason: String,
    /** 通知安排环节是否真的被调用过。抑制路径必须为 false。 */
    val notifierCalled: Boolean,
    val notifierOutcome: String?,
)

/** 一次编排的结果。notifierCallCount 用来证明抑制真的拦住了安排。 */
data class GeoTriggerRunOutcome(
    val results: List<GeoTriggerResult>,
    val skips: List<GeoTriggerSkip>,
    val deferrals: List<GeoTriggerDeferral>,
    val notifierCallCount: Int,
)

/** 一条原始观测的完整处理结果：要么在新鲜度检查处被丢弃，要么走完规则与预算链路。 */
data class GeoEventHandling(
    val accepted: Boolean,
    val discard: LocationEventDiscard?,
    val run: GeoTriggerRunOutcome?,
)
