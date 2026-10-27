package com.daycue.android.ui.note

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.NoteOriginKind
import java.io.File
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 图片 / 录音记录。
 *
 * 这些记录还停在 capture_item 里（没整理成笔记），列表里必须看得见：
 * 否则用户既无法确认存的是不是那张图，也没有地方删掉选错的那张。
 * 图片现在带本机 OCR 文字，录音在后端可用时带转写文字——两者都算这条记录的内容。
 */
data class MediaCaptureItem(
    val captureId: String,
    val kind: CaptureKind,
    val path: String?,
    val recordedAt: Instant,
    val status: CaptureStatus,
    /** 列表行的预览文字：用户改过的优先，其次转写、OCR，最后是「录音 N 秒」这类摘要。 */
    val text: String?,
    /**
     * 录音的转写全文。
     *
     * 单独一个字段而不是复用 text：音频的 raw_text 是「录音 8 秒」这种摘要，
     * 直接拿来当转写全文显示会把摘要当成转写结果。
     */
    val transcriptText: String? = null,
)

data class NoteListUiState(
    val keyword: String = "",
    /** 仓储给出的原始结果（最近列表或检索结果），筛选在界面层再套一层。 */
    val notes: List<NoteRecord> = emptyList(),
    /** 按来源筛选；null 表示「全部」。 */
    val filter: NoteOriginKind? = null,
    val searching: Boolean = false,
    val loaded: Boolean = false,
    val error: String? = null,
    /** 列表里「今天/昨天」的基准时刻。由 ViewModel 注入，界面不自己取系统时间。 */
    val now: Instant? = null,
    /** 本机的图片 / 录音记录，按时间倒序。 */
    val mediaCaptures: List<MediaCaptureItem> = emptyList(),
) {
    /**
     * 真正显示出来的记录。
     *
     * 为什么在界面层筛而不是回到仓储再查一次：笔记量级很小（最近 100 条），
     * 换筛选条件时不该再触发一次 LIKE 查询，也不该让「搜索 + 筛选」两个条件
     * 在两条不同的查询路径上各算一遍，那是最容易出现「搜索结果和筛选结果对不上」的地方。
     */
    val visibleNotes: List<NoteRecord>
        get() = if (filter == null) notes else notes.filter { it.originKind == filter }

    /** 有没有任何记录（不看筛选）：决定空白页是「一条都没有」还是「筛掉了」。 */
    val trulyEmpty: Boolean
        get() = loaded && notes.isEmpty() && keyword.isBlank()
}

/**
 * 记录列表。
 *
 * 关键词为空时跟着仓储的最近列表走（流式）；一旦输入关键词就切到仓储的检索结果。
 * 为什么两套路径不合并：检索是 LIKE 查询，把它挂成流式会让每次击键都重启一个查询，
 * 而笔记量级很小，一次性查完更省电。
 */
class NoteListViewModel(private val container: AppContainer) : ViewModel() {

    private val _state = MutableStateFlow(NoteListUiState(now = container.timeSource.now()))
    val state: StateFlow<NoteListUiState> = _state.asStateFlow()

    private var recent: List<NoteRecord> = emptyList()

    init {
        viewModelScope.launch {
            container.noteRepository.observeRecent(100).collect { records ->
                recent = records
                if (_state.value.keyword.isBlank()) {
                    _state.update { it.copy(notes = records, loaded = true) }
                }
            }
        }
        viewModelScope.launch {
            container.captureRepository.observeRecent(50).collect { captures ->
                // 只列「还没整理成笔记」的记录。
                // 判据是状态而不是类型：解析成功的记录（EXTRACTED）已经长成笔记了，
                // 再列一遍就是同一件事出现两次；而图片、录音、以及没解析成功的文字，
                // 都还只存在于 capture_item 里，不列出来用户就完全看不到自己存了什么。
                val media = captures
                    .filter { it.status != CaptureStatus.EXTRACTED }
                    .map { record ->
                        MediaCaptureItem(
                            captureId = record.id,
                            kind = record.kind,
                            path = record.mediaPath,
                            recordedAt = record.recordedAt,
                            status = record.status,
                            text = record.rawText?.takeIf { it.isNotBlank() }
                                ?: record.ocrText?.takeIf { it.isNotBlank() }
                                ?: record.transcript?.takeIf { it.isNotBlank() },
                            transcriptText = record.transcript?.takeIf { it.isNotBlank() },
                        )
                    }
                _state.update { it.copy(mediaCaptures = media) }
            }
        }
    }

    /**
     * 删掉一条图片 / 录音记录。
     *
     * 先删库再删文件：库里的行是「这条记录存在」的唯一凭据，先删文件会让界面短暂出现
     * 一条指向不存在文件的记录；反过来只会留下一个没人引用的文件，由 deleteQuietly 兜底。
     */
    fun deleteCapture(item: MediaCaptureItem) {
        viewModelScope.launch {
            runCatching { container.captureRepository.delete(item.captureId) }
                .onFailure { error ->
                    _state.update { it.copy(error = error.message ?: "删除失败") }
                    return@launch
                }
            val path = item.path ?: return@launch
            // 图片是按内容哈希去重的：同一张图选两次会共用同一个文件。
            // 所以删记录之后要先确认没有别的记录还指向它，否则会把另一条记录变成裂图。
            val stillUsed = runCatching {
                container.captureRepository.observeRecent(200).first().any { it.mediaPath == path }
            }.getOrDefault(true)
            if (!stillUsed) container.mediaStore.deleteQuietly(File(path))
        }
    }

