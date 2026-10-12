package com.daycue.android.domain.followup

import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.FollowUpState
import java.time.Instant
import java.time.temporal.ChronoUnit

/** 追问窗口与补发规则。默认值来自设计文档 5.3：计划结束后 5–15 分钟为窗口。 */
data class FollowUpPolicy(
    val minDelayMinutes: Long = 5,
    val maxDelayMinutes: Long = 15,
    /**
     * 晚于计划时刻多久就不再补发。
     * 这个值存在的意义是「不补发昨天的追问」：手机被关机一整天后重开，
     * 补一堆过期的追问比不提醒更糟。
     */
    val pickupGraceMinutes: Long = 120,
    /** 连堂判定：下一节在本节结束后这么久内开始，就并成一串，只在最后一起追问。 */
    val chainGapMinutes: Long = 20,
)

data class InstanceSpec(
    val id: String,
    val courseId: String,
    val startsAt: Instant,
    val endsAt: Instant,
    val status: CourseInstanceStatus,
)

data class CourseFollowUpSpec(
    val courseId: String,
    val enabled: Boolean,
    val delayMinutes: Int = 5,
    val mode: FollowUpMode = FollowUpMode.EVERY_CLASS,
)

/** 已存在的追问（一个课程实例最多一条，这与 schema 的 UNIQUE(course_instance_id) 一致）。 */
data class FollowUpSpec(
    val id: String,
    val instanceId: String,
    val state: FollowUpState,
    val scheduledAt: Instant,
    val snoozeUntil: Instant? = null,
    val attempt: Int = 0,
)

/**
 * 调度器给出的结论。
 * 做成密封类而不是「返回一个可空时刻」，是为了让「不排」的原因必须被显式写出来——
 * 这些原因要落进 proactive_message.suppress_reason，用户问「为什么没问我」时能答上来。
 */
sealed interface FollowUpDecision {
    data class Plan(
        val instanceId: String,
        val courseId: String,
        val scheduledAt: Instant,
        val attempt: Int,
        val reason: String,
    ) : FollowUpDecision

    data class Reschedule(
        val followUpId: String,
        val scheduledAt: Instant,
        val reason: String,
    ) : FollowUpDecision

    data class Cancel(val followUpId: String, val reason: String) : FollowUpDecision

    data class Expire(val followUpId: String, val reason: String) : FollowUpDecision

    data class Skip(val instanceId: String, val reason: String) : FollowUpDecision
}

/**
 * 课后追问调度。
 *
 * 三条硬规则（都是「少打扰」的直接来源）：
 * 1. 终态（answered / skipped / expired / cancelled）永不被拾取——否则会出现「点了跳过又被追问」；
 * 2. 停课（cancelled）与未开启追问的课程不排，且已排的旧追问要取消，不能留在系统通知里；
 * 3. snooze 是显式重新安排，仍属于同一个候选，不新建第二条。
 */
object FollowUpScheduler {

