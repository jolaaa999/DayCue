package com.daycue.android.platform.work

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.platform.OutboxExecution
import com.daycue.android.platform.PlatformDependencies
import com.daycue.android.platform.platformDependenciesOrNull
import kotlinx.coroutines.CancellationException
import java.time.Instant

/**
 * outbox 的重试作业。
 *
 * 状态机是这个类唯一的职责：取可执行的操作 → 抢占 → 执行 → 按结果推进状态。
 * 执行细节交给注入的 OutboxOperationExecutor，因为它必然依赖平台能力（外部提供方、网络）。
 *
 * 三条不可动摇的规则：
 * 1. 未配置后端或处于离线模式时**不碰任何记录**，直接 retry：状态是用户数据，不能因为没网就改动；
 * 2. 「不确定是否执行成功」必须标 unknown 走对账，绝不当 failed 直接重试——那会让外部多出一条提醒；
 * 3. 提取与执行之间必须经过 claim，两个 worker 同时跑也不会重复执行同一条。
 */
class OutboxRetryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val dependencies = applicationContext.platformDependenciesOrNull()
            ?: return Result.failure(workDataOf(KEY_ERROR to "AppContainer 尚不可用（初始化顺序异常），未执行任何 outbox 操作"))

        // 纯本地模式（没配后端或用户开了离线）不是错误：outbox 里的记录原样留着，等条件具备再执行。
        if (dependencies.settingsRepository.isPurelyLocal()) {
            Log.i(TAG, "后端未配置或处于离线模式，保留 outbox 状态并稍后重试")
            return Result.retry()
        }

        val executor = dependencies.outboxExecutor
        if (executor == null) {
            // 没有执行者时宁可什么都不做：假成功会让用户以为已经同步，标失败则等于放弃这些操作。
            Log.e(TAG, "没有注册 OutboxOperationExecutor（见 OutboxExecutionRegistry），outbox 保持不变")
            return Result.retry()
        }

        val now = dependencies.timeSource.now()
        recoverStaleRunning(dependencies, now)

        var retryNeeded = false
        for (operation in dependencies.syncRepository.executable(now)) {
            // claim 失败说明别的 worker 已经抢到它了，直接跳过而不是执行两次。
            if (!dependencies.syncRepository.claim(operation.id)) continue
            val claimed = dependencies.syncRepository.findOperation(operation.id) ?: operation

            val outcome = try {
                executor.execute(claimed)
            } catch (e: CancellationException) {
                // 被系统叫停时不能替这条操作下结论：它可能已经执行了一半。
                throw e
            } catch (e: Throwable) {
                OutboxExecution.Unknown("执行过程中抛出异常，无法确认结果：" + (e.message ?: e::class.java.simpleName))
            }

            when (outcome) {
                is OutboxExecution.Succeeded -> dependencies.syncRepository.markSucceeded(claimed.id)

                is OutboxExecution.Retryable -> {
                    requeueForRetry(dependencies, claimed, outcome)
                    retryNeeded = true
                }

                is OutboxExecution.Failed ->
                    dependencies.syncRepository.markFailed(claimed.id, outcome.message, null)

                is OutboxExecution.Unknown ->
                    dependencies.syncRepository.markUnknown(claimed.id, outcome.message)
            }
        }

        return if (retryNeeded) Result.retry() else Result.success()
    }

    /**
     * 把「确定没执行成功、但重试是安全的」重新排回 pending。
     *
     * 为什么直接调 DAO：SyncRepository 没有暴露「重新排队」，而 markFailed 会把 state 写成 failed，
     * 可执行的查询只认 pending——用 markFailed 等于把一次网络抖动变成永久失败。
     * 这里只改自己读出来的那条记录（copy + @Update 按主键更新），不碰数据层代码。
     */
    private suspend fun requeueForRetry(
        dependencies: PlatformDependencies,
        record: OutboxOperationRecord,
        outcome: OutboxExecution.Retryable,
    ) {
        val now = dependencies.timeSource.now()
        dependencies.outboxDao.update(
            record.copy(
                state = OutboxState.PENDING,
                lastError = outcome.message,
                nextRetryAt = outcome.retryAt ?: now.plusSeconds(RETRY_DELAY_SECONDS),
                updatedAt = now,
            ),
        )
    }

    /**
     * 回收上次进程被中断留下的 running 记录。
     *
     * 可执行查询只认 pending，running 永远不会被再次拾取；不处理的话这些操作会永远消失。
     * 不知道它到底执行没执行，所以只能标 unknown 交给对账（这也正是状态机的设计意图）。
     * 用 15 分钟门槛而不是立即回收：CoroutineWorker 最长执行 10 分钟，超过门槛的一定不是本次在跑的。
     */
    private suspend fun recoverStaleRunning(dependencies: PlatformDependencies, now: Instant) {
        val running = try {
            dependencies.outboxDao.listByState(OutboxState.RUNNING)
        } catch (e: Exception) {
            Log.w(TAG, "读取 running 状态的 outbox 失败", e)
            return
        }
        for (record in running) {
            val ageMillis = now.toEpochMilli() - record.updatedAt.toEpochMilli()
            if (ageMillis < STALE_RUNNING_MILLIS) continue
            Log.w(TAG, "outbox 记录长时间停留在 running，标记为未知等待对账：" + record.id)
            dependencies.syncRepository.markUnknown(
                record.id,
                "上次执行被中断且结果未知，已停止自动重写，等待与外部对账。",
            )
        }
    }

    private companion object {
        const val TAG = "OutboxRetryWorker"
        const val KEY_ERROR = "error"

        /** 与 iOS 的 60 秒对齐：同一条操作重试太快既没意义，也容易触发后端限流。 */
        const val RETRY_DELAY_SECONDS = 60L
        const val STALE_RUNNING_MILLIS = 15L * 60L * 1000L
    }
}
