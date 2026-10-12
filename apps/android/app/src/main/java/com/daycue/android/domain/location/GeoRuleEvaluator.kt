package com.daycue.android.domain.location

import com.daycue.android.domain.model.PlaceTrigger
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

/** 位置状态的变化。由调用方比较相邻两次采样得出，判断逻辑不自己猜「刚才在不在里面」。 */
enum class GeoTransition { ENTERED, EXITED, NONE }

/** 规则的纯数据视图，不依赖 Room 实体。 */
data class GeoRuleSpec(
    val id: String,
    val placeId: String,
    val trigger: PlaceTrigger,
    val title: String,
    val minDwellSeconds: Int = 0,
    val cooldownSeconds: Int = 3600,
    val activeFromLocal: LocalTime? = null,
    val activeToLocal: LocalTime? = null,
    val weekdays: List<Int> = emptyList(),
    val enabled: Boolean = true,
    val expiresAt: Instant? = null,
)

data class GeoState(
    val transition: GeoTransition,
    /** 进入围栏的时刻，用于 dwell 判定；不在围栏内时为 null。 */
    val insideSince: Instant? = null,
    val lastTriggeredAt: Instant? = null,
)

sealed interface GeoDecision {
    data class Trigger(val ruleId: String, val reason: String) : GeoDecision

    data class Defer(val ruleId: String, val until: Instant, val reason: String) : GeoDecision

    data class Suppress(val ruleId: String, val reason: String) : GeoDecision

    data class Skip(val reason: String) : GeoDecision
}

/**
 * 位置规则判定。
 *
 * 最重要的一条：**定位能力不可用时直接 Skip，绝不拿陈旧坐标凑合**。
 * 设计文档说得很直白——「位置不可用时不把陈旧位置当作当前位置」，
 * 否则用户会在图书馆收到「你到家了」。
 */
object GeoRuleEvaluator {

    fun evaluate(
        rule: GeoRuleSpec,
        state: GeoState,
        now: Instant,
        zone: ZoneId,
        locationUsable: Boolean,
    ): GeoDecision {
        if (!locationUsable) return GeoDecision.Skip("定位不可用，不使用陈旧位置")
        if (!rule.enabled) return GeoDecision.Skip("规则已暂停")
        if (rule.expiresAt != null && now.isAfter(rule.expiresAt)) return GeoDecision.Skip("规则已过期")

        val localNow = ZonedDateTime.ofInstant(now, zone)
        if (rule.weekdays.isNotEmpty() && localNow.dayOfWeek.value !in rule.weekdays) {
            return GeoDecision.Skip("今天不在规则的生效星期内")
        }
        if (!withinActiveWindow(rule, localNow.toLocalTime())) {
            return GeoDecision.Skip("当前不在规则的生效时段内")
        }

        if (cooldownEndsAt(state, rule).isAfter(now)) {
            return GeoDecision.Suppress(rule.id, "仍在冷却期内")
        }

        return when (rule.trigger) {
            PlaceTrigger.ENTER -> when (state.transition) {
                GeoTransition.ENTERED -> GeoDecision.Trigger(rule.id, "刚刚进入地点")
                else -> GeoDecision.Skip("尚未进入地点")
            }

            PlaceTrigger.EXIT -> when (state.transition) {
                GeoTransition.EXITED -> GeoDecision.Trigger(rule.id, "刚刚离开地点")
                else -> GeoDecision.Skip("尚未离开地点")
            }

            PlaceTrigger.DWELL -> {
                val since = state.insideSince ?: return GeoDecision.Skip("不在围栏内，无法判断停留")
                val readyAt = since.plus(rule.minDwellSeconds.toLong(), ChronoUnit.SECONDS)
                if (now.isBefore(readyAt)) {
                    GeoDecision.Defer(rule.id, readyAt, "停留时间还没到设定值")
                } else {
                    GeoDecision.Trigger(rule.id, "已在地点停留满设定时长")
                }
            }
        }
    }

    private fun cooldownEndsAt(state: GeoState, rule: GeoRuleSpec): Instant {
        val last = state.lastTriggeredAt ?: return Instant.MIN
        return last.plus(rule.cooldownSeconds.toLong(), ChronoUnit.SECONDS)
    }

    /** 生效时段允许跨零点（例如 21:00–02:00），所以分两种情形判断。 */
    internal fun withinActiveWindow(rule: GeoRuleSpec, localTime: LocalTime): Boolean {
        val from = rule.activeFromLocal ?: return true
        val to = rule.activeToLocal ?: return true
        // from==to 视为全天有效，而不是「零长度窗口」——后者会让规则永远不触发，
        // 属于那种用户查不出原因、只能把规则删掉的故障。
        if (from == to) return true
        return if (from.isBefore(to)) {
            !localTime.isBefore(from) && localTime.isBefore(to)
        } else {
            !localTime.isBefore(from) || localTime.isBefore(to)
        }
    }
}
