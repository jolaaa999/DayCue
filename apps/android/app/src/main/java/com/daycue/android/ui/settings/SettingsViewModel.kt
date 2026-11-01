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
    // 令牌只作为「待保存的草稿」留在状态里，保存后立刻清空；已保存与否由 tokenStored 表达。
    val bearerToken: String = "",
    val tokenStored: Boolean = false,
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
    // 外观偏好（跟随系统 / 浅色 / 深色），原始字符串由 ThemeMode.fromRaw 解释。
    val themeMode: String = "system",
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
            // 令牌存在 AndroidKeyStore 里，解密有成本，不能在主线程做。
            val hasToken = withContext(Dispatchers.IO) {
                runCatching { container.tokenStore.read() != null }.getOrDefault(false)
            }
            _state.update {
                it.copy(
                    loading = false,
                    tokenStored = hasToken,
                    backendUrl = runCatching { settings.backendBaseUrl() }.getOrNull().orEmpty(),
                    offlineMode = runCatching { settings.offlineMode() }.getOrDefault(false),
                    purelyLocal = runCatching { settings.isPurelyLocal() }.getOrDefault(true),
                    locationRulesEnabled = runCatching { settings.locationRulesEnabled() }.getOrDefault(false),
                    themeMode = runCatching { settings.themeMode() }.getOrNull() ?: "system",
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

    fun onBearerTokenChange(value: String) = _state.update { it.copy(bearerToken = value) }

    /**
     * 保存后端令牌（传空串即清除）。
     *
     * 为什么必须让用户手工粘贴：本端没有登录界面，令牌只能在电脑上用
     * scripts/issue-token.ps1 换好再填进来。此前 TokenStore 虽然实现了 save()，
     * 却**没有任何调用方**，于是设备登记、同步、AI 解析全是 401，
     * 而界面上完全没有地方能把令牌填进去——这类「类写好了但没有入口」的缺口
     * 从代码结构上看不出来，只有真的把 App 装到手机上才会撞到。
     */
    fun saveBearerToken() {
        val raw = _state.value.bearerToken.trim()
        viewModelScope.launch {
            // TokenStore.save 内部会吞掉 KeyStore 异常（它拒绝退回明文存储），
            // 所以这里用「存完再读回来」确认结果：只信 save 的返回会把
            // 「系统密钥库不可用」显示成保存成功。
            val stored = withContext(Dispatchers.IO) {
                runCatching {
                    container.tokenStore.save(raw)
                    raw.isEmpty() || container.tokenStore.read() != null
                }.getOrDefault(false)
            }
            if (!stored) {
                _state.update { it.copy(error = "保存后端令牌失败：系统密钥库不可用，令牌没有写入", message = null) }
                return@launch
            }
            // 输入框立即清空：令牌一旦保存就不该继续留在界面状态里被截屏或误看。
            _state.update {
                it.copy(
                    bearerToken = "",
                    message = if (raw.isEmpty()) "已清除后端令牌" else "后端令牌已保存",
                )
            }
            refresh()
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

    /**
     * 外观偏好。
     *
     * 写库之后再 refresh：主题由根界面监听同一条流来切换，
     * 这里不做乐观更新，避免「界面变成深色但库里还是浅色」这种下次启动才发现的错位。
     */
    fun setThemeMode(mode: com.daycue.android.ui.theme.ThemeMode) {
        viewModelScope.launch {
            runCatching { container.settingsRepository.setThemeMode(mode.raw) }
                .onSuccess {
                    _state.update { it.copy(message = "外观已切换为" + mode.displayName) }
                    refresh()
                }
                .onFailure { it.fail("保存外观设置失败") }
        }
    }

    fun setLocationRulesEnabled(enabled: Boolean) {
        viewModelScope.launch {
            runCatching { container.settingsRepository.setLocationRulesEnabled(enabled) }
                .onSuccess {
                    // 总开关变化必须立刻对账注册：关掉时要真的取消围栏，
                    // 否则「关了还在提醒」会直接摧毁用户对开关的信任。
                    runCatching { container.geoCoordinator.onRuleChanged() }
                        .onFailure { error -> _state.update { it.copy(error = "地点规则注册更新失败：" + (error.message ?: "未知原因")) } }
                    refresh()
                }
                .onFailure { it.fail("保存地点规则开关失败") }
        }
    }

    fun saveTerm(firstMondayText: String, weeksText: String) {
        // 空值和写错格式分开报，否则用户不知道是「没填」还是「填错了」（ISSUE-20261029-032）
        if (firstMondayText.isBlank()) {
            _state.update { it.copy(error = "请先填学期第一周的周一，例如 2026-09-07（必须是周一）") }
            return
        }
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
