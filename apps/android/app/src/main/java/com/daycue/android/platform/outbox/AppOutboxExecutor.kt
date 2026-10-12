package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.platform.OutboxExecution
import com.daycue.android.platform.OutboxOperationExecutor
import kotlinx.coroutines.CancellationException

/**
 * 按 op 字符串分发到具体处理者。
 *
 * 它就是注册进 OutboxExecutionRegistry 的那个执行者（见 OutboxExecutors）。
 *
 * 这里额外保留一道次数上限检查：万一主会话没有把 Worker 换成 OutboxProcessor，
 * 旧 Worker 直接调用本类时仍然能拿到「已达上限」的终止结论，
 * 而不会把一条永远失败的操作无限重排回 pending。
 *
 * 异常统一转成 Unknown：抛异常时无法判断「写了一半」还是「完全没写」，
 * 当成失败去重试可能让 App 内待办出现重复或状态的错误推进。
 */
class AppOutboxExecutor(
    private val handlers: Map<String, OutboxOperationHandler>,
    private val policy: OutboxRetryPolicy = OutboxRetryPolicy.DEFAULT,
) : OutboxOperationExecutor {

    override suspend fun execute(operation: OutboxOperationRecord): OutboxExecution {
        val handler = handlers[operation.op]
            ?: return OutboxExecution.Failed(OutboxOperationKinds.describeUnsupported(operation.op))

        if (!policy.hasAttemptsLeft(operation.attempt)) {
            return OutboxExecution.Failed(
                "重试次数已达上限 " + policy.maxAttempts +
                    "（上次原因：" + (operation.lastError ?: "未记录") + "）",
            )
        }

        return try {
            handler.execute(operation)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            OutboxExecution.Unknown("执行者抛出异常，无法确认结果：" + (e.message ?: e::class.java.simpleName))
        }
    }
}
