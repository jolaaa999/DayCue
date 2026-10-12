package com.daycue.android.data.repository

import com.daycue.android.domain.location.GeoLedgerRow
import com.daycue.android.domain.location.GeoMonitoredPlace
import com.daycue.android.domain.location.GeoNotificationRequest
import com.daycue.android.domain.location.GeoNotificationScheduleResult
import com.daycue.android.domain.location.GeoNotificationScheduler
import com.daycue.android.domain.location.GeoPlaceSpec
import com.daycue.android.domain.location.GeoRuleCatalog
import com.daycue.android.domain.location.GeoRuleSpec
import com.daycue.android.domain.location.GeoRuleSwitchMemory
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.location.LocationEventKind
import com.daycue.android.domain.location.LocationEventSource
import com.daycue.android.domain.location.LocationRuleSwitch
import com.daycue.android.domain.location.ProactiveLedger
import com.daycue.android.domain.location.RawLocationObservation
import com.daycue.android.domain.model.PlaceTrigger
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.BudgetDecision
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.domain.proactive.ProactiveCandidate
import com.daycue.android.domain.proactive.SuppressReason
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * 地点调用链的**编排**。
 *
 * 这些用例证明的不是「某个纯函数算出了什么值」，而是**调用链真的接通了**：
 * 撤销权限时有没有真的去注销围栏、被预算抑制时通知安排器到底有没有被调用、
 * 规则被删之后那条已经排上的通知有没有被取消。
 *
 * 全部用替身：没有 Room、没有 AlarmManager、没有定位框架，所以在 Windows 上也能跑。
 * 真实系统行为（围栏是否真的触发、通知是否真的展示）属于设备验证，不在本文件范围内。
 */
class GeoProactiveCoordinatorTest {

    private val zone: ZoneId = ZoneId.of("UTC")

    /** 正午，避开 22:30-08:00 的静默时段，让预算判定只受用例本身影响。 */
    private val now: Instant = Instant.parse("2026-03-04T12:00:00Z")

    // ---- 替身 ----

    /** 记录「有没有真的去注册 / 注销」——这正是编排用例要断言的东西。 */
    private class FakeRules(
        var rules: List<GeoRuleSpec> = emptyList(),
        var places: Map<String, GeoPlaceSpec> = emptyMap(),
    ) : GeoRuleCatalog {

        var syncAvailabilityCalls = 0
        var lastWanted: Set<String>? = null

        override suspend fun rulesForEvaluation(): List<GeoRuleSpec> = rules.filter { it.enabled }

        override suspend fun allRules(): List<GeoRuleSpec> = rules

        override suspend fun placesById(): Map<String, GeoPlaceSpec> = places

        override suspend fun syncAvailability(
            capability: LocationCapability,
            previouslyEnabledRuleIds: Set<String>,
        ): Int {
            syncAvailabilityCalls += 1
            lastWanted = previouslyEnabledRuleIds
            var changed = 0
            rules = rules.map { rule ->
                // 与 PlaceRepository 同一条规则：能力可用且用户想要，才开着。
                val should = capability.isUsable && rule.id in previouslyEnabledRuleIds
                if (rule.enabled != should) {
                    changed += 1
                    rule.copy(enabled = should)
                } else {
                    rule
                }
            }
            return changed
        }
    }

    private class FakeLedger : ProactiveLedger {

        val recorded = ArrayList<ProactiveCandidate>()
        val cancelledRowIds = ArrayList<String>()
        var decision: BudgetDecision = BudgetDecision.Deliver(Instant.EPOCH, false)
        var pendingRows: List<GeoLedgerRow> = emptyList()
        var nextRecordId: String? = "row-1"

        override suspend fun evaluate(
            candidate: ProactiveCandidate,
            now: Instant,
            zone: ZoneId,
            policy: BudgetPolicy,
            cooldownMinutes: Long,
        ): BudgetDecision = decision

