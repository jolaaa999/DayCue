package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.CourseInstanceRecord
import com.daycue.android.data.local.entity.CourseRecord
import com.daycue.android.data.local.entity.CourseScheduleRuleRecord
import com.daycue.android.data.local.entity.FollowUpRecord
import com.daycue.android.data.local.entity.FollowUpReplyRecord
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.FollowUpState
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/** course：课程主数据。软删除，便于一学期结束后归档而不是丢失历史。 */
@Dao
interface CourseDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: CourseRecord)

    @Update
    suspend fun update(record: CourseRecord)

    @Query("SELECT * FROM course WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): CourseRecord?

    @Query("SELECT * FROM course WHERE deleted_at IS NULL ORDER BY name ASC")
    fun observeActive(): Flow<List<CourseRecord>>

    @Query("SELECT * FROM course WHERE deleted_at IS NULL ORDER BY name ASC")
    suspend fun listActive(): List<CourseRecord>

    @Query("SELECT * FROM course WHERE deleted_at IS NULL AND term = :term ORDER BY name ASC")
    suspend fun listByTerm(term: String): List<CourseRecord>

    /** ICS 导入时按名字查重：同一门课重复导入不应该变成两门课。 */
    @Query("SELECT * FROM course WHERE deleted_at IS NULL AND name = :name LIMIT 1")
    suspend fun findByName(name: String): CourseRecord?

    @Query("UPDATE course SET follow_up_enabled = :enabled, follow_up_delay_minutes = :delayMinutes, follow_up_mode = :mode, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateFollowUpSettings(id: String, enabled: Boolean, delayMinutes: Int, mode: String, updatedAt: Instant)

    @Query("UPDATE course SET excluded_dates = :excludedDates, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateExcludedDates(id: String, excludedDates: String, updatedAt: Instant)

    @Query("UPDATE course SET deleted_at = :deletedAt, updated_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)
}

/** course_schedule_rule：每周重复规则。整门课重排时先删后插，不逐条 diff——规则条数很少。 */
@Dao
interface CourseScheduleRuleDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(records: List<CourseScheduleRuleRecord>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(record: CourseScheduleRuleRecord)

    @Query("SELECT * FROM course_schedule_rule WHERE id = :id")
    suspend fun findById(id: String): CourseScheduleRuleRecord?

    @Query("SELECT * FROM course_schedule_rule WHERE course_id = :courseId ORDER BY weekday ASC, section_start ASC")
    suspend fun listByCourse(courseId: String): List<CourseScheduleRuleRecord>

    @Query("SELECT * FROM course_schedule_rule ORDER BY weekday ASC, section_start ASC")
    suspend fun listAll(): List<CourseScheduleRuleRecord>

    @Query("SELECT * FROM course_schedule_rule WHERE weekday = :weekday ORDER BY section_start ASC")
    suspend fun listByWeekday(weekday: Int): List<CourseScheduleRuleRecord>

    @Query("DELETE FROM course_schedule_rule WHERE course_id = :courseId")
    suspend fun deleteByCourse(courseId: String)
}

/**
 * course_instance：每次课一行。
 *
 * 插入用 IGNORE 而不是 REPLACE：实例 id 由 (规则, 开始时刻) 确定性生成，
 * 重复展开时 IGNORE 会保留用户已经改过的 status（停课/调课），
 * 而 REPLACE 会把「用户标了停课」悄悄覆盖回 scheduled。
 */
@Dao
interface CourseInstanceDao {

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertIgnoringExisting(record: CourseInstanceRecord): Long

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertAllIgnoringExisting(records: List<CourseInstanceRecord>): List<Long>

    @Update
    suspend fun update(record: CourseInstanceRecord)

    @Query("SELECT * FROM course_instance WHERE id = :id")
    suspend fun findById(id: String): CourseInstanceRecord?

    /** 周视图与「今天」页：按绝对时刻的闭开区间取。 */
    @Query("SELECT * FROM course_instance WHERE starts_at_utc >= :from AND starts_at_utc < :to ORDER BY starts_at_utc ASC")
    fun observeBetween(from: Instant, to: Instant): Flow<List<CourseInstanceRecord>>

    @Query("SELECT * FROM course_instance WHERE starts_at_utc >= :from AND starts_at_utc < :to ORDER BY starts_at_utc ASC")
    suspend fun listBetween(from: Instant, to: Instant): List<CourseInstanceRecord>

    @Query("SELECT * FROM course_instance WHERE course_id = :courseId ORDER BY starts_at_utc ASC")
    suspend fun listByCourse(courseId: String): List<CourseInstanceRecord>

    @Query("SELECT * FROM course_instance WHERE rule_id = :ruleId AND starts_at_utc = :startsAtUtc")
    suspend fun findByRuleAndStart(ruleId: String, startsAtUtc: Instant): CourseInstanceRecord?

    @Query("UPDATE course_instance SET status = :status, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateStatus(id: String, status: CourseInstanceStatus, updatedAt: Instant)

    @Query("UPDATE course_instance SET starts_at_utc = :startsAtUtc, ends_at_utc = :endsAtUtc, status = 'rescheduled', note = :note, updated_at = :updatedAt WHERE id = :id")
    suspend fun reschedule(id: String, startsAtUtc: Instant, endsAtUtc: Instant, note: String?, updatedAt: Instant)

    /** 重新展开某条规则时清理旧实例。只删还没被用户改过的 scheduled 行——停课/调课的记录必须留着。 */
    @Query("DELETE FROM course_instance WHERE rule_id = :ruleId AND status = 'scheduled' AND starts_at_utc >= :from AND starts_at_utc < :to")
    suspend fun deleteGeneratedScheduled(ruleId: String, from: Instant, to: Instant)
}

/**
 * follow_up：一个课程实例最多一条（唯一索引兜底）。
 * 查询集中在「谁该被拾取」与「今天已经追问了几次」两件事上。
 */
@Dao
interface FollowUpDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: FollowUpRecord)

    @Update
    suspend fun update(record: FollowUpRecord)

    @Query("SELECT * FROM follow_up WHERE id = :id")
    suspend fun findById(id: String): FollowUpRecord?

    @Query("SELECT * FROM follow_up WHERE course_instance_id = :instanceId")
    suspend fun findByInstance(instanceId: String): FollowUpRecord?

    /**
     * 可拾取：到点的 scheduled，或到了 snooze 时刻的 snoozed。
     * 终态在 SQL 里就排除了，避免调度器漏判断导致「跳过后又被追问」。
     */
    @Query("SELECT * FROM follow_up WHERE (state = 'scheduled' AND scheduled_at_utc <= :now) OR (state = 'snoozed' AND snooze_until_utc IS NOT NULL AND snooze_until_utc <= :now) ORDER BY scheduled_at_utc ASC")
    suspend fun listDueForPickup(now: Instant): List<FollowUpRecord>

    @Query("SELECT * FROM follow_up WHERE state = :state ORDER BY scheduled_at_utc DESC")
    suspend fun listByState(state: FollowUpState): List<FollowUpRecord>

    @Query("SELECT * FROM follow_up WHERE state IN ('scheduled', 'delivered', 'snoozed') ORDER BY scheduled_at_utc ASC")
    fun observeOutstanding(): Flow<List<FollowUpRecord>>

    @Query("SELECT * FROM follow_up WHERE course_id = :courseId AND state IN ('scheduled', 'delivered', 'snoozed') ORDER BY scheduled_at_utc ASC")
    suspend fun listOutstandingByCourse(courseId: String): List<FollowUpRecord>

    @Query("SELECT COUNT(*) FROM follow_up WHERE course_id = :courseId AND delivered_at_utc >= :from AND delivered_at_utc < :to")
    suspend fun countDeliveredBetween(courseId: String, from: Instant, to: Instant): Int

    @Query("SELECT * FROM follow_up WHERE state = 'answered' ORDER BY delivered_at_utc DESC LIMIT :limit")
    suspend fun listAnswered(limit: Int = 50): List<FollowUpRecord>

    @Query("UPDATE follow_up SET state = :state, scheduled_at_utc = :scheduledAt, snooze_until_utc = :snoozeUntil, delivered_at_utc = :deliveredAt, attempt = :attempt, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateStateAndSchedule(
        id: String,
        state: FollowUpState,
        scheduledAt: Instant,
        snoozeUntil: Instant?,
        deliveredAt: Instant?,
        attempt: Int,
        updatedAt: Instant,
    )

    @Query("UPDATE follow_up SET state = :state, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateState(id: String, state: FollowUpState, updatedAt: Instant)
}

/** follow_up_reply：回复归档。note_id / task_id 是「这条回复后来变成了什么」的追溯线索。 */
@Dao
interface FollowUpReplyDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: FollowUpReplyRecord)

    @Query("SELECT * FROM follow_up_reply WHERE follow_up_id = :followUpId ORDER BY created_at ASC")
    suspend fun listByFollowUp(followUpId: String): List<FollowUpReplyRecord>

    @Query("SELECT * FROM follow_up_reply WHERE course_id = :courseId ORDER BY created_at DESC LIMIT :limit")
    suspend fun listByCourse(courseId: String, limit: Int = 50): List<FollowUpReplyRecord>

    @Query("SELECT * FROM follow_up_reply ORDER BY created_at DESC LIMIT :limit")
    fun observeRecent(limit: Int = 100): Flow<List<FollowUpReplyRecord>>
}