    fun plan(
        instance: InstanceSpec,
        course: CourseFollowUpSpec,
        existing: FollowUpSpec?,
        now: Instant,
        policy: FollowUpPolicy = FollowUpPolicy(),
        /** 同一天里、开始时间晚于本节的同一课程实例，用来识别连堂。 */
        laterInstances: List<InstanceSpec> = emptyList(),
        /** 该课程当天已经发出过几次追问，用于「每天首次」策略。 */
        deliveredTodayCount: Int = 0,
        /** 「仅我标记困难后」策略下，用户是否标记过这节课有疑问。 */
        userMarkedDifficult: Boolean = false,
    ): FollowUpDecision {

        // 1. 终态不再拾取
        if (existing != null && existing.state.isTerminal) {
            return FollowUpDecision.Skip(instance.id, "追问已处于终态(" + existing.state.raw + ")，不再拾取")
        }

        // 2. 停课 / 未开启追问：停课不排，且已排的要取消
        if (instance.status == CourseInstanceStatus.CANCELLED) {
            return if (existing != null) {
                FollowUpDecision.Cancel(existing.id, "课程已停课，取消已安排的追问")
            } else {
                FollowUpDecision.Skip(instance.id, "课程已停课，不安排追问")
            }
        }
        if (!course.enabled) {
            return if (existing != null) {
                FollowUpDecision.Cancel(existing.id, "该课程未开启课后追问")
            } else {
                FollowUpDecision.Skip(instance.id, "该课程未开启课后追问")
            }
        }

        // 3. 课程级策略
        if (course.mode == FollowUpMode.MANUAL_ONLY && !userMarkedDifficult) {
            return FollowUpDecision.Skip(instance.id, "策略为「仅标记困难后」，本次未标记")
        }
        if (course.mode == FollowUpMode.FIRST_OF_DAY && deliveredTodayCount > 0) {
            return FollowUpDecision.Skip(instance.id, "今天已经追问过这门课")
        }

        // 4. 已发出但还没回复：保留在今天页，不重复推送
        if (existing != null && existing.state == FollowUpState.DELIVERED) {
            return FollowUpDecision.Skip(instance.id, "已发出，等待用户回复，不重复推送")
        }

        // 5. snooze：用户显式延后，同一个候选换个时刻
        if (existing != null && existing.state == FollowUpState.SNOOZED) {
            val snoozeUntil = existing.snoozeUntil
                ?: return FollowUpDecision.Skip(instance.id, "snooze 状态缺少 snoozeUntil，无法安排")
            val at = if (snoozeUntil.isAfter(now)) snoozeUntil else now
            return FollowUpDecision.Reschedule(existing.id, at, "用户选择了稍后提醒")
        }

        // 6. 连堂：后面紧跟着同一门课就并入同一次追问，避免课间打断
        val chainEnd = chainEndOf(instance, laterInstances, policy)

        // 7. 计划结束 + 课程配置的延迟，并夹在窗口内
        val delay = course.delayMinutes.toLong().coerceIn(policy.minDelayMinutes, policy.maxDelayMinutes)
        val scheduledAt = chainEnd.plus(delay, ChronoUnit.MINUTES)

        // 8. 过期不补发
        val overdueMinutes = ChronoUnit.MINUTES.between(scheduledAt, now)
        if (overdueMinutes > policy.pickupGraceMinutes) {
            return if (existing != null) {
                FollowUpDecision.Expire(existing.id, "已超过有效窗口 " + overdueMinutes + " 分钟，不补发")
            } else {
                FollowUpDecision.Skip(instance.id, "已超过有效窗口 " + overdueMinutes + " 分钟，不补发")
            }
        }

        // 9. 窗口内但时刻已过：现在发出，而不是回到过去
        val effectiveAt = if (scheduledAt.isBefore(now)) now else scheduledAt
        return FollowUpDecision.Plan(
            instanceId = instance.id,
            courseId = course.courseId,
            scheduledAt = effectiveAt,
            attempt = (existing?.attempt ?: 0) + 1,
            reason = "计划结束 " + chainEnd.toString() + " 后 " + delay + " 分钟追问",
        )
    }

    /** 从本节开始，把后面紧挨着的同课程实例串起来，返回这一串的结束时刻。 */
    internal fun chainEndOf(
        instance: InstanceSpec,
        laterInstances: List<InstanceSpec>,
        policy: FollowUpPolicy,
    ): Instant {
        var end = instance.endsAt
        val pending = laterInstances
            .filter { it.status != CourseInstanceStatus.CANCELLED }
            .sortedBy { it.startsAt }
        for (next in pending) {
            val gap = ChronoUnit.MINUTES.between(end, next.startsAt)
            if (gap > policy.chainGapMinutes) break
            if (next.endsAt.isAfter(end)) end = next.endsAt
        }
        return end
    }
}