        override suspend fun record(
            candidate: ProactiveCandidate,
            decision: BudgetDecision,
            now: Instant,
        ): String? {
            recorded += candidate
            return nextRecordId
        }

        override suspend fun markCancelled(id: String) { cancelledRowIds += id }

        override suspend fun ledgerSince(since: Instant): List<GeoLedgerRow> = emptyList()

        override suspend fun pendingForRule(ruleId: String): List<GeoLedgerRow> = pendingRows
    }

    private class FakeNotifier : GeoNotificationScheduler {

        val scheduled = ArrayList<GeoNotificationRequest>()
        val cancelled = ArrayList<String>()
        var result: (GeoNotificationRequest) -> GeoNotificationScheduleResult = { request ->
            GeoNotificationScheduleResult.Scheduled(request.identifier, request.fireAt)
        }

        override suspend fun schedule(request: GeoNotificationRequest): GeoNotificationScheduleResult {
            scheduled += request
            return result(request)
        }

        override suspend fun cancel(identifier: String) { cancelled += identifier }
    }

    private class FakeSource(
        override var capability: LocationCapability = LocationCapability.AVAILABLE,
        monitored: Set<String> = emptySet(),
    ) : LocationEventSource {

        override var monitoredPlaceIds: Set<String> = monitored

        val started = ArrayList<List<GeoMonitoredPlace>>()
        val stopped = ArrayList<List<String>>()
        val dwellScheduled = ArrayList<Pair<String, Instant>>()
        var fixProvider: ((String, Instant) -> RawLocationObservation?)? = null

        override fun refreshCapability(): LocationCapability = capability

        override fun startMonitoring(places: List<GeoMonitoredPlace>) {
            started += places
            monitoredPlaceIds = monitoredPlaceIds + places.map { it.id }
        }

        override fun stopMonitoring(placeIds: List<String>) {
            stopped += placeIds
            monitoredPlaceIds = monitoredPlaceIds - placeIds.toSet()
        }

        override fun stopAllMonitoring() { stopMonitoring(monitoredPlaceIds.toList()) }

        override fun proximityObservation(placeId: String, entering: Boolean, now: Instant) =
            RawLocationObservation(
                placeId = placeId,
                kind = if (entering) LocationEventKind.Entered else LocationEventKind.Exited,
                observedAt = now,
                horizontalAccuracyMeters = null,
                capability = capability,
            )

        override fun currentObservation(placeId: String, now: Instant): RawLocationObservation? =
            fixProvider?.invoke(placeId, now)

        override fun scheduleDwellRecheck(placeId: String, at: Instant) {
            dwellScheduled += placeId to at
        }

        override fun cancelDwellRecheck(placeId: String) = Unit
    }

    private class FakeSwitchMemory(private var ids: Set<String> = emptySet()) : GeoRuleSwitchMemory {
        override fun read(): Set<String> = ids
        override fun write(ruleIds: Set<String>) { ids = ruleIds }
    }

    // ---- 夹具 ----

    private fun place(id: String = "p1", confirmed: Boolean = true) = GeoPlaceSpec(
        id = id,
        name = "图书馆",
        latitude = 31.23,
        longitude = 121.47,
        radiusMeters = 200.0,
        confirmedByUser = confirmed,
        deleted = false,
    )

    private fun rule(
        id: String = "r1",
        placeId: String = "p1",
        trigger: PlaceTrigger = PlaceTrigger.ENTER,
        enabled: Boolean = true,
        title: String = "到图书馆了",
        body: String? = "要不要先看今天的课表？",
        minDwellSeconds: Int = 0,
    ) = GeoRuleSpec(
        id = id,
        placeId = placeId,
        trigger = trigger,
        title = title,
        body = body,
        minDwellSeconds = minDwellSeconds,
        enabled = enabled,
    )

