package com.daycue.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.AppContainer
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.network.DayCueApiException
import com.daycue.android.platform.capability.CapabilityReport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalTime

/** 连接测试的状态。用枚举而不是「一个可空字符串」：界面才能区分「还没测过」和「测失败了」。 */
enum class ConnectionState { IDLE, TESTING, OK, FAILED }

data class SettingsUiState(
    val loading: Boolean = true,
    val backendUrl: String = "",
    val offlineMode: Boolean = false,
    val purelyLocal: Boolean = true,
    val connection: ConnectionState = ConnectionState.IDLE,
    val connectionMessage: String? = null,
    // 能力与权限
    val recordingGranted: Boolean = false,
    val cameraGranted: Boolean = false,
    val notificationsGranted: Boolean = false,
    val exactAlarmGranted: Boolean = false,
    val locationName: String = "",
    val locationUsable: Boolean = false,
    // 学期基准（文本态，便于用户边输边改）
    val termFirstMonday: String = "",
    val termWeeks: String = "",
    // 打扰预算
    val dailyLimit: String = "3",
    val minIntervalMinutes: String = "90",
    val quietStart: String = "22:30",
    val quietEnd: String = "08:00",
    val locationRulesEnabled: Boolean = false,
    // 统计
    val noteCount: Int = 0,
    val openTaskCount: Int = 0,
    val outboxPending: Int = 0,
    val message: String? = null,
    val error: String? = null,
)

/**
 * 设置。
 *
 * 这里刻意不做「乐观更新」：每一项都是先写库、再把库里的值读回来刷新界面。
 * 因为设置大多是「开关 + 立即生效」的语义，界面显示的和实际生效的不一致，
 * 会让用户反复点、最后完全不信任这一页。
 */
