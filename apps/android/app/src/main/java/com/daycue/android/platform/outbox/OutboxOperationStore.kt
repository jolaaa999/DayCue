package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import java.time.Instant

/**
 * 处理器需要的 outbox 持久化动作。
 *
 * 抽成接口而不是直接用 Room DAO，是为了让状态机能在纯 JVM 单测里跑：
 * DAO 的实现由 Room 生成，单测里既起不了数据库，也不该去验证 SQL。
 * 生产实现是 DaoOutboxOperationStore，它只做字段映射，不含任何决策。
 */
interface OutboxOperationStore {

    suspend fun executable(now: Instant, limit: Int): List<OutboxOperationRecord>

    /** 抢占：只有真的把状态从 pending 推到 running 的那次调用才返回 true。 */
    suspend fun claim(id: String, now: Instant): Boolean

    suspend fun find(id: String): OutboxOperationRecord?

    suspend fun markSucceeded(id: String, now: Instant)

    suspend fun markFailed(id: String, reason: String?, now: Instant)

    suspend fun markUnknown(id: String, reason: String?, now: Instant)

    suspend fun markDeadLetter(id: String, reason: String, now: Instant)

    suspend fun markCancelled(id: String, reason: String, now: Instant)

    /**
     * 重排回 pending 等待退避结束。
     *
     * 传整条记录而不是只传 id：DAO 的 markFailed 会在 SQL 里做 attempt = attempt + 1，
     * 而抢占时已经加过一次，再走一遍会重复计数（既有 worker 也是因此改用 @Update）。
     */
    suspend fun reschedule(record: OutboxOperationRecord, reason: String?, retryAt: Instant, now: Instant)

    suspend fun listRunning(): List<OutboxOperationRecord>
}
