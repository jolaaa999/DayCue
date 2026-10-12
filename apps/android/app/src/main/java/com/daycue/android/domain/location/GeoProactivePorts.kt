package com.daycue.android.domain.location

import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.model.ProactiveState
import com.daycue.android.domain.proactive.BudgetDecision
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.domain.proactive.ProactiveCandidate
import java.time.Instant
import java.time.ZoneId

/**
 * 规则与地点的读取口。
 *
 * 由 PlaceRepository 实现，测试可用内存替身替换：编排的正确性（是否真的重新注册、
 * 撤销后是否真的取消了注册）必须能在没有 Room、没有设备的环境里断言。
 */
interface GeoRuleCatalog {

    /** 参与判定的规则：未删除且启用。 */
    suspend fun rulesForEvaluation(): List<GeoRuleSpec>

    /** 全部未删除规则（含已暂停的）：界面展示与「用户想要哪些规则开着」的记忆都要用到。 */
    suspend fun allRules(): List<GeoRuleSpec>

    /** 全部地点（含未确认与已删除的）：只有拿到全集，readiness 才能说出「为什么不会触发」。 */
    suspend fun placesById(): Map<String, GeoPlaceSpec>

    /**
     * 定位能力变化时同步规则的启用状态。
     *
     * 不可用 -> 全部暂停；恢复可用 -> 只把用户此前确实开着的规则放回来。
     * 为什么不「一恢复就全开」：暂停可能是用户自己关的，能力恢复不该改变用户的决定。
     */
    suspend fun syncAvailability(capability: LocationCapability, previouslyEnabledRuleIds: Set<String>): Int
}

/** 账本里的一行，只带预算 / 冷却 / 取消判定需要的字段，不把 Room 实体漏进领域层。 */
data class GeoLedgerRow(
    val id: String,
    val dedupeKey: String,
    val kind: ProactiveKind,
    val state: ProactiveState,
    val cooldownKey: String?,
    val deliveredAt: Instant?,
)

/**
 * 主动消息账本端口。
 *
 * 安排通知**之前**必须经过它，预算 / 静默 / 冷却 / 去重都在这一层判完；
 * 由 ProactiveRepository 实现（真正的判断在纯逻辑 ProactiveBudget 里）。
 */
interface ProactiveLedger {

    suspend fun evaluate(
        candidate: ProactiveCandidate,
        now: Instant,
        zone: ZoneId,
        policy: BudgetPolicy,
        cooldownMinutes: Long,
    ): BudgetDecision

    /** 把判定结果落账，返回账本行 id；dedupe_key 已存在时返回 null（去重生效，不是错误）。 */
    suspend fun record(candidate: ProactiveCandidate, decision: BudgetDecision, now: Instant): String?

    suspend fun markCancelled(id: String)

    /** 预算与冷却要看的那一段账本。 */
    suspend fun ledgerSince(since: Instant): List<GeoLedgerRow>

    /** 某条规则当前还在等发出的账本行：删除规则时要把它们取消掉，不能留下一条会突然响的记录。 */
    suspend fun pendingForRule(ruleId: String): List<GeoLedgerRow>
}

/** 回执落账需要的一行。 */
data class ProactiveReceiptRow(
    val id: String,
    val dedupeKey: String,
    val kind: ProactiveKind,
    val state: ProactiveState,
    val deliveredAt: Instant?,
)

/** 通知交互回执的写入端口，由 ProactiveRepository 实现。 */
interface ProactiveReceiptStore {

    suspend fun findReceiptRow(dedupeKey: String): ProactiveReceiptRow?

    suspend fun applyInteraction(
        id: String,
        state: ProactiveState,
        reason: String?,
        deliveredAt: Instant?,
        at: Instant,
    )
}

/**
 * 位置规则总开关。
 *
 * 位置是敏感能力，默认关闭、必须由用户显式打开；用一个函数式接口表达，
 * 是为了让编排层不必依赖 SettingsRepository，测试也能直接给出「开 / 关」。
 */
fun interface LocationRuleSwitch {

    suspend fun isEnabled(): Boolean
}

/**
 * 「用户想要哪些规则开着」的记忆。
 *
 * 为什么需要它：定位能力不可用时我们只能把规则全部暂停（这是「不假装规则正常运行」的要求），
 * 但能力恢复时必须只放回用户原本开着的那些。没有这份记忆，「一恢复就全开」或「永远开不回来」
 * 二选一都是错的。
 */
interface GeoRuleSwitchMemory {

    fun read(): Set<String>

    fun write(ruleIds: Set<String>)
}
