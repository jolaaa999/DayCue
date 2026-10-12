package com.daycue.android.ui.memory

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 一组同状态的记忆。分组在界面层做，仓储只负责给出全部条目。 */
data class MemoryGroup(
    val status: MemoryStatus,
    val items: List<MemoryItemRecord>,
)

/** 记忆来源策略的一行说明。 */
data class MemorySourceRow(
    val sourceKind: MemorySourceKind,
    val behavior: String,
)

data class MemoryUiState(
    /** 需要用户关注的条目（待确认里已到期复核的），单独置顶。 */
    val attention: List<MemoryItemRecord> = emptyList(),
    val groups: List<MemoryGroup> = emptyList(),
    val sourcePolicy: List<MemorySourceRow> = emptyList(),
    val loaded: Boolean = false,
    val message: String? = null,
    val error: String? = null,
)

/**
 * 记忆列表。
 *
 * 界面必须把「系统推断」与「用户自己说过」区分得非常清楚：
 * 推断出来的记忆只有在用户确认之后才算事实，否则就是把机器的猜测当成用户的表述。
 * 因此这里不做任何自动确认，只暴露确认 / 作废 / 删除三个显式动作。
 */
class MemoryViewModel(private val container: AppContainer) : ViewModel() {

    private val _state = MutableStateFlow(MemoryUiState())
    val state: StateFlow<MemoryUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            container.memoryRepository.observeAll().collect { records ->
                _state.update { it.copy(groups = group(records), loaded = true) }
            }
        }
        viewModelScope.launch { refreshAttention() }
        _state.update { it.copy(sourcePolicy = defaultPolicy()) }
    }

    fun refreshAttention() {
        viewModelScope.launch {
            runCatching { container.memoryRepository.candidatesNeedingAttention() }
                .onSuccess { items -> _state.update { it.copy(attention = items) } }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: "读取待复核记忆失败") } }
        }
    }

    fun confirm(id: String) = mutate("已确认这条记忆") { container.memoryRepository.confirm(id) }

    fun retire(id: String) = mutate("已作废这条记忆") { container.memoryRepository.retire(id) }

    fun delete(id: String) = mutate("已删除这条记忆") { container.memoryRepository.softDelete(id) }

    fun clearMessages() = _state.update { it.copy(message = null, error = null) }

    private fun mutate(successMessage: String, action: suspend () -> Unit) {
        viewModelScope.launch {
            runCatching { action() }
                .onSuccess { _state.update { it.copy(message = successMessage, error = null) }; refreshAttention() }
                .onFailure { error -> _state.update { it.copy(error = error.message ?: "操作失败", message = null) } }
        }
    }

    private fun group(records: List<MemoryItemRecord>): List<MemoryGroup> =
        // 顺序固定：待确认 -> 冲突 -> 已确认 -> 已失效。让用户先看到需要他做决定的东西。
        listOf(MemoryStatus.CANDIDATE, MemoryStatus.CONFLICT, MemoryStatus.CONFIRMED, MemoryStatus.RETIRED)
            .map { status -> MemoryGroup(status, records.filter { it.status == status }) }
            .filter { it.items.isNotEmpty() }

    /**
     * 来源策略是**如实描述当前实现**，不是可切换的开关。
     *
     * 为什么不放开关：设置里目前没有「按来源类别关闭记忆写入」的键，
     * 放一个不会真正生效的开关比不放更糟——用户会以为关掉之后系统真的不记了。
     */
    private fun defaultPolicy(): List<MemorySourceRow> = listOf(
        MemorySourceRow(MemorySourceKind.USER_STATEMENT, "你自己说过的话，记下来即视为事实"),
        MemorySourceRow(MemorySourceKind.USER_SETTING, "你在设置里选定的偏好，直接生效"),
        MemorySourceRow(MemorySourceKind.INFERRED, "系统推断，只作为待确认候选，等你确认后才算事实"),
    )

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { MemoryViewModel(container) }
        }
    }
}
