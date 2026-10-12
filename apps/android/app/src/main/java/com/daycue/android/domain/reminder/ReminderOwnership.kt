package com.daycue.android.domain.reminder

import java.time.Instant

/**
 * 提醒的执行方。
 *
 * 铁律：同一条任务到点只能有一个执行方。两个都排就会「响两次」，
 * 所以切换执行方时**先取消旧的**，再安排新的。
 */
enum class ReminderOwner(val displayName: String) {
    APP_LOCAL("App 内提醒"),
    EXTERNAL_PROVIDER("外部提供方（如 iPhone 上的提醒事项）"),
    NONE("不提醒"),
}

/** 本地投递能力。Android 12+ 的精确闹钟是可选能力，不是理所当然。 */
enum class LocalDelivery { EXACT, INEXACT, NONE }

data class ReminderCapability(
    val notificationsAllowed: Boolean,
    val exactAlarmAllowed: Boolean,
) {
    val localDelivery: LocalDelivery
        get() = when {
            !notificationsAllowed -> LocalDelivery.NONE
            exactAlarmAllowed -> LocalDelivery.EXACT
            // 精确闹钟不可用时降级为不精确，而不是「假装准点」。
            else -> LocalDelivery.INEXACT
        }
}

/** 任务当前的提醒状态快照，用来判断「需不需要先取消旧的」。 */
data class TaskReminderSnapshot(
    val taskId: String,
    val remindAt: Instant?,
    /** 当前实际生效的执行方（不是期望值）。 */
    val currentOwner: ReminderOwner = ReminderOwner.NONE,
    val localAlarmScheduled: Boolean = false,
    val externalWritten: Boolean = false,
    val externalWriteRequested: Boolean = false,
)

sealed interface ReminderAction {
    data class ScheduleLocalAlarm(
        val taskId: String,
        val at: Instant,
        val exact: Boolean,
    ) : ReminderAction

    data class CancelLocalAlarm(val taskId: String) : ReminderAction

    data class RequestExternalWrite(val taskId: String) : ReminderAction

    data class CancelExternalReminder(val taskId: String, val reason: String) : ReminderAction
}

data class ReminderPlan(
    val owner: ReminderOwner,
    val actions: List<ReminderAction>,
    /** 必须显示给用户的降级说明（不精确、无通知权限、外部未写入）。不能只写日志。 */
    val notices: List<String>,
)

/** 计划执行完之后的状态，用于断言「只有一个执行方」。 */
data class ReminderState(
    val localScheduled: Boolean,
    val externalWritten: Boolean,
    val owner: ReminderOwner,
    val at: Instant?,
) {
    /** 到点提醒的执行方数量。必须 ≤ 1。 */
    val activeChannelCount: Int = (if (localScheduled) 1 else 0) + (if (externalWritten) 1 else 0)
}

/**
 * 通知归属决策。
 *
 * 与 iOS 的 NotificationService / ReminderService 分工一致：
 * 用户把某条任务的提醒交给外部提供方后，App **不再**为它安排本地闹钟；
 * 外部还没写成功时先用本地提醒兜底，并在界面上说清楚「尚未写入」；
 * 用户改回 App 内提醒、或撤销外部写入时，先取消外部，再安排本地。
 */
object ReminderOwnership {

