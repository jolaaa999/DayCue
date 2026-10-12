package com.daycue.android.platform.work

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * 后台作业的统一排程入口。
 *
 * 只做两件事：周期作业（刷新课表 / 重试 outbox）与手动触发的一次性作业。
 * 周期用 15 分钟——这是 WorkManager 允许的最小周期，再短会被系统拒绝；
 * 追问的准确到点不靠这个周期，而靠周期作业算出来后交给 AlarmManager（见 ReminderScheduler）。
 */
class DayCueWorkScheduler(private val context: Context) {

    private val workManager: WorkManager
        get() = WorkManager.getInstance(context.applicationContext)

    fun schedulePeriodic() {
        // KEEP 而不是 REPLACE：每次开机都重新排一遍会把周期计时清零，
        // 结果是「重启越频繁，后台作业越跑不到」。
        workManager.enqueueUniquePeriodicWork(
            SCHEDULE_REFRESH_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<ScheduleRefreshWorker>(PERIODIC_MINUTES, TimeUnit.MINUTES).build(),
        )
        // 不给 outbox 作业加 CONNECTED 约束：worker 内部要区分「没网」和「没配后端」两种情况，
        // 加了约束就永远走不到那个分支，两处判断会分叉成两套逻辑。
        workManager.enqueueUniquePeriodicWork(
            OUTBOX_RETRY_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<OutboxRetryWorker>(PERIODIC_MINUTES, TimeUnit.MINUTES).build(),
        )
    }

    /** 用户手动点「立即重试同步」时用：一次性作业，重复点击用 REPLACE 合并成一次。 */
    fun enqueueOutboxRetryNow() {
        workManager.enqueueUniqueWork(
            OUTBOX_RETRY_NOW,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<OutboxRetryWorker>().build(),
        )
    }

    /** 课表变更（导入 ICS、改规则）后立即重算实例与追问。 */
    fun enqueueScheduleRefreshNow() {
        workManager.enqueueUniqueWork(
            SCHEDULE_REFRESH_NOW,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<ScheduleRefreshWorker>().build(),
        )
    }

    fun cancelAll() {
        workManager.cancelUniqueWork(SCHEDULE_REFRESH_PERIODIC)
        workManager.cancelUniqueWork(OUTBOX_RETRY_PERIODIC)
        workManager.cancelUniqueWork(SCHEDULE_REFRESH_NOW)
        workManager.cancelUniqueWork(OUTBOX_RETRY_NOW)
    }

    companion object {
        const val SCHEDULE_REFRESH_PERIODIC = "daycue.schedule_refresh.periodic"
        const val OUTBOX_RETRY_PERIODIC = "daycue.outbox_retry.periodic"
        const val SCHEDULE_REFRESH_NOW = "daycue.schedule_refresh.now"
        const val OUTBOX_RETRY_NOW = "daycue.outbox_retry.now"

        /** WorkManager 的周期下限就是 15 分钟，写常量是为了让「为什么不能再快」有落点。 */
        const val PERIODIC_MINUTES = 15L
    }
}
