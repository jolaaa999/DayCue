package com.daycue.android.domain.followup

import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpMode
import com.daycue.android.domain.model.FollowUpState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * 课后追问调度。
 *
 * 时间全部是显式传入的绝对时刻（UTC 整点），不用「当前时间」——
 * 否则这套测试会依赖运行时区与执行时刻，跑起来时好时坏。
 */
class FollowUpSchedulerTest {

    private val course = CourseFollowUpSpec(courseId = "course_1", enabled = true, delayMinutes = 5)

    private fun instance(
        id: String = "instance_1",
        start: String = "2026-10-12T09:00:00Z",
        end: String = "2026-10-12T10:00:00Z",
        status: CourseInstanceStatus = CourseInstanceStatus.SCHEDULED,
    ) = InstanceSpec(id, "course_1", Instant.parse(start), Instant.parse(end), status)

    private fun existing(
        state: FollowUpState = FollowUpState.SCHEDULED,
        scheduledAt: String = "2026-10-12T10:05:00Z",
        snoozeUntil: String? = null,
        attempt: Int = 1,
    ) = FollowUpSpec(
        id = "follow_up_1",
        instanceId = "instance_1",
        state = state,
        scheduledAt = Instant.parse(scheduledAt),
        snoozeUntil = snoozeUntil?.let { Instant.parse(it) },
        attempt = attempt,
    )

    @Test
    fun plansFiveMinutesAfterPlannedEnd() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Plan)
        assertEquals(Instant.parse("2026-10-12T10:05:00Z"), (decision as FollowUpDecision.Plan).scheduledAt)
        assertEquals(1, decision.attempt)
    }

    @Test
    fun delayIsClampedIntoConfiguredWindow() {
        // 用户把延迟设成 30 分钟，也必须夹回 5–15 分钟的窗口：窗口本身就是「别打扰太久」的承诺。
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course.copy(delayMinutes = 30),
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
        )
        assertEquals(Instant.parse("2026-10-12T10:15:00Z"), (decision as FollowUpDecision.Plan).scheduledAt)
    }

    @Test
    fun terminalStateIsNeverPickedUpAgain() {
        for (state in listOf(FollowUpState.ANSWERED, FollowUpState.SKIPPED, FollowUpState.EXPIRED, FollowUpState.CANCELLED)) {
            val decision = FollowUpScheduler.plan(
                instance = instance(),
                course = course,
                existing = existing(state = state),
                now = Instant.parse("2026-10-12T10:06:00Z"),
            )
            assertTrue("终态 $state 不应被再次拾取", decision is FollowUpDecision.Skip)
        }
    }

    @Test
    fun cancelledClassCancelsExistingFollowUp() {
        val decision = FollowUpScheduler.plan(
            instance = instance(status = CourseInstanceStatus.CANCELLED),
            course = course,
            existing = existing(),
            now = Instant.parse("2026-10-12T09:30:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Cancel)
        assertEquals("follow_up_1", (decision as FollowUpDecision.Cancel).followUpId)
    }

    @Test
    fun cancelledClassWithoutExistingFollowUpIsSkipped() {
        val decision = FollowUpScheduler.plan(
            instance = instance(status = CourseInstanceStatus.CANCELLED),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T09:30:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Skip)
    }

    @Test
    fun courseWithoutFollowUpEnabledCancelsExisting() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course.copy(enabled = false),
            existing = existing(),
            now = Instant.parse("2026-10-12T10:06:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Cancel)
    }

    @Test
    fun deliveredFollowUpIsNotPushedAgain() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = existing(state = FollowUpState.DELIVERED),
            now = Instant.parse("2026-10-12T10:30:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Skip)
    }

    @Test
    fun snoozeReschedulesSameFollowUpInsteadOfCreatingNewOne() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = existing(state = FollowUpState.SNOOZED, snoozeUntil = "2026-10-12T11:00:00Z"),
            now = Instant.parse("2026-10-12T10:10:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Reschedule)
        assertEquals("follow_up_1", (decision as FollowUpDecision.Reschedule).followUpId)
        assertEquals(Instant.parse("2026-10-12T11:00:00Z"), decision.scheduledAt)
    }

    @Test
    fun snoozeInThePastDeliversNow() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = existing(state = FollowUpState.SNOOZED, snoozeUntil = "2026-10-12T10:20:00Z"),
            now = Instant.parse("2026-10-12T10:30:00Z"),
        )
        assertEquals(Instant.parse("2026-10-12T10:30:00Z"), (decision as FollowUpDecision.Reschedule).scheduledAt)
    }

    @Test
    fun backToBackClassesAreChainedIntoOneFollowUp() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
            laterInstances = listOf(instance(id = "instance_2", start = "2026-10-12T10:05:00Z", end = "2026-10-12T11:00:00Z")),
        )
        // 连堂中间不打断：等到最后一节结束再加延迟。
        assertEquals(Instant.parse("2026-10-12T11:05:00Z"), (decision as FollowUpDecision.Plan).scheduledAt)
    }

    @Test
    fun longGapBreaksTheChain() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
            laterInstances = listOf(instance(id = "instance_2", start = "2026-10-12T13:00:00Z", end = "2026-10-12T14:00:00Z")),
        )
        assertEquals(Instant.parse("2026-10-12T10:05:00Z"), (decision as FollowUpDecision.Plan).scheduledAt)
    }

    @Test
    fun overdueBeyondGraceIsNotDeliveredLate() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T14:00:00Z"),
        )
        assertTrue(decision is FollowUpDecision.Skip)
        assertTrue((decision as FollowUpDecision.Skip).reason.contains("不补发"))
    }

    @Test
    fun withinGraceDeliversImmediatelyInsteadOfInThePast() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course,
            existing = null,
            now = Instant.parse("2026-10-12T11:30:00Z"),
        )
        assertEquals(Instant.parse("2026-10-12T11:30:00Z"), (decision as FollowUpDecision.Plan).scheduledAt)
    }

    @Test
    fun firstOfDayModeSkipsWhenAlreadyFollowedUpToday() {
        val decision = FollowUpScheduler.plan(
            instance = instance(),
            course = course.copy(mode = FollowUpMode.FIRST_OF_DAY),
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
            deliveredTodayCount = 1,
        )
        assertTrue(decision is FollowUpDecision.Skip)
    }

    @Test
    fun manualOnlyModeNeedsUserMarkedDifficulty() {
        val skipped = FollowUpScheduler.plan(
            instance = instance(),
            course = course.copy(mode = FollowUpMode.MANUAL_ONLY),
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
        )
        assertTrue(skipped is FollowUpDecision.Skip)

        val planned = FollowUpScheduler.plan(
            instance = instance(),
            course = course.copy(mode = FollowUpMode.MANUAL_ONLY),
            existing = null,
            now = Instant.parse("2026-10-12T10:00:00Z"),
            userMarkedDifficult = true,
        )
        assertTrue(planned is FollowUpDecision.Plan)
    }

    @Test
    fun chainIgnoresCancelledLaterInstances() {
        val end = FollowUpScheduler.chainEndOf(
            instance = instance(),
            laterInstances = listOf(
                instance(id = "instance_2", start = "2026-10-12T10:05:00Z", end = "2026-10-12T11:00:00Z", status = CourseInstanceStatus.CANCELLED),
            ),
            policy = FollowUpPolicy(),
        )
        assertEquals(Instant.parse("2026-10-12T10:00:00Z"), end)
    }
}
