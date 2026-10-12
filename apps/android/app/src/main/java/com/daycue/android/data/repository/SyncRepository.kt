package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueJson
import com.daycue.android.core.DayCueTime
import com.daycue.android.core.IdempotencyKey
import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.dao.SyncCursorDao
import com.daycue.android.data.local.dao.SyncSnapshotDao
import com.daycue.android.data.local.dao.SyncTombstoneDao
import com.daycue.android.data.local.dao.TaskDao
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.local.entity.SyncCursorRecord
import com.daycue.android.data.local.entity.SyncSnapshotRecord
import com.daycue.android.data.local.entity.SyncTombstoneRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.domain.sync.ExternalProjection
import com.daycue.android.domain.sync.FieldOutcome
import com.daycue.android.domain.sync.ReconciliationResult
import com.daycue.android.domain.sync.SyncField
import com.daycue.android.domain.sync.SyncReconciler
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.time.Instant

/** outbox 记录的构造。幂等键必须在这里确定性地算出来，绝不用随机 id。 */
object OutboxOperations {

    fun createReminder(taskId: String, listId: String, now: Instant): OutboxOperationRecord {
        val key = IdempotencyKey.createReminder(taskId, listId)
        return OutboxOperationRecord(
            id = DayCueId.new(),
            entityType = "task",
            entityId = taskId,
            op = "create_reminder",
            idempotencyKey = key,
            payloadJson = DayCueJson.encodeToString(
                MapSerializer(String.serializer(), String.serializer()),
                mapOf("task_id" to taskId, "list_id" to listId),
            ),
            createdAt = now,
            updatedAt = now,
        )
    }

    fun deleteReminder(taskId: String, externalId: String, now: Instant): OutboxOperationRecord =
        OutboxOperationRecord(
            id = DayCueId.new(),
            entityType = "task",
            entityId = taskId,
            op = "delete_reminder",
            idempotencyKey = IdempotencyKey.deleteReminder(taskId, externalId),
            payloadJson = DayCueJson.encodeToString(
                MapSerializer(String.serializer(), String.serializer()),
                mapOf("task_id" to taskId, "external_id" to externalId),
            ),
            createdAt = now,
            updatedAt = now,
        )

    fun extractCapture(captureId: String, contentFingerprint: String, now: Instant): OutboxOperationRecord =
        OutboxOperationRecord(
            id = DayCueId.new(),
            entityType = "capture",
            entityId = captureId,
            op = "extract_capture",
            idempotencyKey = IdempotencyKey.extractCapture(captureId, contentFingerprint),
            payloadJson = null,
            createdAt = now,
            updatedAt = now,
        )
}

/**
 * 同步仓储：outbox、游标、墓碑、对账快照。
 *
 * 对账只覆盖 App 真正建模了的字段（标题/备注/完成状态/截止/提醒）。
 * 清单与地点这两列有意不参与比较——没有外部绑定表，采用它们的值也无处可存，
 * 与其静默丢掉，不如一开始就不比较（这一点在 README 的「已知限制」里也写了）。
 */