    private fun observation(
        placeId: String = "p1",
        kind: LocationEventKind = LocationEventKind.Entered,
        observedAt: Instant = now,
        capability: LocationCapability = LocationCapability.AVAILABLE,
        insideSince: Instant? = null,
    ) = RawLocationObservation(
        placeId = placeId,
        kind = kind,
        observedAt = observedAt,
        horizontalAccuracyMeters = 20.0,
        capability = capability,
        insideSince = insideSince,
    )

    /** 一整套替身 + 用它们装好的编排器。 */
    private class Harness(
        val rules: FakeRules,
        val ledger: FakeLedger,
        val notifier: FakeNotifier,
        val source: FakeSource,
        val memory: FakeSwitchMemory,
        val switchState: BooleanArray,
        now: Instant,
    ) {
        val coordinator = GeoProactiveCoordinator(
            rules = rules,
            ledger = ledger,
            notifier = notifier,
            source = source,
            ruleSwitch = LocationRuleSwitch { switchState[0] },
            switchMemory = memory,
            timeSource = TimeSource { now },
        )
    }

    private fun harness(
        rules: List<GeoRuleSpec> = listOf(rule()),
        places: Map<String, GeoPlaceSpec> = mapOf("p1" to place()),
        capability: LocationCapability = LocationCapability.AVAILABLE,
        monitored: Set<String> = emptySet(),
        memory: Set<String> = emptySet(),
        switchEnabled: Boolean = true,
    ) = Harness(
        rules = FakeRules(rules = rules, places = places),
        ledger = FakeLedger(),
        notifier = FakeNotifier(),
        source = FakeSource(capability = capability, monitored = monitored),
        memory = FakeSwitchMemory(memory),
        switchState = booleanArrayOf(switchEnabled),
        now = now,
    )

    // ---- 预算：抑制必须真的拦住通知 ----

    @Test
    fun suppressedDecisionNeverReachesTheNotifier() = runTest {
        val h = harness()
        // 预算判定为「重复」，编排层必须就此打住，不能只是记一个状态、照样排通知。
        h.ledger.decision = BudgetDecision.Suppressed(SuppressReason.DUPLICATE)

        val handling = h.coordinator.handleObservation(observation(), zone)

        assertTrue("事件本身应当被接受（只是没发出去）", handling.accepted)
        val run = requireNotNull(handling.run)
        assertEquals("抑制时通知安排器一次都不能被调用", 0, run.notifierCallCount)
        assertTrue("抑制时不得真的安排通知", h.notifier.scheduled.isEmpty())
        assertEquals(ProactiveState.SUPPRESSED, run.results.single().state)
    }

    @Test
    fun deliveredCandidateSchedulesNotificationAndRecordsPending() = runTest {
        val h = harness()
        val fireAt = now.plusSeconds(60)
        h.ledger.decision = BudgetDecision.Deliver(fireAt, deferred = false)

        val run = requireNotNull(h.coordinator.handleObservation(observation(), zone).run)

        assertEquals(1, run.notifierCallCount)
        assertEquals(1, h.notifier.scheduled.size)
        assertEquals("账本必须留下 pending，等回执再改", ProactiveState.PENDING, run.results.single().state)
        assertEquals(fireAt, h.notifier.scheduled.single().fireAt)
    }

    @Test
    fun notScheduledOutcomeDoesNotLeaveAFakePendingRow() = runTest {
        val h = harness()
        h.ledger.decision = BudgetDecision.Deliver(now.plusSeconds(60), false)
        // 系统拒绝排程（例如通知权限被关）。此时绝不能留一条「等待发出」的假记录。
        h.notifier.result = { GeoNotificationScheduleResult.NotScheduled("通知权限未开启") }

        val run = requireNotNull(h.coordinator.handleObservation(observation(), zone).run)

        assertEquals(ProactiveState.CANCELLED, run.results.single().state)
        assertEquals("排程失败必须把账本落成 cancelled", listOf("row-1"), h.ledger.cancelledRowIds)
    }

