package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.TaskStatus
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/**
 * task 的读写。
 *
 * 所有列表查询都带 deleted_at IS NULL —— 任务用软删除，因为外部对账期间
 * 「本地删了、外部还在」需要一个可解释的中间态。
 */
@Dao
interface TaskDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: TaskRecord)

    @Update
    suspend fun update(record: TaskRecord)

    @Query("SELECT * FROM task WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): TaskRecord?

    @Query("SELECT * FROM task WHERE id = :id")
    suspend fun findByIdIncludingDeleted(id: String): TaskRecord?

    @Query("SELECT * FROM task WHERE status = 'open' AND deleted_at IS NULL ORDER BY (due_utc IS NULL), due_utc ASC, created_at ASC")
    fun observeOpen(): Flow<List<TaskRecord>>

    @Query("SELECT * FROM task WHERE status = :status AND deleted_at IS NULL ORDER BY created_at DESC")
    suspend fun listByStatus(status: TaskStatus): List<TaskRecord>

    /** 「今天」页与提醒作业都靠这个：按截止时刻的闭开区间取任务。 */
    @Query("SELECT * FROM task WHERE deleted_at IS NULL AND due_utc IS NOT NULL AND due_utc >= :from AND due_utc < :to ORDER BY due_utc ASC")
    suspend fun listDueBetween(from: Instant, to: Instant): List<TaskRecord>

    /** 尚未到期但已经有提醒时刻的任务：提醒作业按 nextRetryAt 之类的方式重排时要用。 */
    @Query("SELECT * FROM task WHERE deleted_at IS NULL AND remind_utc IS NOT NULL AND status = 'open' AND remind_utc >= :from ORDER BY remind_utc ASC")
    suspend fun listUpcomingReminders(from: Instant): List<TaskRecord>

    @Query("SELECT * FROM task WHERE external_write_state = :state AND deleted_at IS NULL ORDER BY updated_at DESC")
    suspend fun listByExternalWriteState(state: ExternalWriteState): List<TaskRecord>

    /** 同步异常分区：既不是「没请求过」也不是「写好了」的任务。 */
    @Query("SELECT * FROM task WHERE deleted_at IS NULL AND external_write_state NOT IN ('not_requested', 'written') ORDER BY updated_at DESC")
    fun observeExternalIssues(): Flow<List<TaskRecord>>

    @Query("SELECT * FROM task WHERE deleted_at IS NULL AND external_write_state = 'pending' ORDER BY created_at ASC")
    suspend fun listPendingExternalWrites(): List<TaskRecord>

    @Query("SELECT * FROM task WHERE origin_capture_id = :captureId AND deleted_at IS NULL")
    suspend fun listByOriginCapture(captureId: String): List<TaskRecord>

    @Query("UPDATE task SET status = :status, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateStatus(id: String, status: TaskStatus, updatedAt: Instant)

    @Query("UPDATE task SET external_write_state = :state, last_receipt_at = :receiptAt, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateExternalWriteState(id: String, state: ExternalWriteState, receiptAt: Instant?, updatedAt: Instant)

    @Query("UPDATE task SET deleted_at = :deletedAt, updated_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)

    @Query("SELECT COUNT(*) FROM task WHERE status = 'open' AND deleted_at IS NULL")
    fun observeOpenCount(): Flow<Int>
}
