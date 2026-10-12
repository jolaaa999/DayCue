package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.dao.CourseDao
import com.daycue.android.data.local.dao.CourseInstanceDao
import com.daycue.android.data.local.dao.FollowUpDao
import com.daycue.android.data.local.dao.FollowUpReplyDao
import com.daycue.android.data.local.entity.FollowUpRecord
import com.daycue.android.data.local.entity.FollowUpReplyRecord
import com.daycue.android.domain.followup.FollowUpDecision
import com.daycue.android.domain.followup.FollowUpPolicy
import com.daycue.android.domain.followup.FollowUpScheduler
import com.daycue.android.domain.followup.FollowUpSpec
import com.daycue.android.domain.followup.InstanceSpec
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpReplyKind
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.domain.model.ProactiveKind
import com.daycue.android.domain.proactive.BudgetDecision
import com.daycue.android.domain.schedule.TermCalendar
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** 回答追问的结果：回复本身 + 顺带生成的课堂记录。 */
data class FollowUpAnswerResult(
    val followUpId: String,
    val replyId: String,
    val noteId: String?,
    val archivedNoteFailed: Boolean = false,
)

/**
 * 课后追问仓储。
 *
 * 调度决策全在 FollowUpScheduler（纯函数），这里只负责「读现状 → 决策 → 落库」这三步，
 * 以及投递前的那道主动消息预算闸门。
 */
