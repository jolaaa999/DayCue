package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.dao.CaptureDao
import com.daycue.android.data.local.entity.CaptureItemRecord
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.ZoneId

/**
 * 记录（capture_item）的仓储。
 *
 * 核心不变式：**先落库，再谈网络**。任何一次提交都必须先产生一条 local 状态的记录，
 * 后面的转写/解析失败只能改状态，不能把这条记录删掉或吞掉。
 */
class CaptureRepository(
    private val dao: CaptureDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    suspend fun saveText(text: String, zone: ZoneId): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        dao.insert(
            CaptureItemRecord(
                id = id,
                kind = CaptureKind.TEXT,
                rawText = text,
                recordedAt = now,
                recordedTimezone = zone.id,
                status = CaptureStatus.LOCAL,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    suspend fun saveAudio(mediaPath: String, zone: ZoneId, durationSeconds: Long? = null): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        dao.insert(
            CaptureItemRecord(
                id = id,
                kind = CaptureKind.AUDIO,
                mediaPath = mediaPath,
                rawText = durationSeconds?.let { "录音 " + it + " 秒" },
                recordedAt = now,
                recordedTimezone = zone.id,
                status = CaptureStatus.LOCAL,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    suspend fun saveImage(mediaPath: String, ocrText: String?, zone: ZoneId): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        dao.insert(
            CaptureItemRecord(
                id = id,
                kind = CaptureKind.IMAGE,
                mediaPath = mediaPath,
                ocrText = ocrText,
                recordedAt = now,
                recordedTimezone = zone.id,
                status = CaptureStatus.LOCAL,
                createdAt = now,
                updatedAt = now,
            ),
        )
        return id
    }

    /**
     * 用户改过文本：置 user_edited 并把内容写进 raw_text。
     * 晚到的转写结果只能写 transcript，不允许覆盖这里——这是「用户修订优先」的落点。
     */
    suspend fun applyUserEdit(captureId: String, text: String) {
        dao.markUserEdited(captureId, text, timeSource.now())
    }

    /**
     * 写入机器转写结果。
     * 永远只写 transcript：展示文本的优先级由 displayText() 决定（用户改过的 raw_text 优先），
     * 所以「用户已改过」这件事不需要在这里分叉，晚到的结果也就永远覆盖不了用户。
     */
    suspend fun attachTranscript(captureId: String, transcript: String) {
        dao.updateTranscript(captureId, transcript, timeSource.now())
    }

    suspend fun attachOcrText(captureId: String, text: String) {
        dao.updateOcrText(captureId, text, timeSource.now())
    }

    suspend fun markStatus(captureId: String, status: CaptureStatus) {
        dao.updateStatus(captureId, status, timeSource.now())
    }

    suspend fun find(captureId: String): CaptureItemRecord? = dao.findById(captureId)

    /** 展示给界面的文本：用户改过的优先，其次转写，再次 OCR，最后原文。 */
    suspend fun displayText(captureId: String): String? = dao.findById(captureId)?.let { displayText(it) }

    fun displayText(record: CaptureItemRecord): String? =
        record.rawText?.takeIf { it.isNotBlank() }
            ?: record.transcript?.takeIf { it.isNotBlank() }
            ?: record.ocrText?.takeIf { it.isNotBlank() }

    fun observeRecent(limit: Int = 50): Flow<List<CaptureItemRecord>> = dao.observeRecent(limit)

    fun observePendingCount(): Flow<Int> = dao.observePendingCount()

    suspend fun listByStatus(status: CaptureStatus): List<CaptureItemRecord> = dao.listByStatus(status)

    /** 今天录了什么：按用户时区的闭开区间查，避免用 UTC 日界切错。 */
    suspend fun listOnLocalDate(date: java.time.LocalDate, zone: ZoneId): List<CaptureItemRecord> =
        dao.listRecordedBetween(
            from = DayCueTime.startOfLocalDay(date, zone),
            to = DayCueTime.startOfNextLocalDay(date, zone),
        )

    suspend fun retryable(): List<CaptureItemRecord> =
        dao.listByStatus(CaptureStatus.LOCAL) + dao.listByStatus(CaptureStatus.FAILED)

    suspend fun delete(captureId: String) = dao.deleteById(captureId)

    /** 供后台作业判断：这条记录是不是还值得发起解析。 */
    suspend fun shouldStartExtraction(captureId: String): Boolean {
        val record = dao.findById(captureId) ?: return false
        return record.status.isRetryable
    }

    suspend fun markExtracting(captureId: String, at: Instant = timeSource.now()) {
        dao.updateStatus(captureId, CaptureStatus.EXTRACTING, at)
    }
}