class SettingsViewModel(private val container: AppContainer) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    init {
        refresh()
        viewModelScope.launch {
            container.noteRepository.observeCount().collect { count -> _state.update { it.copy(noteCount = count) } }
        }
        viewModelScope.launch {
            container.taskRepository.observeOpenCount().collect { count -> _state.update { it.copy(openTaskCount = count) } }
        }
        viewModelScope.launch {
            container.syncRepository.observePendingCount().collect { count -> _state.update { it.copy(outboxPending = count) } }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            val settings = container.settingsRepository
            val term = runCatching { settings.termCalendar() }.getOrNull()
            val budget = runCatching { settings.budgetPolicy() }.getOrDefault(BudgetPolicy())
            val quiet = runCatching { settings.quietHours() }.getOrDefault(LocalTime.of(22, 30) to LocalTime.of(8, 0))
            _state.update {
                it.copy(
                    loading = false,
                    backendUrl = runCatching { settings.backendBaseUrl() }.getOrNull().orEmpty(),
                    offlineMode = runCatching { settings.offlineMode() }.getOrDefault(false),
                    purelyLocal = runCatching { settings.isPurelyLocal() }.getOrDefault(true),
                    locationRulesEnabled = runCatching { settings.locationRulesEnabled() }.getOrDefault(false),
                    termFirstMonday = term?.firstWeekMonday?.toString().orEmpty(),
                    termWeeks = term?.totalWeeks?.toString().orEmpty(),
                    dailyLimit = budget.dailyLimit.toString(),
                    minIntervalMinutes = budget.minIntervalMinutes.toString(),
                    quietStart = quiet.first.toString(),
                    quietEnd = quiet.second.toString(),
                )
            }
        }
    }

    /**
     * 能力状态由界面在每次进入前台时喂进来。
     *
     * 权限只能在 Activity 里查询与申请，ViewModel 拿不到 Context 也不该拿；
     * 同时系统设置的跳转也必须由界面发起，所以这里只接收结果、不主动查询。
     */
    fun updateCapabilities(report: CapabilityReport) {
        _state.update {
            it.copy(
                recordingGranted = report.recordingAllowed,
                cameraGranted = report.cameraAvailable,
                notificationsGranted = report.notificationsAllowed,
                exactAlarmGranted = report.exactAlarmAllowed,
                locationName = report.location.displayName,
                locationUsable = report.location.isUsable,
            )
        }
    }

    fun onBackendUrlChange(value: String) = _state.update { it.copy(backendUrl = value) }

    fun saveBackendUrl() {
        viewModelScope.launch {
            val raw = _state.value.backendUrl
            runCatching { container.settingsRepository.setBackendBaseUrl(raw) }
                .onSuccess {
                    _state.update { it.copy(message = if (raw.isBlank()) "已清空后端地址，App 现在完全在本机运行" else "后端地址已保存") }
                    refresh()
                }
                .onFailure { it.fail("保存后端地址失败") }
        }
    }

    fun setOfflineMode(enabled: Boolean) {
        viewModelScope.launch {
            runCatching { container.settingsRepository.setOfflineMode(enabled) }
                .onSuccess {
                    _state.update { it.copy(message = if (enabled) "已切换到纯本地模式，不再发起任何网络请求" else "已允许联网") }
                    refresh()
                }
                .onFailure { it.fail("切换离线模式失败") }
        }
    }

    fun testConnection() {
        viewModelScope.launch {
            _state.update { it.copy(connection = ConnectionState.TESTING, connectionMessage = "正在连接…") }
            val result = runCatching { container.apiClient.health() }
            result
                .onSuccess { text ->
                    _state.update { it.copy(connection = ConnectionState.OK, connectionMessage = "连接正常：$text") }
                }
                .onFailure { error ->
                    // 必须显示真实原因：只写「连接失败」会让用户没法判断是地址错了、没联网，还是服务挂了。
                    val detail = when (error) {
                        is DayCueApiException -> error.message ?: "服务返回了无法识别的错误"
                        else -> error.message ?: error::class.java.simpleName
                    }
                    _state.update { it.copy(connection = ConnectionState.FAILED, connectionMessage = "连接失败：$detail") }
                }
        }
    }

    fun setLocationRulesEnabled(enabled: Boolean) {
        viewModelScope.launch {
            runCatching { container.settingsRepository.setLocationRulesEnabled(enabled) }
                .onSuccess { refresh() }
                .onFailure { it.fail("保存地点规则开关失败") }
        }
    }

    fun saveTerm(firstMondayText: String, weeksText: String) {
        val date = runCatching { java.time.LocalDate.parse(firstMondayText.trim()) }.getOrNull()
        if (date == null) {
            _state.update { it.copy(error = "学期第一周的周一需要写成 2026-09-07 这样的日期") }
            return
        }
        val weeks = weeksText.trim().toIntOrNull()
        if (weeks == null || weeks !in 1..60) {
            _state.update { it.copy(error = "学期周数需要是 1 到 60 之间的整数") }
            return
        }
        viewModelScope.launch {
            runCatching { container.settingsRepository.setTermCalendar(com.daycue.android.domain.schedule.TermCalendar(firstWeekMonday = date, totalWeeks = weeks)) }
                .onSuccess { _state.update { it.copy(message = "学期基准已保存，课表会按它展开") }; refresh() }
                .onFailure { it.fail("保存学期基准失败") }
        }
    }

    fun saveBudget(dailyLimitText: String, minIntervalText: String, quietStartText: String, quietEndText: String) {
        val limit = dailyLimitText.trim().toIntOrNull()
        val interval = minIntervalText.trim().toLongOrNull()
        val start = runCatching { LocalTime.parse(quietStartText.trim()) }.getOrNull()
        val end = runCatching { LocalTime.parse(quietEndText.trim()) }.getOrNull()
        if (limit == null || limit < 0) { _state.update { it.copy(error = "每日消息条数需要是不小于 0 的整数") }; return }
        if (interval == null || interval < 0) { _state.update { it.copy(error = "最小间隔需要是不小于 0 的分钟数") }; return }
        if (start == null || end == null) { _state.update { it.copy(error = "静默时段需要写成 22:30 这样的时间") }; return }
        viewModelScope.launch {
            runCatching {
                container.settingsRepository.setBudgetPolicy(BudgetPolicy(dailyLimit = limit, minIntervalMinutes = interval))
                container.settingsRepository.setQuietHours(start, end)
            }
                .onSuccess { _state.update { it.copy(message = "打扰预算已保存") }; refresh() }
                .onFailure { it.fail("保存打扰预算失败") }
        }
    }

    /**
     * 清空本地数据。
     *
     * 直接 clearAllTables 而不是逐表删除：用户按下这个按钮的意思就是「把本机这份数据全部丢掉」，
     * 逐表删既慢又容易漏掉新加的表。未同步的 outbox 记录会一起消失，这一点在确认弹窗里写清楚了。
     */
    fun clearLocalData() {
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { container.database.clearAllTables() } }
                .onSuccess { _state.update { it.copy(message = "本机数据已清空") }; refresh() }
                .onFailure { it.fail("清空本地数据失败") }
        }
    }

    fun clearMessages() = _state.update { it.copy(message = null, error = null) }

    private fun Throwable.fail(prefix: String) {
        _state.update { it.copy(error = prefix + "：" + (message ?: this::class.java.simpleName), message = null) }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer { SettingsViewModel(container) }
        }
    }
}
