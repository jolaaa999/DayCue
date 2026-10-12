package com.daycue.android.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.daycue.android.data.local.entity.CaptureItemRecord
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import kotlinx.coroutines.flow.Flow
import java.time.Instant

/**
 * capture_item 的读写。
 *
 * 「按状态」「按时间范围」这两类查询是界面真实需要的：
 * 记录页顶部要显示「待处理记录」，今天页要看某一天录了什么，离线期间还要能找回没解析完的。
 */
@Dao
interface CaptureDao {

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(record: CaptureItemRecord)

    @Update
    suspend fun update(record: CaptureItemRecord)

    @Query("SELECT * FROM capture_item WHERE id = :id")
    suspend fun findById(id: String): CaptureItemRecord?

    @Query("SELECT * FROM capture_item ORDER BY recorded_at DESC LIMIT :limit")
    fun observeRecent(limit: Int = 50): Flow<List<CaptureItemRecord>>

    @Query("SELECT * FROM capture_item WHERE status = :status ORDER BY recorded_at DESC")
    suspend fun listByStatus(status: CaptureStatus): List<CaptureItemRecord>

    /** 按时间范围取：闭区间，参数是绝对时刻。 */
    @Query("SELECT * FROM capture_item WHERE recorded_at >= :from AND recorded_at < :to ORDER BY recorded_at DESC")
    suspend fun listRecordedBetween(from: Instant, to: Instant): List<CaptureItemRecord>

    @Query("SELECT * FROM capture_item WHERE kind = :kind ORDER BY recorded_at DESC LIMIT :limit")
    suspend fun listByKind(kind: CaptureKind, limit: Int): List<CaptureItemRecord>

    @Query("UPDATE capture_item SET status = :status, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateStatus(id: String, status: CaptureStatus, updatedAt: Instant)

    /**
     * 用户改过之后置 user_edited=1，并把文本写进 raw_text。
     * 晚到的转写/OCR 结果只能写 transcript / ocr_text，永远不能覆盖 raw_text。
     */
    @Query("UPDATE capture_item SET user_edited = 1, raw_text = :text, updated_at = :updatedAt WHERE id = :id")
    suspend fun markUserEdited(id: String, text: String, updatedAt: Instant)

    @Query("UPDATE capture_item SET transcript = :transcript, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateTranscript(id: String, transcript: String, updatedAt: Instant)

    @Query("UPDATE capture_item SET ocr_text = :text, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateOcrText(id: String, text: String, updatedAt: Instant)

    @Query("DELETE FROM capture_item WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("SELECT COUNT(*) FROM capture_item WHERE status IN ('local', 'failed', 'extracting')")
    fun observePendingCount(): Flow<Int>
}
