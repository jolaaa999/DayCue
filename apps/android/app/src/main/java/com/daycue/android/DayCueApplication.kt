package com.daycue.android

import android.app.Application
import android.util.Log
import androidx.work.Configuration
import com.daycue.android.platform.notify.NotificationChannels
import com.daycue.android.platform.outbox.OutboxExecutors
import kotlinx.coroutines.launch

/**
 * 应用入口。
 *
 * onCreate 里只做三件必须尽早完成的事：建容器、建通知渠道、登记周期作业。
 * 通知渠道必须在发出第一条通知之前创建（Android 8+ 会静默丢弃没有渠道的通知），
 * 所以它不能等到用户第一次打开设置页才建。
 */
private const val TAG = "DayCueApplication"

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
        // 进程重启后的地点规则重建。
        //
        // 系统里的围栏注册与 AlarmManager 排程都不跨进程重启，这里做一次注册对账，
        // 把「应该监控哪些地点」与「实际还挂着哪些」对齐；不对账会漏注册，
        // 表现为「规则开着但再也不响」。失败只记日志：下一次回前台或开机还会再试。
        container.applicationScope.launch {
            runCatching { container.geoCoordinator.refreshRegistration() }
                .onFailure { Log.w(TAG, "启动时重建地点规则注册失败", it) }
        }
        // 设备能力与 IANA 时区上报。
        //
        // 放在启动时做一次：能力（权限）随时可能被用户改，每次启动现读一次最接近事实；
        // 时区也在这里现读，用户跨时区或改了系统时区之后下一次启动就会修正。
        // 纯本地模式不发起任何请求——那是这个产品的合法形态，静默联网才是错的。
        container.applicationScope.launch {
            if (container.isPurelyLocal()) {
                Log.i(TAG, "纯本地模式，跳过设备上报")
                return@launch
            }
            container.deviceReportService.report()
                .onSuccess { outcome ->
                    Log.i(TAG, "设备已上报：" + outcome.deviceId + "，时区 " + outcome.reportedTimezone)
                }
                .onFailure { error -> Log.w(TAG, "设备上报失败，本次跳过（不影响本地功能）", error) }
        }
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