    fun onFilterChange(kind: NoteOriginKind?) {
        _state.update { it.copy(filter = kind) }
    }

    fun onKeywordChange(value: String) {
        _state.update { it.copy(keyword = value, error = null) }
        if (value.isBlank()) {
            _state.update { it.copy(notes = recent, searching = false) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(searching = true) }
            runCatching { container.noteRepository.search(value) }
                .onSuccess { found ->
                    _state.update { it.copy(notes = found, searching = false, loaded = true) }
                }
                .onFailure { error ->
                    _state.update { it.copy(searching = false, error = error.message ?: "搜索失败") }
                }
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { NoteListViewModel(container) }
        }
    }
}

data class NoteDetailUiState(
    val loading: Boolean = true,
    val note: NoteRecord? = null,
    val sourceCaptureKind: String? = null,
    val sourceCaptureText: String? = null,
    val relatedNotes: List<NoteRecord> = emptyList(),
    val relatedTasks: List<TaskRecord> = emptyList(),
    val titleDraft: String = "",
    val bodyDraft: String = "",
    val deleted: Boolean = false,
    val busy: Boolean = false,
    val notice: String? = null,
    val error: String? = null,
    /** 「今天 / 昨天 / 10月20日」的基准时刻，和列表页保持同一套日期写法。 */
    val now: Instant? = null,
) {
    /** 标题或正文被改过才允许保存，避免「点一下保存」把 user_edited 无意义地置位。 */
    val dirty: Boolean
        get() = note != null && (titleDraft.trim() != note.title || bodyDraft != note.body)
}

/**
 * 记录详情：可编辑、可软删除，并显示来源。
 *
 * 保存走 saveUserEdit 而不是整行 update：那条 SQL 会把 user_edited 置位，
 * 而「用户改过的内容优先于任何晚到的机器识别结果」正是靠这个标志实现的。
 */
class NoteDetailViewModel(
    private val container: AppContainer,
    private val noteId: String,
) : ViewModel() {

    private val _state = MutableStateFlow(NoteDetailUiState(now = container.timeSource.now()))
    val state: StateFlow<NoteDetailUiState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun onTitleChange(value: String) {
        _state.update { it.copy(titleDraft = value, error = null) }
    }

    fun onBodyChange(value: String) {
        _state.update { it.copy(bodyDraft = value, error = null) }
    }

    fun clearMessages() {
        _state.update { it.copy(notice = null, error = null) }
    }

    fun save() {
        val current = _state.value
        if (current.bodyDraft.isBlank() && current.titleDraft.isBlank()) {
            _state.update { it.copy(error = "标题和正文不能同时为空。", notice = null) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, notice = null) }
            runCatching {
                container.noteRepository.saveUserEdit(noteId, current.titleDraft.trim(), current.bodyDraft)
            }.onSuccess {
                _state.update { it.copy(busy = false, notice = "已保存。这条笔记标记为「用户修订」，后续识别结果不会覆盖它。") }
                refresh()
            }.onFailure { error ->
                _state.update { it.copy(busy = false, error = error.message ?: "保存失败") }
            }
        }
    }

    fun delete() {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, error = null, notice = null) }
            runCatching { container.noteRepository.softDelete(noteId) }
                .onSuccess { _state.update { it.copy(busy = false, deleted = true, notice = "已删除。这是软删除，记录仍留在本机数据库中，不会被立刻抹掉。") } }
                .onFailure { error -> _state.update { it.copy(busy = false, error = error.message ?: "删除失败") } }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                val note = container.noteRepository.find(noteId)
                val capture = note?.originCaptureId?.let { container.captureRepository.find(it) }
                // 溯源优先按来源记录，其次按课程：两条线索都可能为空，那就没有相关笔记。
                val relatedNotes = note?.originCaptureId?.let { container.noteRepository.listByOriginCapture(it) }
                    ?: note?.courseHint?.takeIf { it.isNotBlank() }?.let { container.noteRepository.listByCourse(it) }
                    ?: emptyList()
                val relatedTasks = note?.originCaptureId?.let { container.taskRepository.listByOriginCapture(it) } ?: emptyList()
                Triple(note, capture, relatedNotes to relatedTasks)
            }.onSuccess { (note, capture, related) ->
                val (relatedNotes, relatedTasks) = related
                _state.update {
                    it.copy(
                        loading = false,
                        note = note,
                        sourceCaptureKind = capture?.kind?.displayName,
                        sourceCaptureText = capture?.let { record -> container.captureRepository.displayText(record) },
                        relatedNotes = relatedNotes.filter { other -> other.id != noteId },
                        relatedTasks = relatedTasks,
                        titleDraft = note?.title.orEmpty(),
                        bodyDraft = note?.body.orEmpty(),
                    )
                }
            }.onFailure { error ->
                _state.update { it.copy(loading = false, error = error.message ?: "读取笔记失败") }
            }
        }
    }

    companion object {
        fun factory(container: AppContainer, noteId: String): ViewModelProvider.Factory = viewModelFactory {
            initializer { NoteDetailViewModel(container, noteId) }
        }
    }
}