class FollowUpRepository(
    private val followUpDao: FollowUpDao,
    private val replyDao: FollowUpReplyDao,
    private val instanceDao: CourseInstanceDao,
    private val courseDao: CourseDao,
    private val noteRepository: NoteRepository,
    private val proactiveRepository: ProactiveRepository,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    suspend fun findByInstance(instanceId: String): FollowUpRecord? = followUpDao.findByInstance(instanceId)

    suspend fun find(followUpId: String): FollowUpRecord? = followUpDao.findById(followUpId)

    fun observeOutstanding(): Flow<List<FollowUpRecord>> = followUpDao.observeOutstanding()

    suspend fun repliesFor(followUpId: String): List<FollowUpReplyRecord> = replyDao.listByFollowUp(followUpId)

    /**
     * 为未来若干天的课程实例排追问。
     *
     * 每次都重新跑一遍调度器，而不是「排过就不动」：课表可能被重新展开（停课、调课），
     * 已经作废的追问必须被取消，否则用户会在停课的晚上收到追问。
     */
    suspend fun scheduleUpcoming(
        term: TermCalendar,
        zone: ZoneId,
        now: Instant = timeSource.now(),
        horizonDays: Long = 7,
        policy: FollowUpPolicy = FollowUpPolicy(),
    ): Int {
        val from = now.minus(policy.pickupGraceMinutes, ChronoUnit.MINUTES)
        val to = now.plus(horizonDays, ChronoUnit.DAYS)
        val instances = instanceDao.listBetween(from, to)
        if (instances.isEmpty()) return 0

        val courses = courseDao.listActive().associateBy { it.id }
        var changes = 0

        for (instance in instances) {
            val course = courses[instance.courseId] ?: continue
            val spec = InstanceSpec(
                id = instance.id,
                courseId = instance.courseId,
                startsAt = instance.startsAtUtc,
                endsAt = instance.endsAtUtc,
                status = instance.status,
            )
            val dayStart = DayCueTime.startOfLocalDay(DayCueTime.localDateOf(instance.startsAtUtc, zone), zone)
            val dayEnd = DayCueTime.startOfNextLocalDay(DayCueTime.localDateOf(instance.startsAtUtc, zone), zone)
            val laterSameDay = instances
                .filter { it.courseId == instance.courseId && it.id != instance.id && it.startsAtUtc.isAfter(instance.startsAtUtc) }
                .filter { it.startsAtUtc.isBefore(dayEnd) }
                .map { InstanceSpec(it.id, it.courseId, it.startsAtUtc, it.endsAtUtc, it.status) }

            val decision = FollowUpScheduler.plan(
                instance = spec,
                course = ScheduleRepositoryBridge.courseSpec(course),
                existing = followUpDao.findByInstance(instance.id)?.toSpec(),
                now = now,
                policy = policy,
                laterInstances = laterSameDay,
                deliveredTodayCount = followUpDao.countDeliveredBetween(course.id, dayStart, dayEnd),
                userMarkedDifficult = false,
            )

            when (decision) {
                is FollowUpDecision.Plan -> {
                    val insertId = DayCueId.new()
                    followUpDao.insert(
                        FollowUpRecord(
                            id = insertId,
                            courseInstanceId = decision.instanceId,
                            courseId = decision.courseId,
                            state = FollowUpState.SCHEDULED,
                            scheduledAtUtc = decision.scheduledAt,
                            attempt = decision.attempt,
                            createdAt = now,
                            updatedAt = now,
                        ),
                    )
                    changes += 1
                }

                is FollowUpDecision.Reschedule -> {
                    val existing = followUpDao.findById(decision.followUpId) ?: continue
                    followUpDao.updateStateAndSchedule(
                        id = existing.id,
                        state = FollowUpState.SCHEDULED,
                        scheduledAt = decision.scheduledAt,
                        snoozeUntil = null,
                        deliveredAt = existing.deliveredAtUtc,
                        attempt = existing.attempt,
                        updatedAt = now,
                    )
                    changes += 1
                }

                is FollowUpDecision.Cancel -> {
                    followUpDao.updateState(decision.followUpId, FollowUpState.CANCELLED, now)
                    changes += 1
                }

                is FollowUpDecision.Expire -> {
                    followUpDao.updateState(decision.followUpId, FollowUpState.EXPIRED, now)
                    changes += 1
                }

                is FollowUpDecision.Skip -> Unit
            }
        }
        return changes
    }

    /**
     * 取到点该发的追问，并过一遍主动消息预算。
     *
     * 返回的是「现在应该真正发出去的那几条」，以及被顺延到的时刻。
     * 被预算抑制的不返回——但账本里会留下 suppressed 行，用户问「为什么没提醒」时能查。
     */
    suspend fun dueForDelivery(
        zone: ZoneId,
        now: Instant = timeSource.now(),
        policy: com.daycue.android.domain.proactive.BudgetPolicy = com.daycue.android.domain.proactive.BudgetPolicy(),
    ): List<DueDelivery> {
        val due = followUpDao.listDueForPickup(now)
        val result = ArrayList<DueDelivery>()
        for (record in due) {
            val candidate = proactiveRepository.candidate(
                kind = ProactiveKind.FOLLOW_UP,
                dedupeKey = "follow_up:" + record.courseInstanceId,
                scheduledAt = record.scheduledAtUtc,
                // 追问的有效期：过了补发宽限期就不该再出现。
                expiresAt = record.scheduledAtUtc.plus(12, ChronoUnit.HOURS),
                cooldownKey = record.courseId,
            )
            when (val decision = proactiveRepository.evaluate(candidate, now, zone, policy, cooldownMinutes = 0)) {
                is BudgetDecision.Deliver -> {
                    proactiveRepository.record(candidate, decision, now)
                    result += DueDelivery(
                        followUpId = record.id,
                        courseId = record.courseId,
                        deliverAt = decision.at,
                        deferred = decision.deferred,
                    )
                }

                is BudgetDecision.Suppressed -> proactiveRepository.record(candidate, decision, now)

                is BudgetDecision.Expired -> {
                    proactiveRepository.record(candidate, decision, now)
                    followUpDao.updateState(record.id, FollowUpState.EXPIRED, now)
                }
            }
        }
        return result
    }

    suspend fun markDelivered(followUpId: String, at: Instant = timeSource.now()) {
        val record = followUpDao.findById(followUpId) ?: return
        followUpDao.updateStateAndSchedule(
            id = record.id,
            state = FollowUpState.DELIVERED,
            scheduledAt = record.scheduledAtUtc,
            snoozeUntil = null,
            deliveredAt = at,
            attempt = record.attempt,
            updatedAt = at,
        )
        proactiveRepository.markDelivered("follow_up:" + record.courseInstanceId, at)
    }

    /** 「稍后」是显式重新安排，仍属于同一个候选，不新建第二条（设计文档 8.2）。 */
    suspend fun snooze(followUpId: String, until: Instant, now: Instant = timeSource.now()) {
        val record = followUpDao.findById(followUpId) ?: return
        followUpDao.updateStateAndSchedule(
            id = record.id,
            state = FollowUpState.SNOOZED,
            scheduledAt = record.scheduledAtUtc,
            snoozeUntil = until,
            deliveredAt = record.deliveredAtUtc,
            attempt = record.attempt,
            updatedAt = now,
        )
    }

    /** 跳过 ≠ 已学会。这里只记状态，不写任何「用户已掌握」的记忆。 */
    suspend fun skip(followUpId: String, now: Instant = timeSource.now()) {
        followUpDao.updateState(followUpId, FollowUpState.SKIPPED, now)
        proactiveRepository.findByDedupeKey("follow_up:" + followUpId)?.let {
            proactiveRepository.markCancelled(it.id)
        }
    }

    suspend fun cancelForInstance(instanceId: String, now: Instant = timeSource.now()) {
        val existing = followUpDao.findByInstance(instanceId) ?: return
        if (!existing.state.isTerminal) followUpDao.updateState(existing.id, FollowUpState.CANCELLED, now)
    }

    suspend fun expire(followUpId: String, now: Instant = timeSource.now()) =
        followUpDao.updateState(followUpId, FollowUpState.EXPIRED, now)

    /**
     * 回答追问：归档回复，并顺手生成一条课堂记录。
     *
     * 为什么默认生成笔记：设计文档 5.3 的闭环是「回复 → 保存课堂记录 → 针对疑问解释」，
     * 笔记是这条闭环里唯一可长期检索的东西。生成失败也不能影响回复本身落地。
     */
    suspend fun answer(
        followUpId: String,
        text: String,
        zone: ZoneId,
        now: Instant = timeSource.now(),
        courseHint: String? = null,
    ): FollowUpAnswerResult {
        val record = followUpDao.findById(followUpId) ?: error("追问不存在：" + followUpId)
        val replyId = DayCueId.new()
        replyDao.insert(
            FollowUpReplyRecord(
                id = replyId,
                followUpId = followUpId,
                courseId = record.courseId,
                kind = FollowUpReplyKind.TEXT,
                text = text,
                createdAt = now,
            ),
        )
        followUpDao.updateStateAndSchedule(
            id = record.id,
            state = FollowUpState.ANSWERED,
            scheduledAt = record.scheduledAtUtc,
            snoozeUntil = null,
            deliveredAt = record.deliveredAtUtc ?: now,
            attempt = record.attempt,
            updatedAt = now,
        )
        proactiveRepository.markDelivered("follow_up:" + record.courseInstanceId, now)

        val noteId = runCatching {
            noteRepository.create(
                title = (courseHint ?: "课后记录") + " · " + DayCueTime.displayDate(now, zone),
                body = text,
                originKind = NoteOriginKind.FOLLOW_UP,
                courseHint = courseHint,
                occurredAt = now,
                zone = zone,
            )
        }.getOrNull()

        return FollowUpAnswerResult(
            followUpId = followUpId,
            replyId = replyId,
            noteId = noteId,
            archivedNoteFailed = noteId == null,
        )
    }

    /** 语音回复：先存音频路径，转写结果晚点补写。 */
    suspend fun attachAudioReply(
        followUpId: String,
        mediaPath: String,
        transcript: String?,
        now: Instant = timeSource.now(),
    ): String {
        val record = followUpDao.findById(followUpId) ?: error("追问不存在：" + followUpId)
        val replyId = DayCueId.new()
        replyDao.insert(
            FollowUpReplyRecord(
                id = replyId,
                followUpId = followUpId,
                courseId = record.courseId,
                kind = FollowUpReplyKind.AUDIO,
                transcript = transcript,
                mediaPath = mediaPath,
                createdAt = now,
            ),
        )
        return replyId
    }

    private fun FollowUpRecord.toSpec(): FollowUpSpec = FollowUpSpec(
        id = id,
        instanceId = courseInstanceId,
        state = state,
        scheduledAt = scheduledAtUtc,
        snoozeUntil = snoozeUntilUtc,
        attempt = attempt,
    )

    /** 投递给系统通知时用的一条。 */
    data class DueDelivery(
        val followUpId: String,
        val courseId: String,
        val deliverAt: Instant,
        val deferred: Boolean,
    )
}

/** 把一个 CourseRecord 转成调度器要的课程策略。单独放这里是为了不让仓储之间互相依赖。 */
internal object ScheduleRepositoryBridge {
    fun courseSpec(course: com.daycue.android.data.local.entity.CourseRecord) =
        com.daycue.android.domain.followup.CourseFollowUpSpec(
            courseId = course.id,
            enabled = course.followUpEnabled,
            delayMinutes = course.followUpDelayMinutes,
            mode = course.followUpMode,
        )
}
