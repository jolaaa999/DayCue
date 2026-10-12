package com.daycue.android.platform.work

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.daycue.android.platform.outbox.OutboxExecutors
import com.daycue.android.platform.platformDependenciesOrNull

/**
 * outbox 的后台作业。
 *
 * 状态机已经搬进 OutboxProcessor（纯 Kotlin，因此能被 JVM 单测真正覆盖），
 * 这里只负责三件事：取依赖 → 确认有执行者 → 跑一轮。
 *
 * 为什么去掉了原来「纯本地模式整轮跳过」的判断：
 * Android 端 outbox 的目标是 **App 内待办**，是本机写入、根本不需要后端。
 * 原来的判断会让这些操作在没配后端时永远不执行 —— 而没配后端恰恰是默认状态。
 * 真正需要后端的操作（例如 extract_capture）不在已实现集合里，
 * 会被一次性终止并说明原因，而不是在这里等网络。
 */
class OutboxRetryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val dependencies = applicationContext.platformDependenciesOrNull()
            ?: return Result.failure(
                workDataOf(KEY_ERROR to "AppContainer 尚不可用（初始化顺序异常），未执行任何 outbox 操作"),
            )

        val executor = dependencies.outboxExecutor
        if (executor == null) {
            // 没有执行者时宁可什么都不做：假成功会让用户以为已经写入，标失败则等于放弃这些操作。
            Log.e(TAG, "没有注册 OutboxOperationExecutor（见 OutboxExecutors.install），outbox 保持不变")
            return Result.retry()
        }

        val summary = OutboxExecutors.processor(dependencies, executor).runOnce()
        Log.i(TAG, summary.describe())
        return if (summary.retryNeeded) Result.retry() else Result.success()
    }

    private companion object {
        const val TAG = "OutboxRetryWorker"
        const val KEY_ERROR = "error"
    }
}
