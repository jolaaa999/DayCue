package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.platform.OutboxExecution
import com.daycue.android.platform.OutboxOperationExecutor
import kotlinx.coroutines.CancellationException
import java.time.Duration
import java.time.Instant

/** 取消闸门：返回 true 表示这条操作不该再执行（用户取消了任务、实体已经不存在等）。 */
fun interface OutboxCancellationGate {
    suspend fun isCancelled(operation: OutboxOperationRecord): Boolean

    companion object {
        /** 不做任何取消判断的实现，供只关心编排逻辑的单测使用。 */
        val NeverCancelled: OutboxCancellationGate = object : OutboxCancellationGate {
            override suspend fun isCancelled(operation: OutboxOperationRecord): Boolean = false
        }
    }
}

/** 一次 runOnce 的结果。只用于日志与测试断言，不参与业务决策。 */
data class OutboxRunSummary(
    val claimed: Int = 0,
    val succeeded: Int = 0,
    val retried: Int = 0,
    val failed: Int = 0,
    val unknown: Int = 0,
    val deadLettered: Int = 0,
    val cancelled: Int = 0,
    val skipped: Int = 0,
) {
    val retryNeeded: Boolean get() = retried > 0

    val processed: Int
        get() = succeeded + retried + failed + unknown + deadLettered + cancelled

    fun describe(): String = "outbox 本轮：抢占 " + claimed + "，成功 " + succeeded + "，重试 " + retried +
        "，失败 " + failed + "，未知 " + unknown + "，终止 " + deadLettered + "，取消 " + cancelled +
        "，跳过 " + skipped
}

/**
 * outbox 状态机。
 *
 * 为什么把它从 Worker 里拿出来：Worker 是 Android-only 的 CoroutineWorker，
 * JVM 单测起不来；而「五种结局分别写什么状态」恰恰是最需要被测试钉死的部分。
 * 这里只依赖 TimeSource、执行者与持久化端口，可以在纯 JVM 里走到每一条分支。
 *
 * 五条不可动摇的规则：
 * 1. 只有抢到 claim 的操作才执行，两个 worker 同时跑也不会重复执行同一条；
 * 2. 结果不确定一律 unknown 交对账，绝不当作确定失败重试；
 * 3. 可重试失败必须有次数上限，到顶即终止（failed），不再回到 pending；
 * 4. 未注册/未实现的操作一次性终止（dead_letter）并写明原因，绝不无限排队；
 * 5. 被取消的操作不再执行，也不回到 pending。
 */
class OutboxProcessor(
    private val store: OutboxOperationStore,
    private val executor: OutboxOperationExecutor,
    private val timeSource: TimeSource,
    private val policy: OutboxRetryPolicy = OutboxRetryPolicy.DEFAULT,
    private val cancellation: OutboxCancellationGate = OutboxCancellationGate.NeverCancelled,
    private val staleRunningAfter: Duration = STALE_RUNNING_TIMEOUT,
) {

    suspend fun runOnce(limit: Int = DEFAULT_BATCH): OutboxRunSummary {
        val now = timeSource.now()
        var summary = OutboxRunSummary()

        for (operation in store.executable(now, limit)) {
            summary = summary.copy(claimed = summary.claimed + 1)

            if (!store.claim(operation.id, now)) {
                // 别的 worker 抢到了它：跳过，而不是执行两次。
                summary = summary.copy(skipped = summary.skipped + 1)
                continue
            }
            val claimed = store.find(operation.id) ?: operation

            if (cancellation.isCancelled(claimed)) {
                store.markCancelled(claimed.id, CANCELLED_MESSAGE, now)
                summary = summary.copy(cancelled = summary.cancelled + 1)
                continue
            }

            if (!OutboxOperationKinds.isSupported(claimed.op)) {
                // 未实现 / 不认识的操作：一次性终止并写明原因，绝不留在 pending 里循环。
                store.markDeadLetter(claimed.id, OutboxOperationKinds.describeUnsupported(claimed.op), now)
                summary = summary.copy(deadLettered = summary.deadLettered + 1)
                continue
            }

            val outcome = try {
                executor.execute(claimed)
            } catch (e: CancellationException) {
                // 被系统叫停时不能替这条操作下结论：它可能已经执行了一半。
                // 保持 running，交给下面的陈旧回收标记为 unknown。
                throw e
            } catch (e: Throwable) {
                OutboxExecution.Unknown(EXCEPTION_PREFIX + (e.message ?: e::class.java.simpleName))
            }

            when (outcome) {
                is OutboxExecution.Succeeded -> {
                    store.markSucceeded(claimed.id, now)
                    summary = summary.copy(succeeded = summary.succeeded + 1)
                }

                is OutboxExecution.Failed -> {
                    store.markFailed(claimed.id, outcome.message, now)
                    summary = summary.copy(failed = summary.failed + 1)
                }

                is OutboxExecution.Unknown -> {
                    // 交对账：状态 unknown 且 next_retry_at 为空，可执行查询捞不到它。
                    store.markUnknown(claimed.id, outcome.message, now)
                    summary = summary.copy(unknown = summary.unknown + 1)
                }

                is OutboxExecution.Retryable -> {
                    if (policy.hasAttemptsLeft(claimed.attempt)) {
                        val retryAt = outcome.retryAt ?: policy.nextRetryAt(claimed.attempt, now)
                        store.reschedule(claimed, outcome.message, retryAt, now)
                        summary = summary.copy(retried = summary.retried + 1)
                    } else {
                        // 到了上限就终止。没有这一步，一条永远失败的操作会永久占据队列。
                        store.markFailed(
                            claimed.id,
                            OVER_LIMIT_PREFIX + policy.maxAttempts + "，停止重试：" + outcome.message,
                            now,
                        )
                        summary = summary.copy(failed = summary.failed + 1)
                    }
                }
            }
        }

        // 回收上次进程被杀留下的 running 记录：可执行查询只认 pending，
        // 不处理它们，这些操作会永远消失。不知道执行没执行，所以只能标 unknown 交对账。
        summary = summary.copy(unknown = summary.unknown + recoverStaleRunning(now))
        return summary
    }

    private suspend fun recoverStaleRunning(now: Instant): Int {
        var recovered = 0
        for (record in store.listRunning()) {
            val age = Duration.between(record.updatedAt, now)
            if (age < staleRunningAfter) continue
            store.markUnknown(record.id, STALE_MESSAGE, now)
            recovered++
        }
        return recovered
    }

    private companion object {
        const val DEFAULT_BATCH = 20
        const val CANCELLED_MESSAGE = "操作已被取消，不再执行。"
        const val STALE_MESSAGE = "上次执行被中断且结果未知，已停止自动重写，等待与外部对账。"
        const val EXCEPTION_PREFIX = "执行过程中抛出异常，无法确认结果："
        const val OVER_LIMIT_PREFIX = "重试次数已达上限 "
    }
}

/** 与 CoroutineWorker 的 10 分钟上限留出余量：更久的一定不是本次在跑的。 */
private val STALE_RUNNING_TIMEOUT: Duration = Duration.ofMinutes(15)
