package com.daycue.android.platform

import android.content.Context
import android.util.Log
import com.daycue.android.AppContainer
import com.daycue.android.DayCueApplication
import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.repository.FollowUpRepository
import com.daycue.android.data.repository.ScheduleRepository
import com.daycue.android.data.repository.SettingsRepository
import com.daycue.android.data.repository.SyncRepository
import com.daycue.android.data.repository.TaskRepository
import com.daycue.android.data.repository.TimeSource
import java.time.Instant

private const val TAG = "PlatformDependencies"

/**
 * 平台适配层需要的依赖视图。
 *
 * 为什么不直接在 Worker 里 new 数据库：后台组件（Worker / BroadcastReceiver）既拿不到 Compose 的上下文，
 * 也无法保证装配顺序。这里只是把 Application 已经装好的 [AppContainer] 转成一份平台层专用的、
 * 最小化的依赖表：worker 因此能换成假仓储做测试，而业务代码一行都不用改。
 */
data class PlatformDependencies(
    /** 时间必须从注入源取：后台作业与界面共用同一基准，测试才能控制「现在」。 */
    val timeSource: TimeSource,
    val settingsRepository: SettingsRepository,
    val syncRepository: SyncRepository,
    /**
     * 直接暴露 DAO 只为一件事：把「可重试的失败」重新排回 pending。
     * SyncRepository 没有暴露这个动作，而 markFailed 会把记录变成终态（可执行查询只认 pending）。
     */
    val outboxDao: OutboxDao,
    val taskRepository: TaskRepository,
    val scheduleRepository: ScheduleRepository,
    val followUpRepository: FollowUpRepository,
    /**
     * outbox 操作的实际执行者，来源见 [OutboxExecutionRegistry]。
     *
     * 允许为 null 是刻意的：Android 端当前没有可写的外部提供方（iPhone 提醒事项桥接尚未接入），
     * 此时宁可不执行、如实把记录留在 pending，也不要伪造一次成功、更不要把它标成 failed。
     * 一旦有人调用 [OutboxExecutionRegistry.install]，worker 就会真正推进 outbox。
     */
    val outboxExecutor: OutboxOperationExecutor? = null,
)

/**
 * outbox 执行者的注册点。
 *
 * 为什么用注册表而不是给 AppContainer 加字段：平台层不允许改容器（它属于设备骨架），
 * 而「谁来执行 outbox」是接入外部写入能力时才需要回答的问题。留一个显式的注册口，
 * 既不伪造执行者，也不把「还没接桥接」这件事变成编译错误。
 */
object OutboxExecutionRegistry {

    @Volatile
    private var executor: OutboxOperationExecutor? = null

    fun install(executor: OutboxOperationExecutor?) {
        this.executor = executor
    }

    fun current(): OutboxOperationExecutor? = executor
}

/**
 * 取平台依赖；拿不到就返回 null 而不是抛异常。
 *
 * 后台组件抛异常会让 WorkManager 反复重试并放大问题，明确返回 null 至少能在日志里定位。
 */
fun Context.platformDependenciesOrNull(): PlatformDependencies? {
    val application = applicationContext as? DayCueApplication ?: return null
    return try {
        fromContainer(application.container)
    } catch (e: Throwable) {
        // container 是 lateinit：理论上后台组件运行时 Application.onCreate 早已完成，
        // 这里兜住只是为了防止「初始化顺序被改动」演变成一次难以复现的崩溃。
        Log.e(TAG, "读取 AppContainer 失败，按拿不到依赖处理", e)
        null
    }
}

/** 把容器转成平台层依赖。公开是为了让单测能自己造一个假容器，而不必起进程。 */
fun fromContainer(container: AppContainer): PlatformDependencies = PlatformDependencies(
    timeSource = container.timeSource,
    settingsRepository = container.settingsRepository,
    syncRepository = container.syncRepository,
    outboxDao = container.database.outboxDao(),
    taskRepository = container.taskRepository,
    scheduleRepository = container.scheduleRepository,
    followUpRepository = container.followUpRepository,
    outboxExecutor = OutboxExecutionRegistry.current(),
)

/**
 * outbox 一次执行的结果。
 *
 * 三类失败必须分开：把「可能已经写成功」当成「确定失败」重试，会让外部系统多出一条提醒。
 */
sealed interface OutboxExecution {
    /** 确定成功。 */
    data object Succeeded : OutboxExecution

    /** 确定没执行成功，且稍后重试是安全的（网络不通、被限流）。 */
    data class Retryable(val message: String, val retryAt: Instant? = null) : OutboxExecution

    /** 确定没执行成功，且自动重试没有意义（参数非法、外部提供方不存在）。 */
    data class Failed(val message: String) : OutboxExecution

    /** 不知道是否已执行成功：只能标记未知并交给对账，绝不能当 failed 直接重试。 */
    data class Unknown(val message: String) : OutboxExecution
}

/** outbox 操作的实际执行动作。做成接口是为了让 worker 只负责状态机，执行细节可替换、可测试。 */
fun interface OutboxOperationExecutor {
    suspend fun execute(operation: OutboxOperationRecord): OutboxExecution
}