class SyncRepository(
    private val outboxDao: OutboxDao,
    private val cursorDao: SyncCursorDao,
    private val tombstoneDao: SyncTombstoneDao,
    private val snapshotDao: SyncSnapshotDao,
    private val taskDao: TaskDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    private val comparableFields = listOf(
        SyncField.TITLE,
        SyncField.DETAIL,
        SyncField.STATUS,
        SyncField.DUE,
        SyncField.REMIND,
    )

    // ---- outbox ----

    /** 返回 false 表示幂等键已存在（应用层重复排队），这不是错误。 */
    suspend fun enqueue(record: OutboxOperationRecord): Boolean = outboxDao.enqueue(record) != -1L

    suspend fun executable(now: Instant = timeSource.now(), limit: Int = 20): List<OutboxOperationRecord> =
        outboxDao.listExecutable(now, limit)

    suspend fun findOperation(id: String) = outboxDao.findById(id)

    /** 抢占：只有真的把它从 pending 推到 running 的那次调用才返回 true，避免两个 worker 同时执行。 */
    suspend fun claim(id: String): Boolean = outboxDao.markRunning(id, timeSource.now()) == 1

    suspend fun markSucceeded(id: String) = outboxDao.markSucceeded(id, timeSource.now())

    suspend fun markFailed(id: String, error: String?, retryAt: Instant?) =
        outboxDao.markFailed(id, OutboxState.FAILED, error, retryAt, timeSource.now())

    /**
     * 结果未知（进程崩溃、网络半途失败）：必须走 unknown 而不是 failed 或 pending，
     * 因为「可能已经写成功」和「确定没成功」是两件事，前者只能靠对账收场。
     */
    suspend fun markUnknown(id: String, error: String?) =
        outboxDao.markFailed(id, OutboxState.UNKNOWN, error, null, timeSource.now())

    fun observePendingCount(): Flow<Int> = outboxDao.observePendingCount()

    // ---- 游标与墓碑 ----

    suspend fun cursor(scope: String): String? = cursorDao.find(scope)?.cursor

    suspend fun updateCursor(scope: String, cursor: String) =
        cursorDao.upsert(SyncCursorRecord(scope, cursor, timeSource.now()))

    suspend fun recordTombstone(entityType: String, entityId: String, remoteVersion: Int? = null) =
        tombstoneDao.record(SyncTombstoneRecord(entityType, entityId, timeSource.now(), remoteVersion))

    suspend fun isTombstoned(entityType: String, entityId: String): Boolean =
        tombstoneDao.find(entityType, entityId) != null

    suspend fun tombstonesSince(since: Instant): List<SyncTombstoneRecord> = tombstoneDao.listSince(since)

    suspend fun pruneTombstones(before: Instant) = tombstoneDao.deleteOlderThan(before)

    // ---- 三方对账 ----

    suspend fun snapshotOf(entityType: String, entityId: String, provider: String): Map<SyncField, String?> {
        val record = snapshotDao.find(entityType, entityId, provider) ?: return emptyMap()
        return decodeFields(record.payloadJson)
    }

    suspend fun saveSnapshot(entityType: String, entityId: String, provider: String, fields: Map<SyncField, String?>) {
        val payload = encodeFields(fields)
        snapshotDao.save(
            SyncSnapshotRecord(
                entityType = entityType,
                entityId = entityId,
                provider = provider,
                payloadJson = payload,
                contentHash = com.daycue.android.core.Sha256.hex(payload),
                capturedAt = timeSource.now(),
            ),
        )
    }

    /**
     * 对一条任务做三方比较并把「外部改了、本地没改」的字段采纳回来。
     *
     * 同字段双方都改且不一致时**不写入**，只把冲突返回给界面——
     * 这是设计文档 9.2 的硬要求：不用单一最后写入覆盖用户的手工修改。
     */
    suspend fun reconcileTask(
        taskId: String,
        external: ExternalProjection,
        provider: String = PROVIDER_EXTERNAL,
    ): ReconciliationResult {
        val task = taskDao.findById(taskId)
            ?: return ReconciliationResult(emptyMap(), false, false, "任务不存在")
        val snapshot = snapshotOf("task", taskId, provider)
        val local = task.toFieldMap()
        val filtered = ExternalProjection(
            available = external.available,
            exists = external.exists,
            fields = external.fields.filterKeys { it in comparableFields },
        )
        val result = SyncReconciler.reconcile(snapshot, local, filtered)

        val merged = SyncReconciler.applyToLocal(local, result)
        if (merged != local) {
            taskDao.update(applyFields(task, merged, timeSource.now()))
        }
        if (filtered.available && filtered.exists) {
            // 快照必须用「对账之后」的值重拍，否则下一轮会把同一处变化再报一次冲突。
            saveSnapshot("task", taskId, provider, merged)
        }
        if (result.externalDeleted) {
            taskDao.updateExternalWriteState(
                taskId,
                ExternalWriteState.NEEDS_RECONCILIATION,
                null,
                timeSource.now(),
            )
        }
        return result
    }

    private fun TaskRecord.toFieldMap(): Map<SyncField, String?> = mapOf(
        SyncField.TITLE to title,
        SyncField.DETAIL to detail,
        SyncField.STATUS to status.raw,
        // 日期型截止只存 due_local，绝对时刻型只存 due_utc；两者不会同时有值。
        SyncField.DUE to (dueUtc?.let { DayCueTime.utcString(it) } ?: dueLocal),
        SyncField.REMIND to remindUtc?.let { DayCueTime.utcString(it) },
    )

    private fun applyFields(task: TaskRecord, fields: Map<SyncField, String?>, now: Instant): TaskRecord {
        var updated = task
        fields[SyncField.TITLE]?.let { if (it.isNotBlank()) updated = updated.copy(title = it) }
        if (fields.containsKey(SyncField.DETAIL)) updated = updated.copy(detail = fields[SyncField.DETAIL])
        fields[SyncField.STATUS]?.let { raw ->
            runCatching { TaskStatus.fromRaw(raw) }.getOrNull()?.let { updated = updated.copy(status = it) }
        }
        fields[SyncField.REMIND]?.let { raw ->
            DayCueTime.parseInstantOrNull(raw)?.let { instant ->
                // 时区列存的是字符串，理论上可能被写坏；解析失败时宁可只留 UTC 值，
                // 也不要让一次对账因为一个坏时区把整条更新抛异常掉。
                val zone = runCatching { java.time.ZoneId.of(updated.timezone) }.getOrNull()
                updated = updated.copy(
                    remindUtc = instant,
                    remindLocal = zone?.let { DayCueTime.localDateTimeString(instant, it) },
                )
            }
        } ?: run {
            if (fields.containsKey(SyncField.REMIND)) updated = updated.copy(remindUtc = null, remindLocal = null)
        }
        return updated.copy(updatedAt = now)
    }

    private fun encodeFields(fields: Map<SyncField, String?>): String =
        DayCueJson.encodeToString(
            MapSerializer(String.serializer(), String.serializer()),
            fields.entries.associate { it.key.key to (it.value ?: "") },
        )

    private fun decodeFields(payload: String): Map<SyncField, String?> {
        val raw = runCatching {
            DayCueJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), payload)
        }.getOrDefault(emptyMap())
        return SyncField.entries.associateWith { field ->
            raw[field.key]?.takeIf { it.isNotEmpty() }
        }
    }

    companion object {
        const val PROVIDER_EXTERNAL = "external"
    }
}