    @Test
    fun ruleTitleAndBodyReachTheNotification() = runTest {
        val h = harness()
        h.ledger.decision = BudgetDecision.Deliver(now.plusSeconds(60), false)

        h.coordinator.handleObservation(observation(), zone)

        val request = h.notifier.scheduled.single()
        assertEquals("到图书馆了", request.title)
        // 正文来自 geo_rule 表的 body 列。它此前根本没映射进领域视图，通知正文永远是空的。
        assertEquals("要不要先看今天的课表？", request.body)
        assertEquals("r1", request.targetRef)
    }

    // ---- 注册对账：撤销与恢复 ----

    @Test
    fun revokedCapabilityStopsMonitoringAndBlocksEveryRule() = runTest {
        // 场景：用户刚在系统设置里撤销了定位权限，而系统里还挂着 p1 的围栏。
        val h = harness(capability = LocationCapability.PERMISSION_DENIED, monitored = setOf("p1"))

        val plan = h.coordinator.refreshRegistration()

        assertTrue("撤销权限后必须真的去注销围栏", h.source.stopped.flatten().contains("p1"))
        assertTrue("注册表里不该再留着它", h.source.monitoredPlaceIds.isEmpty())
        val readiness = plan.readiness.single()
        assertFalse("界面必须显示「不会触发」", readiness.isActive)
        assertTrue("必须给出可读原因，不能留空", !readiness.blockingReason.isNullOrBlank())
        assertTrue("权限不可用时不得注册任何围栏", plan.placesToStartMonitoring.isEmpty())
    }

    @Test
    fun capabilityRecoveryRestoresTheRulesTheUserWanted() = runTest {
        // 场景：权限曾被撤销，规则因此被全部暂停，但记忆里留着用户原本开着的那条。
        val h = harness(
            rules = listOf(rule(enabled = false)),
            capability = LocationCapability.AVAILABLE,
            memory = setOf("r1"),
        )

        val plan = h.coordinator.refreshRegistration()

        assertTrue("能力恢复后必须把用户原本开着的规则放回来", h.rules.rules.single().enabled)
        assertTrue("恢复后必须真的注册围栏", h.source.started.flatten().map { it.id }.contains("p1"))
        assertTrue(plan.readiness.single().isActive)
    }

    @Test
    fun recoveryDoesNotResurrectAUserDisabledRule() = runTest {
        // 反面：第二条规则本来就是关着的，能力恢复不该把它打开。
        val h = harness(
            rules = listOf(rule(id = "r1", placeId = "p1", enabled = true), rule(id = "r2", placeId = "p1", enabled = false)),
        )
        h.memory.write(setOf("r1"))

        h.coordinator.refreshRegistration()

        assertFalse("用户没开的规则不能被打开", h.rules.rules.first { it.id == "r2" }.enabled)
    }

    @Test
    fun newRuleGetsRegisteredOnRuleChanged() = runTest {
        val h = harness(rules = emptyList())
        h.coordinator.refreshRegistration()
        assertTrue("初始没有规则时不该注册任何围栏", h.source.started.isEmpty())

        // 用户新增了一条规则。
        h.rules.rules = listOf(rule())

        val plan = h.coordinator.onRuleChanged()

        assertTrue("新增规则后必须注册对应围栏", h.source.started.flatten().map { it.id }.contains("p1"))
        assertTrue(plan.readiness.single().isActive)
    }

    @Test
    fun removingARuleCancelsItsPendingNotification() = runTest {
        val h = harness()
        // 这条规则已经排上过一条还没发的通知。
        h.ledger.pendingRows = listOf(
            GeoLedgerRow(
                id = "row-9",
                dedupeKey = "geo:r1:1700000000",
                kind = ProactiveKind.GEO,
                state = ProactiveState.PENDING,
                cooldownKey = "r1",
                deliveredAt = null,
            ),
        )

        h.coordinator.onRulesRemoved(listOf("r1"))

        // 只取消围栏是不够的：几分钟后那条已经排上的提醒照样会响，用户会以为删除没生效。
        assertEquals(1, h.notifier.cancelled.size)
        assertTrue(
            "取消用的标识必须由幂等键派生（和排程时同一个）",
            h.notifier.cancelled.single().endsWith("geo:r1:1700000000"),
        )
        assertTrue("账本行必须落成 cancelled", h.ledger.cancelledRowIds.contains("row-9"))
    }