    fun plan(
        desiredOwner: ReminderOwner,
        snapshot: TaskReminderSnapshot,
        capability: ReminderCapability,
    ): ReminderPlan {
        val actions = ArrayList<ReminderAction>()
        val notices = ArrayList<String>()

        // 撤销：没有提醒时刻就不再保留任何执行方。
        if (desiredOwner == ReminderOwner.NONE || snapshot.remindAt == null) {
            if (snapshot.localAlarmScheduled) actions += ReminderAction.CancelLocalAlarm(snapshot.taskId)
            if (snapshot.externalWriteRequested || snapshot.externalWritten) {
                actions += ReminderAction.CancelExternalReminder(snapshot.taskId, "用户撤销了提醒")
            }
            return ReminderPlan(ReminderOwner.NONE, actions, notices)
        }

        val at = snapshot.remindAt

        when (desiredOwner) {
            ReminderOwner.APP_LOCAL -> {
                // 先取消旧的执行方，再安排新的：顺序反了会出现「响两次」的窗口。
                if (snapshot.externalWriteRequested || snapshot.externalWritten) {
                    actions += ReminderAction.CancelExternalReminder(snapshot.taskId, "提醒执行方改为 App 内")
                }
                when (capability.localDelivery) {
                    LocalDelivery.EXACT -> actions += ReminderAction.ScheduleLocalAlarm(snapshot.taskId, at, exact = true)
                    LocalDelivery.INEXACT -> {
                        actions += ReminderAction.ScheduleLocalAlarm(snapshot.taskId, at, exact = false)
                        notices += "系统未授予精确闹钟权限，这条提醒可能延迟几分钟。"
                    }
                    LocalDelivery.NONE -> notices += "通知权限未开启，这条提醒不会弹出；它仍会出现在今天页。"
                }
            }

            ReminderOwner.EXTERNAL_PROVIDER -> {
                // 先把本地闹钟取消，避免与外部提醒重复。
                if (snapshot.localAlarmScheduled) {
                    actions += ReminderAction.CancelLocalAlarm(snapshot.taskId)
                }
                if (!snapshot.externalWritten) {
                    actions += ReminderAction.RequestExternalWrite(snapshot.taskId)
                    // 外部写入是异步且可能失败的，失败时不能让用户彻底失去提醒，所以本地兜底。
                    when (capability.localDelivery) {
                        LocalDelivery.EXACT -> actions += ReminderAction.ScheduleLocalAlarm(snapshot.taskId, at, exact = true)
                        LocalDelivery.INEXACT -> {
                            actions += ReminderAction.ScheduleLocalAlarm(snapshot.taskId, at, exact = false)
                            notices += "系统未授予精确闹钟权限，兜底提醒可能延迟几分钟。"
                        }
                        LocalDelivery.NONE -> notices += "通知权限未开启，写入外部之前不会有任何提醒。"
                    }
                    notices += "这条任务尚未写入外部提供方，App 会先本地提醒；写入成功后自动取消本地提醒。"
                }
            }

            ReminderOwner.NONE -> Unit
        }

        return ReminderPlan(desiredOwner, actions, notices)
    }

    /**
     * 把计划作用到快照上，得到执行后的状态。
     * 单独抽出来是为了能直接断言那条铁律：任何组合下 activeChannelCount 都 ≤ 1。
     */
    fun apply(snapshot: TaskReminderSnapshot, plan: ReminderPlan): ReminderState {
        var localScheduled = snapshot.localAlarmScheduled
        var externalWritten = snapshot.externalWritten
        var at: Instant? = snapshot.remindAt

        for (action in plan.actions) {
            when (action) {
                is ReminderAction.ScheduleLocalAlarm -> {
                    localScheduled = true
                    at = action.at
                }

                is ReminderAction.CancelLocalAlarm -> {
                    localScheduled = false
                    at = null
                }

                is ReminderAction.RequestExternalWrite -> {
                    // 只是发起请求，还不算写入成功——这种区分正是「不许虚报已写入」的落点。
                }

                is ReminderAction.CancelExternalReminder -> {
                    externalWritten = false
                }
            }
        }

        val hasChannel = localScheduled || externalWritten
        return ReminderState(
            localScheduled = localScheduled,
            externalWritten = externalWritten,
            owner = plan.owner,
            // 只取消了本地闹钟、外部仍然保留时，提醒的有效时刻并没有消失。
            at = if (hasChannel) (at ?: snapshot.remindAt) else null,
        )
    }
}
