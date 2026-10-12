package com.daycue.android.platform.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.platformDependenciesOrNull
import com.daycue.android.platform.work.DayCueWorkScheduler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * 开机与升级后的重建。
 *
 * 没有它，重启会让所有已安排的闹钟静默消失（AlarmManager 的排程不跨重启），
 * WorkManager 的周期作业也需要一次机会重新确认。
 *
 * 用 goAsync()：重建要读数据库，属于 IO，而 onReceive 返回后进程随时可能被杀；
 * goAsync() 把「还没做完」这件事告诉系统，做完再 finish()。
 */
class BootCompletedReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        // 自己开一个作用域而不是用 GlobalScope：生命周期与这次广播一一对应，做完即结束。
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                rebuild(appContext)
            } catch (e: Throwable) {
                // 重建失败也不能让进程崩：下一次开机或下一次后台作业还会再试。
                Log.w(NOTIFY_LOG_TAG, "重启后重建提醒与周期作业失败", e)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private suspend fun rebuild(context: Context) {
        NotificationChannels.ensure(context)

        val dependencies = context.platformDependenciesOrNull()
        if (dependencies == null) {
            Log.e(
                NOTIFY_LOG_TAG,
                "AppContainer 尚不可用，无法重建提醒；提醒会等到下一次后台作业或下次开机再恢复。",
            )
            return
        }

        val capability = CapabilityProbe.report(context)
        val scheduler = ReminderScheduler(context)
        val now = dependencies.timeSource.now()

        // 任务提醒：只重建「还没到点」的。已经错过的时刻不该在开机后突然响一次。
        for (task in dependencies.taskRepository.listUpcomingReminders(now)) {
            val remindAt = task.remindUtc ?: continue
            val body = task.detail?.takeIf { it.isNotBlank() } ?: "你为这条任务设定的提醒时间到了。"
            // exact = true：这是用户自己设定的时刻，有精确闹钟能力就该准点；没有则由排程器降级并说明。
            scheduler.scheduleLocalAlarm(task.id, remindAt, exact = true, title = task.title, body = body)
        }

        // 课后追问：同样只恢复未来的。设计文档明确「过期不补发」，开机补一条昨晚的追问是打扰而不是帮助。
        rebuildFollowUps(dependencies, scheduler, capability.exactAlarmAllowed, now)

        // WorkManager 的周期作业在重启后由它自己恢复，这里再确认一次是幂等的（唯一作业 + KEEP），
        // 同时补一次立即刷新，把停机期间错过的课表变化与追问补算回来。
        DayCueWorkScheduler(context).apply {
            schedulePeriodic()
            enqueueScheduleRefreshNow()
        }
    }

    private suspend fun rebuildFollowUps(
        dependencies: com.daycue.android.platform.PlatformDependencies,
        scheduler: ReminderScheduler,
        exactAlarmAllowed: Boolean,
        now: Instant,
    ) {
        val outstanding = dependencies.followUpRepository.observeOutstanding().first()
        for (record in outstanding) {
            val at = when (record.state) {
                FollowUpState.SCHEDULED -> record.scheduledAtUtc
                // 「稍后提醒」也是用户明确要的，同样要恢复。
                FollowUpState.SNOOZED -> record.snoozeUntilUtc
                else -> null
            } ?: continue
            if (!at.isAfter(now)) continue

            val courseName = dependencies.scheduleRepository.findCourse(record.courseId)?.name ?: "课程"
            scheduler.scheduleFollowUp(record.id, at, courseName, exact = exactAlarmAllowed)
        }
    }
}