    // ---- 新鲜度与野监控防护 ----

    @Test
    fun staleObservationIsDiscardedBeforeRulesRun() = runTest {
        val h = harness()
        h.ledger.decision = BudgetDecision.Deliver(now, false)

        // 10 分钟前的观测，远超 2 分钟的新鲜度上限。
        val handling = h.coordinator.handleObservation(
            observation(observedAt = now.minusSeconds(600), insideSince = now.minusSeconds(600)),
            zone,
        )

        assertFalse("陈旧观测不得被接受", handling.accepted)
        val discard = requireNotNull(handling.discard)
        assertTrue("位置不可信属于静默降级", discard.isSilent)
        assertTrue("绝不能拿陈旧坐标触发提醒", h.notifier.scheduled.isEmpty())
        assertEquals("规则求值这一步都不该走到", 0, h.ledger.recorded.size)
    }

    @Test
    fun lateBroadcastForUnmonitoredPlaceIsIgnored() = runTest {
        val h = harness(monitored = emptySet())

        val handling = h.coordinator.onProximityTransition("p1", entering = true, zone = zone)

        assertFalse("已经取消监控的地点，迟到的广播必须丢弃", handling.accepted)
        assertTrue(h.notifier.scheduled.isEmpty())
    }

    @Test
    fun dwellRecheckWithoutAFixIsDiscardedInsteadOfGuessed() = runTest {
        val h = harness(monitored = setOf("p1"))
        // 拿不到可用定位（fixProvider 返回 null）。
        h.source.fixProvider = { _, _ -> null }

        val handling = h.coordinator.onDwellRecheck("p1", zone)

        assertFalse("没有可用定位时必须丢弃，不能猜「还在里面」", handling.accepted)
        assertTrue(h.notifier.scheduled.isEmpty())
    }

    @Test
    fun dwellRuleSchedulesARecheckInsteadOfFiringEarly() = runTest {
        // 停留规则：刚进来 60 秒，离 30 分钟的门槛还远，现在不该触发，而要安排一次到点复查。
        //
        // 注意 minDwellSeconds 只对 DWELL 规则生效（见 GeoRuleEvaluator 的 when(rule.trigger)）；
        // ENTER 规则带 minDwellSeconds 是不生效的，所以这里 trigger 必须显式给 DWELL。
        val h = harness(rules = listOf(rule(trigger = PlaceTrigger.DWELL, minDwellSeconds = 1800)))
        val insideSince = now.minusSeconds(60)

        val handling = h.coordinator.handleObservation(
            observation(kind = LocationEventKind.Dwell(insideSince), insideSince = insideSince),
            zone,
        )

        val run = requireNotNull(handling.run)
        assertEquals("还没待够，不该排通知", 0, run.notifierCallCount)
        assertEquals(1, run.deferrals.size)
        // 复查必须真的排上，否则 minDwellSeconds>0 的规则永远不会再被想起。
        assertEquals(listOf("p1"), h.source.dwellScheduled.map { it.first })
    }

    // ---- 总开关 ----

    @Test
    fun disabledMasterSwitchDiscardsWithoutEvaluatingAnything() = runTest {
        val h = harness(switchEnabled = false)

        val handling = h.coordinator.handleObservation(observation(), zone)

        assertFalse(handling.accepted)
        assertTrue("总开关关闭时连规则求值都不该发生", h.ledger.recorded.isEmpty())
        assertTrue(h.notifier.scheduled.isEmpty())
    }
}
