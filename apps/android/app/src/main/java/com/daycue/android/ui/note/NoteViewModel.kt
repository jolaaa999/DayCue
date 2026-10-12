package com.daycue.android.ui.note

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class NoteListUiState(
    val keyword: String = "",
    val notes: List<NoteRecord> = emptyList(),
    val searching: Boolean = false,
    val loaded: Boolean = false,
    val error: String? = null,
)

/**
 * 记录列表。
 *
 * 关键词为空时跟着仓储的最近列表走（流式）；一旦输入关键词就切到仓储的检索结果。
 * 为什么两套路径不合并：检索是 LIKE 查询，把它挂成流式会让每次击键都重启一个查询，
 * 而笔记量级很小，一次性查完更省电。
 */
class NoteListViewModel(private val container: AppContainer) : ViewModel() {

    private val _state = MutableStateFlow(NoteListUiState())
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

    private val _state = MutableStateFlow(NoteDetailUiState())
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
