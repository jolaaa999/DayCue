package com.daycue.android

import android.app.Application
import android.util.Log
import androidx.work.Configuration
import com.daycue.android.platform.notify.NotificationChannels
import com.daycue.android.platform.outbox.OutboxExecutors

/**
 * 应用入口。
 *
 * onCreate 里只做三件必须尽早完成的事：建容器、建通知渠道、登记周期作业。
 * 通知渠道必须在发出第一条通知之前创建（Android 8+ 会静默丢弃没有渠道的通知），
 * 所以它不能等到用户第一次打开设置页才建。
 */
class DayCueApplication : Application(), Configuration.Provider {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // 注册 outbox 的真实执行者。不注册的话后台作业拿不到执行者，
        // 记录只会一直留在 pending，用户看到"待执行"却永远不会动。
        OutboxExecutors.install(container)
        NotificationChannels.ensure(this)
        // 周期作业交给 WorkManager 持久化，进程被杀掉后系统仍会择机唤醒。
        container.workScheduler.schedulePeriodic()
    }

    /**
     * WorkManager 的按需初始化配置。
     *
     * 用默认配置即可（默认线程池 + 应用到点唤醒），这里显式实现只是为了让清单里
     * 移除默认 InitializationProvider 的行为有一个对应的提供者，避免出现「Worker 永远不跑」。
     */
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setMinimumLoggingLevel(Log.INFO)
            .build()
}
