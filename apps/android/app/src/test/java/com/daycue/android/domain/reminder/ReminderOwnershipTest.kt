package com.daycue.android.domain.reminder

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * 通知归属。
 *
 * 核心不变式只有一条：**同一条任务到点只能有一个执行方**。
 * 除此之外还要钉住「切换时先取消旧的」这个顺序——顺序反了会出现一段两个通道都有效的窗口。
 */
class ReminderOwnershipTest {

    private val remindAt = Instant.parse("2026-10-12T12:00:00Z")

    private fun snapshot(
        remindAt: Instant? = Instant.parse("2026-10-12T12:00:00Z"),
        currentOwner: ReminderOwner = ReminderOwner.NONE,
        localAlarmScheduled: Boolean = false,
        externalWritten: Boolean = false,
        externalWriteRequested: Boolean = false,
    ) = TaskReminderSnapshot(
        taskId = "task_1",
        remindAt = remindAt,
        currentOwner = currentOwner,
        localAlarmScheduled = localAlarmScheduled,
        externalWritten = externalWritten,
        externalWriteRequested = externalWriteRequested,
    )

    private val fullCapability = ReminderCapability(notificationsAllowed = true, exactAlarmAllowed = true)

    @Test
    fun switchingFromAppLocalToExternalCancelsLocalAlarmFirst() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.EXTERNAL_PROVIDER,
            snapshot = snapshot(localAlarmScheduled = true),
            capability = fullCapability,
        )
        assertTrue(plan.actions.first() is ReminderAction.CancelLocalAlarm)
        assertTrue(plan.actions.any { it is ReminderAction.RequestExternalWrite })
    }

    @Test
    fun switchingFromExternalToAppLocalCancelsExternalFirst() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.APP_LOCAL,
            snapshot = snapshot(externalWritten = true, currentOwner = ReminderOwner.EXTERNAL_PROVIDER),
            capability = fullCapability,
        )
        assertTrue(plan.actions.first() is ReminderAction.CancelExternalReminder)
        assertTrue(plan.actions.any { it is ReminderAction.ScheduleLocalAlarm })
    }

    @Test
    fun externalNotYetWrittenFallsBackToLocalAlarmAndTellsTheUser() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.EXTERNAL_PROVIDER,
            snapshot = snapshot(),
            capability = fullCapability,
        )
        assertTrue(plan.actions.any { it is ReminderAction.RequestExternalWrite })
        // 外部写入是异步且可能失败的，失败时不能让用户彻底失去提醒。
        val local = plan.actions.filterIsInstance<ReminderAction.ScheduleLocalAlarm>().single()
        assertTrue(local.exact)
        assertTrue(plan.notices.any { it.contains("尚未写入") })
    }

    @Test
    fun externalAlreadyWrittenLeavesExactlyOneChannel() {
        val snapshot = snapshot(localAlarmScheduled = true, externalWritten = true)
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.EXTERNAL_PROVIDER,
            snapshot = snapshot,
            capability = fullCapability,
        )
        val state = ReminderOwnership.apply(snapshot, plan)
        assertFalse(state.localScheduled)
        assertTrue(state.externalWritten)
        assertEquals(1, state.activeChannelCount)
        assertEquals(remindAt, state.at)
    }

    @Test
    fun revokingReminderCancelsEveryChannel() {
        val snapshot = snapshot(localAlarmScheduled = true, externalWritten = true)
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.NONE,
            snapshot = snapshot,
            capability = fullCapability,
        )
        val state = ReminderOwnership.apply(snapshot, plan)
        assertEquals(0, state.activeChannelCount)
        assertEquals(null, state.at)
        assertEquals(ReminderOwner.NONE, state.owner)
    }

    @Test
    fun removingReminderTimeCancelsRegardlessOfRequestedOwner() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.EXTERNAL_PROVIDER,
            snapshot = snapshot(remindAt = null, externalWritten = true),
            capability = fullCapability,
        )
        assertEquals(ReminderOwner.NONE, plan.owner)
        assertTrue(plan.actions.any { it is ReminderAction.CancelExternalReminder })
    }

    @Test
    fun exactAlarmUnavailableDegradesToInexactAndWarns() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.APP_LOCAL,
            snapshot = snapshot(),
            capability = ReminderCapability(notificationsAllowed = true, exactAlarmAllowed = false),
        )
        val local = plan.actions.filterIsInstance<ReminderAction.ScheduleLocalAlarm>().single()
        assertFalse(local.exact)
        assertTrue(plan.notices.any { it.contains("精确闹钟") })
    }

    @Test
    fun notificationsDeniedMeansNoAlarmButTaskStillVisible() {
        val plan = ReminderOwnership.plan(
            desiredOwner = ReminderOwner.APP_LOCAL,
            snapshot = snapshot(),
            capability = ReminderCapability(notificationsAllowed = false, exactAlarmAllowed = true),
        )
        assertTrue(plan.actions.none { it is ReminderAction.ScheduleLocalAlarm })
        assertTrue(plan.notices.any { it.contains("通知权限") })
    }

    @Test
    fun localDeliveryCapabilityFollowsPermissions() {
        assertEquals(
            LocalDelivery.NONE,
            ReminderCapability(notificationsAllowed = false, exactAlarmAllowed = true).localDelivery,
        )
        assertEquals(
            LocalDelivery.INEXACT,
            ReminderCapability(notificationsAllowed = true, exactAlarmAllowed = false).localDelivery,
        )
        assertEquals(
            LocalDelivery.EXACT,
            ReminderCapability(notificationsAllowed = true, exactAlarmAllowed = true).localDelivery,
        )
    }

    @Test
    fun atMostOneChannelIsActiveForEveryOwnerAndStateCombination() {
        val owners = listOf(ReminderOwner.APP_LOCAL, ReminderOwner.EXTERNAL_PROVIDER, ReminderOwner.NONE)
        val booleans = listOf(false, true)
        for (owner in owners) {
            for (local in booleans) {
                for (external in booleans) {
                    for (capability in listOf(
                        fullCapability,
                        ReminderCapability(notificationsAllowed = true, exactAlarmAllowed = false),
                        ReminderCapability(notificationsAllowed = false, exactAlarmAllowed = false),
                    )) {
                        val snapshot = snapshot(localAlarmScheduled = local, externalWritten = external)
                        val plan = ReminderOwnership.plan(owner, snapshot, capability)
                        val state = ReminderOwnership.apply(snapshot, plan)
                        assertTrue(
                            "组合 owner=" + owner + " local=" + local + " external=" + external +
                                " 出现了 " + state.activeChannelCount + " 个执行方",
                            state.activeChannelCount <= 1,
                        )
                    }
                }
            }
        }
    }

    @Test
    fun scheduleLocalAlarmOverridesStaleTime() {
        val snapshot = snapshot()
        val plan = ReminderPlan(
            owner = ReminderOwner.APP_LOCAL,
            actions = listOf(
                ReminderAction.ScheduleLocalAlarm("task_1", Instant.parse("2026-10-12T13:00:00Z"), exact = true),
            ),
            notices = emptyList(),
        )
        assertEquals(Instant.parse("2026-10-12T13:00:00Z"), ReminderOwnership.apply(snapshot, plan).at)
    }
}
