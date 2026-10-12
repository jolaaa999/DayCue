package com.daycue.android.data.repository

import com.daycue.android.domain.location.GeoDedupeKey
import com.daycue.android.domain.location.GeoEventHandling
import com.daycue.android.domain.location.GeoMonitoredPlace
import com.daycue.android.domain.location.GeoNotificationRequest
import com.daycue.android.domain.location.GeoNotificationScheduleResult
import com.daycue.android.domain.location.GeoNotificationScheduler
import com.daycue.android.domain.location.GeoPlaceSpec
import com.daycue.android.domain.location.GeoRegistrationPlan
import com.daycue.android.domain.location.GeoRegistrationPlanner
import com.daycue.android.domain.location.GeoRuleCatalog
import com.daycue.android.domain.location.GeoRuleReadiness
import com.daycue.android.domain.location.GeoRuleReadinessEvaluator
import com.daycue.android.domain.location.GeoRuleSpec
import com.daycue.android.domain.location.GeoRuleSwitchMemory
import com.daycue.android.domain.location.GeoState
import com.daycue.android.domain.location.GeoTriggerDeferral
import com.daycue.android.domain.location.GeoTriggerPlanner
import com.daycue.android.domain.location.GeoTriggerResult
import com.daycue.android.domain.location.GeoTriggerRunOutcome
import com.daycue.android.domain.location.GeoTriggerSkip
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.location.LocationEventDiscard
import com.daycue.android.domain.location.LocationEventNormalization
import com.daycue.android.domain.location.LocationEventNormalizer
import com.daycue.android.domain.location.LocationEventSource
import com.daycue.android.domain.location.LocationFreshnessPolicy
import com.daycue.android.domain.location.LocationRuleSwitch
import com.daycue.android.domain.location.LocationSemanticEvent
import com.daycue.android.domain.location.ProactiveLedger
import com.daycue.android.domain.location.ProactiveNotificationIdentifier
import com.daycue.android.domain.location.RawLocationObservation
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.BudgetDecision
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.domain.proactive.ProactiveCandidate
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * 地点事件的完整落地：新鲜度 -> 规则求值 -> 预算 -> 真安排通知。
 *
 * 谁调用它：系统的围栏广播接收者、停留复查接收者、界面恢复路径（MainActivity.onResume）、
 * 以及开机重建。它们都只做一件事——把「发生了什么」告诉这里，其余判断全在这一层。
 *
 * 为什么编排放在数据 / 平台之间而不是界面层：这样测试可以注入一整套替身，
 * 断言「抑制时通知安排器真的没被调用」「撤销后真的调用了 stopMonitoring」，
 * 而不是只看到一个算出来的枚举值。
 */
