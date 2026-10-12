package com.daycue.android.data.repository

import com.daycue.android.core.DayCueId
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.dao.NoteDao
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.domain.model.NoteOriginKind
import kotlinx.coroutines.flow.Flow
import java.time.Instant
import java.time.ZoneId

/**
 * 笔记（note）的仓储。
 *
 * 笔记默认不提醒——这是产品承诺（「课堂知识记录默认成为笔记，只有行动意图才生成任务」），
 * 所以这里没有任何提醒相关的字段与逻辑。
 */
class NoteRepository(
    private val dao: NoteDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    suspend fun create(
        title: String,
        body: String,
        originKind: NoteOriginKind = NoteOriginKind.MANUAL,
        courseHint: String? = null,
        tags: List<String> = emptyList(),
        originCaptureId: String? = null,
        originItemId: String? = null,
        occurredAt: Instant? = null,
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val now = timeSource.now()
        val id = DayCueId.new()
        dao.insert(
            NoteRecord(
                id = id,
                title = title.ifBlank { "未命名笔记" }.trim(),
                body = body,
                tags = tags,
                courseHint = courseHint,
                originCaptureId = originCaptureId,
                originItemId = originItemId,
                originKind = originKind,
                occurredAt = occurredAt,
                createdAt = now,
                updatedAt = now,
            ),
        )
        // occurredAt 允许为空（例如解析结果里没给发生时间）；列表排序由 NoteDao 的
        // COALESCE(occurred_at, created_at) 兜底，不在写库时伪造一个发生时间。
        return id
    }

    suspend fun saveUserEdit(noteId: String, title: String, body: String) {
        dao.updateUserEdited(noteId, title, body, timeSource.now())
    }

    suspend fun softDelete(noteId: String) = dao.softDelete(noteId, timeSource.now())

    suspend fun find(noteId: String): NoteRecord? = dao.findById(noteId)

    fun observeRecent(limit: Int = 100): Flow<List<NoteRecord>> = dao.observeRecent(limit)

    fun observeCount(): Flow<Int> = dao.observeCount()

    suspend fun search(keyword: String): List<NoteRecord> {
        val trimmed = keyword.trim()
        if (trimmed.isEmpty()) return emptyList()
        return dao.search("%" + trimmed + "%")
    }

    suspend fun listByCourse(courseHint: String): List<NoteRecord> = dao.listByCourse(courseHint)

    suspend fun listByOriginCapture(captureId: String): List<NoteRecord> = dao.listByOriginCapture(captureId)

    suspend fun listOnLocalDate(date: java.time.LocalDate, zone: ZoneId): List<NoteRecord> =
        dao.listCreatedBetween(
            from = DayCueTime.startOfLocalDay(date, zone),
            to = DayCueTime.startOfNextLocalDay(date, zone),
        )
}
