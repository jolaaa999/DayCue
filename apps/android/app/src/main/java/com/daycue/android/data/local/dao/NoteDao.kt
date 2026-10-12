package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.NoteRecord
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/** note 的读写。笔记默认不提醒，所以这里只有检索与来源追溯相关的查询。 */
@Dao
interface NoteDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: NoteRecord)

    @Update
    suspend fun update(record: NoteRecord)

    @Query("SELECT * FROM note WHERE id = :id AND deleted_at IS NULL")
    suspend fun findById(id: String): NoteRecord?

    @Query("SELECT * FROM note WHERE deleted_at IS NULL ORDER BY COALESCE(occurred_at, created_at) DESC LIMIT :limit")
    fun observeRecent(limit: Int = 100): Flow<List<NoteRecord>>

    @Query("SELECT * FROM note WHERE deleted_at IS NULL AND course_hint = :courseHint ORDER BY created_at DESC")
    suspend fun listByCourse(courseHint: String): List<NoteRecord>

    /** 关键词检索：标题与正文都算。用 LIKE 而不是全文索引，是因为笔记量级在单人使用下很小。 */
    @Query("SELECT * FROM note WHERE deleted_at IS NULL AND (title LIKE :pattern OR body LIKE :pattern) ORDER BY created_at DESC LIMIT :limit")
    suspend fun search(pattern: String, limit: Int = 100): List<NoteRecord>

    @Query("SELECT * FROM note WHERE deleted_at IS NULL AND created_at >= :from AND created_at < :to ORDER BY created_at DESC")
    suspend fun listCreatedBetween(from: Instant, to: Instant): List<NoteRecord>

    @Query("SELECT * FROM note WHERE origin_capture_id = :captureId AND deleted_at IS NULL")
    suspend fun listByOriginCapture(captureId: String): List<NoteRecord>

    /** 用户编辑笔记后置位：与 capture 同规则，晚到的解析结果不能覆盖它。 */
    @Query("UPDATE note SET user_edited = 1, title = :title, body = :body, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateUserEdited(id: String, title: String, body: String, updatedAt: Instant)

    @Query("UPDATE note SET deleted_at = :deletedAt, updated_at = :deletedAt WHERE id = :id")
    suspend fun softDelete(id: String, deletedAt: Instant)

    @Query("SELECT COUNT(*) FROM note WHERE deleted_at IS NULL")
    fun observeCount(): Flow<Int>
}