class GeoProactiveCoordinator(
    private val rules: GeoRuleCatalog,
    private val ledger: ProactiveLedger,
    private val notifier: GeoNotificationScheduler,
    private val source: LocationEventSource,
    private val ruleSwitch: LocationRuleSwitch,
    private val switchMemory: GeoRuleSwitchMemory,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    /**
     * 处理一条原始观测。
     *
     * 顺序是刻意的：总开关 -> 新鲜度 -> 规则 -> 预算 -> 通知。任何一步不通过都不会走到后面，
     * 因此「没有安排通知」永远有一个可读的原因，而不是静默消失。
     */
    suspend fun handleObservation(
        observation: RawLocationObservation,
        zone: ZoneId,
        freshness: LocationFreshnessPolicy = LocationFreshnessPolicy.STANDARD,
        budget: BudgetPolicy = BudgetPolicy(),
        now: Instant = timeSource.now(),
    ): GeoEventHandling {

        if (!ruleSwitch.isEnabled()) {
            return discarded(observation.placeId, "位置规则总开关未打开，本次位置事件不触发任何规则。", false, now)
        }

        return when (val normalization = LocationEventNormalizer.normalize(observation, now, freshness)) {
            is LocationEventNormalization.Discarded ->
                discarded(observation.placeId, normalization.reason, normalization.isSilent, now)

            is LocationEventNormalization.Accepted ->
                GeoEventHandling(
                    accepted = true,
                    discard = null,
                    run = runRules(normalization.event, zone, budget, now),
                )
        }
    }

    /** 系统围栏广播的入口。系统只说「进了 / 出了」，坐标与时刻由事件源补齐。 */
    suspend fun onProximityTransition(
        placeId: String,
        entering: Boolean,
        zone: ZoneId,
        freshness: LocationFreshnessPolicy = LocationFreshnessPolicy.STANDARD,
        budget: BudgetPolicy = BudgetPolicy(),
        now: Instant = timeSource.now(),
    ): GeoEventHandling {
        // 迟到的广播：用户可能已经删掉规则，围栏也已经被取消。
        // 没有这道判断，被删掉的规则仍会因为一条迟到的广播响一次，这正是「野监控」的表现。
        if (placeId !in source.monitoredPlaceIds) {
            return discarded(placeId, "该地点的监控已取消，忽略迟到的围栏事件。", false, now)
        }
        return handleObservation(source.proximityObservation(placeId, entering, now), zone, freshness, budget, now)
    }

    /**
     * 停留规则的到点复查。
     *
     * 复查不是「默认还在里面」：必须用系统最近一次定位重新判断，
     * 拿不到可用定位就如实丢弃，宁可这条停留提醒不发，也不要发错地点。
     */
    suspend fun onDwellRecheck(
        placeId: String,
        zone: ZoneId,
        freshness: LocationFreshnessPolicy = LocationFreshnessPolicy.STANDARD,
        budget: BudgetPolicy = BudgetPolicy(),
        now: Instant = timeSource.now(),
    ): GeoEventHandling {
        if (placeId !in source.monitoredPlaceIds) {
            return discarded(placeId, "该地点的监控已取消，忽略迟到的停留复查。", false, now)
        }
        val observation = source.currentObservation(placeId, now)
            ?: return discarded(
                placeId,
                "拿不到可用的定位，无法确认是否仍在围栏内，本次停留判断已跳过。",
                true,
                now,
            )
        return handleObservation(observation, zone, freshness, budget, now)
    }

    /**
     * 前台补偿检查：把「当前是否在围栏内」和事件源记住的上一次状态比一次。
     *
     * 为什么需要它：系统围栏事件在部分机型上会被省电策略丢掉，App 打开时用最近一次定位补一次，
     * 能救回「已经到家但没收到进入事件」的场景。它同样要过新鲜度：陈旧坐标不作数。
     */
    suspend fun evaluateCurrentFix(
        zone: ZoneId,
        freshness: LocationFreshnessPolicy = LocationFreshnessPolicy.STANDARD,
        budget: BudgetPolicy = BudgetPolicy(),
        now: Instant = timeSource.now(),
    ): List<GeoEventHandling> {
        val handlings = ArrayList<GeoEventHandling>()
        for (placeId in source.monitoredPlaceIds.sorted()) {
            val observation = source.currentObservation(placeId, now) ?: continue
            handlings += handleObservation(observation, zone, freshness, budget, now)
        }
        return handlings
    }

    /**
     * 注册对账 + 能力同步。规则增删改、权限变化、开机恢复、界面回到前台都调用它。
     *
     * 返回值就是「现在每条规则会不会触发、为什么」的权威答案，界面直接拿它展示。
     */
    suspend fun refreshRegistration(
        capability: LocationCapability? = null,
        now: Instant = timeSource.now(),
    ): GeoRegistrationPlan {

        val locationRulesEnabled = ruleSwitch.isEnabled()
        val current = capability ?: source.refreshCapability()

        var all = rules.allRules()

        if (current.isUsable) {
            // 能力恢复时把用户原本开着的规则放回来。
            //
            // 这里曾经有一个真实缺陷：原实现只写记忆、不恢复规则。
            // 于是「权限被撤销 -> 恢复」之后，规则此刻还全是暂停状态，
            // 写进记忆的就是一个**空集合**；记忆一旦被抹掉，用户的规则永远回不来，
            // 而且没有任何报错——用户只会觉得「我明明开着，它就是不再提醒了」。
            //
            // 判据「有记忆 + 当前一条都没开」正是我们上次因能力不可用而全部暂停留下的签名；
            // 顺序必须先恢复、后写记忆，反过来就会把空集合写回去。
            //
            // 前提：当前界面不允许在定位不可用时单独改某条规则的开关
            // （设置页的开关以 locationUsable 为前提）。将来若开放该入口，
            // 用户改动规则的路径必须同步更新这份记忆，否则手动关掉的规则会被这里误开。
            val remembered = switchMemory.read()
            val currentlyEnabled = all.filter { it.enabled }.map { it.id }.toSet()
            if (remembered.isNotEmpty() && currentlyEnabled.isEmpty()) {
                rules.syncAvailability(current, remembered)
                // 重新读一次：readiness 必须反映刚恢复的 enabled，否则界面会显示成「还在暂停」。
                all = rules.allRules()
            }
            switchMemory.write(all.filter { it.enabled }.map { it.id }.toSet())
        } else if (locationRulesEnabled) {
            // 能力不可用时把规则全部暂停，但先把「用户原本开着哪些」记牢。
            val remembered = switchMemory.read()
            val wanted = remembered.ifEmpty { all.filter { it.enabled }.map { it.id }.toSet() }
            switchMemory.write(wanted)
            rules.syncAvailability(current, wanted)
            // 重新读一次：readiness 必须反映刚写入的 enabled，否则界面会显示成「还在正常运行」。
            all = rules.allRules()
        }

        val plan = GeoRegistrationPlanner.plan(
            rules = all,
            placesById = rules.placesById(),
            capability = current,
            locationRulesEnabled = locationRulesEnabled,
            currentlyMonitoredPlaceIds = source.monitoredPlaceIds,
            now = now,
        )

        if (plan.placeIdsToStopMonitoring.isNotEmpty()) {
            source.stopMonitoring(plan.placeIdsToStopMonitoring)
            for (placeId in plan.placeIdsToStopMonitoring) {
                source.cancelDwellRecheck(placeId)
            }
        }
        if (plan.placesToStartMonitoring.isNotEmpty()) {
            source.startMonitoring(plan.placesToStartMonitoring)
        }
        return plan
    }

    /** 规则或地点变化后的重新注册。与 refreshRegistration 同一入口，单独命名是为了让调用点读起来是意图。 */
    suspend fun onRuleChanged(now: Instant = timeSource.now()): GeoRegistrationPlan =
        refreshRegistration(now = now)

    /**
     * 规则被删除后的收尾：取消它还没发出的通知，再重新注册。
     *
     * 只取消围栏而不取消已排的通知是不够的——用户删了规则，几分钟后仍然收到那条提醒，
     * 会让人以为删除没生效。
     */
    suspend fun onRulesRemoved(ruleIds: List<String>, now: Instant = timeSource.now()): GeoRegistrationPlan {
        for (ruleId in ruleIds) {
            for (row in ledger.pendingForRule(ruleId)) {
                notifier.cancel(ProactiveNotificationIdentifier.identifierFor(row.dedupeKey))
                ledger.markCancelled(row.id)
            }
        }
        return refreshRegistration(now = now)
    }

    /** 只读的可触发状态查询，供界面展示「为什么这条规则现在不会触发」。 */
    suspend fun readiness(
        capability: LocationCapability? = null,
        locationRulesEnabled: Boolean? = null,
        now: Instant = timeSource.now(),
    ): List<GeoRuleReadiness> {
        val enabled = locationRulesEnabled ?: ruleSwitch.isEnabled()
        val current = capability ?: source.capability
        val places = rules.placesById()
        return rules.allRules().map { rule ->
            GeoRuleReadinessEvaluator.evaluate(rule, places[rule.placeId], current, enabled, now)
        }
    }

    // ---- 内部 ----

    private suspend fun runRules(
        event: LocationSemanticEvent,
        zone: ZoneId,
        budget: BudgetPolicy,
        now: Instant,
    ): GeoTriggerRunOutcome {

        val evaluationRules = rules.rulesForEvaluation()
        val places = rules.placesById()

        // 冷却要看得到昨晚发出的那条：只取当天会漏判「刚过零点又触发」。
        val lastDelivered = ledger.ledgerSince(now.minus(2, ChronoUnit.DAYS))
            .filter { it.kind == ProactiveKind.GEO && it.deliveredAt != null && it.cooldownKey != null }
            .groupBy { it.cooldownKey!! }
            .mapValues { (_, rows) -> rows.maxOf { it.deliveredAt!! } }

        val plan = GeoTriggerPlanner.plan(
            event = event,
            rules = evaluationRules,
            placesById = places,
            lastDeliveredByRuleId = lastDelivered,
            now = now,
            zone = zone,
        )

        val results = ArrayList<GeoTriggerResult>()
        var notifierCallCount = 0

        for (candidate in plan.candidates) {
            val ledgerCandidate = ProactiveCandidate(
                dedupeKey = candidate.dedupeKey,
                kind = ProactiveKind.GEO,
                scheduledAt = now,
                expiresAt = candidate.rule.expiresAt,
                cooldownKey = candidate.rule.id,
            )
            // 冷却归 GeoRuleEvaluator（已在此前的计划里判过），这里只判额度 / 静默 / 去重，
            // 所以 cooldownMinutes 传 0，避免同一个约束被两个地方各判一次、口径还不同。
            val decision = ledger.evaluate(ledgerCandidate, now, zone, budget, cooldownMinutes = 0)
            val recordId = ledger.record(ledgerCandidate, decision, now)

            when (decision) {
                is BudgetDecision.Deliver -> {
                    notifierCallCount += 1
                    val identifier = ProactiveNotificationIdentifier.identifierFor(candidate.dedupeKey)
                    val outcome = notifier.schedule(
                        GeoNotificationRequest(
                            dedupeKey = candidate.dedupeKey,
                            identifier = identifier,
                            title = candidate.rule.title,
                            body = candidate.rule.body,
                            fireAt = decision.at,
                            targetRef = candidate.rule.id,
                        ),
                    )
                    when (outcome) {
                        is GeoNotificationScheduleResult.Scheduled ->
                            results += GeoTriggerResult(
                                ruleId = candidate.rule.id,
                                dedupeKey = candidate.dedupeKey,
                                state = ProactiveState.PENDING,
                                scheduledAt = decision.at,
                                reason = candidate.reason,
                                notifierCalled = true,
                                notifierOutcome = null,
                            )

                        is GeoNotificationScheduleResult.NotScheduled -> {
                            // 安排失败不能留一条「等待发出」的假记录，落成 cancelled 并写明原因。
                            if (recordId != null) ledger.markCancelled(recordId)
                            results += GeoTriggerResult(
                                ruleId = candidate.rule.id,
                                dedupeKey = candidate.dedupeKey,
                                state = ProactiveState.CANCELLED,
                                scheduledAt = decision.at,
                                reason = outcome.reason,
                                notifierCalled = true,
                                notifierOutcome = outcome.reason,
                            )
                        }
                    }
                }

                is BudgetDecision.Suppressed ->
                    results += GeoTriggerResult(
                        ruleId = candidate.rule.id,
                        dedupeKey = candidate.dedupeKey,
                        state = ProactiveState.SUPPRESSED,
                        scheduledAt = decision.until ?: now,
                        reason = decision.reason.displayName,
                        notifierCalled = false,
                        notifierOutcome = null,
                    )

                is BudgetDecision.Expired ->
                    results += GeoTriggerResult(
                        ruleId = candidate.rule.id,
                        dedupeKey = candidate.dedupeKey,
                        state = ProactiveState.EXPIRED,
                        scheduledAt = now,
                        reason = decision.reason,
                        notifierCalled = false,
                        notifierOutcome = null,
                    )
            }
        }

        // 停留规则的到点复查：同一个地点只留最早那一次，复查时会重新评估该地点上的全部停留规则。
        plan.deferrals
            .groupBy { it.placeId }
            .forEach { (placeId, deferrals) ->
                val earliest = deferrals.minByOrNull { it.until } ?: return@forEach
                source.scheduleDwellRecheck(placeId, earliest.until)
            }

        return GeoTriggerRunOutcome(
            results = results,
            skips = plan.skips,
            deferrals = plan.deferrals,
            notifierCallCount = notifierCallCount,
        )
    }

    private fun discarded(placeId: String, reason: String, isSilent: Boolean, now: Instant) = GeoEventHandling(
        accepted = false,
        discard = LocationEventDiscard(placeId = placeId, reason = reason, isSilent = isSilent, at = now),
        run = null,
    )
}
