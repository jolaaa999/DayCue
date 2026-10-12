package com.daycue.android.platform.work

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.notify.NotificationChannels
import com.daycue.android.platform.notify.ReminderScheduler
import com.daycue.android.platform.platformDependenciesOrNull
import java.time.ZoneId

/**
 * 课表实例与课后追问的定期刷新。
 *
 * 做四件事：展开未来实例 → 重排追问 → 取到点的追问 → 交给 AlarmManager。
 *
 * 为什么「到点」这一步在 WorkManager 里做、发通知却在 AlarmManager 里做：
 * 追问的时刻是「课程预计结束后 N 分钟」，课表本身会有停课/调课，兜底探测放周期作业里最稳；
 * 而真正要准点的是通知本身，必须交给 AlarmManager。这样既不会用 WorkManager 冒充准点提醒，
 * 也不会因为课表变化让追问永远排不上。
 */
class ScheduleRefreshWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val dependencies = applicationContext.platformDependenciesOrNull()
            ?: return Result.failure(workDataOf(KEY_ERROR to "AppContainer 尚不可用（初始化顺序异常），本次课表刷新未执行"))

        val term = dependencies.settingsRepository.termCalendar()
        if (term == null) {
            // 没有学期基准就算不出任何实例。这不是失败：用户还没设置学期是合法状态，
            // 返回 failure 只会让 WorkManager 反复重试并写满日志。
            Log.i(TAG, "学期基准尚未设置，跳过课表展开与追问排程")
            return Result.success()
        }

        // 时区取设备当前时区：课程规则里的时间都是本地墙钟时间，展开必须落在用户所在的时区。
        val zone = ZoneId.systemDefault()
        val now = dependencies.timeSource.now()

        var inserted = 0
        for (course in dependencies.scheduleRepository.listCourses()) {
            inserted += dependencies.scheduleRepository.expandAndPersist(course.id, term, zone)
        }

        // 每次都重跑调度器而不是「排过就不动」：停课/调课后作废的追问必须被取消。
        val changed = dependencies.followUpRepository.scheduleUpcoming(term, zone, now = now)

        val capability = CapabilityProbe.report(applicationContext)
        val scheduler = ReminderScheduler(applicationContext)
        NotificationChannels.ensure(applicationContext)

        var scheduled = 0
        for (delivery in dependencies.followUpRepository.dueForDelivery(zone, now = now)) {
            val courseName = dependencies.scheduleRepository.findCourse(delivery.courseId)?.name ?: "课程"
            // 用同一个 followUpId 安排会命中同一个 PendingIntent，重复调用只会覆盖旧的，
            // 所以这里不需要额外的去重表。追问允许窗口，精确能力可用时才要求准点。
            scheduler.scheduleFollowUp(
                followUpId = delivery.followUpId,
                at = delivery.deliverAt,
                courseName = courseName,
                exact = capability.exactAlarmAllowed,
            )
            scheduled += 1
        }

        Log.i(
            TAG,
            "课表刷新完成：新增实例 " + inserted + "，追问变化 " + changed + "，已安排到点追问 " + scheduled,
        )
        return Result.success()
    }

    private companion object {
        const val TAG = "ScheduleRefreshWorker"
        const val KEY_ERROR = "error"
    }
}
