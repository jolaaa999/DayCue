package com.daycue.android.ui.place

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.daycue.android.core.DayCueId
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.data.repository.GeoRuleChangeListener
import com.daycue.android.data.repository.PlaceRepository
import com.daycue.android.data.repository.SystemTimeSource
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.domain.location.GeoPlaceSpec
import com.daycue.android.domain.location.GeoRuleReadiness
import com.daycue.android.domain.location.GeoRuleReadinessEvaluator
import com.daycue.android.domain.location.GeoRuleSpec
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.model.CoordinateSystem
import com.daycue.android.domain.model.PlaceTrigger
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** 规则编辑器里的一份草稿。全部字段都是文本或轻量值，校验放在提交时做，用户能边输边改。 */
data class RuleDraft(
    /** 编辑既有规则时是它的 id；新建时为 null。这个区别决定了 upsertRule 传不传 ruleId。 */
    val ruleId: String? = null,
    val placeId: String = "",
    val trigger: PlaceTrigger = PlaceTrigger.ENTER,
    val title: String = "",
    val body: String = "",
    val minDwellSeconds: String = "300",
    val cooldownSeconds: String = "3600",
    val weekdays: Set<Int> = emptySet(),
    val activeFrom: String = "",
    val activeTo: String = "",
    val expiresAtLocalDate: String = "",
    val linkedTaskId: String? = null,
    val enabled: Boolean = true,
) {
    val isNew: Boolean get() = ruleId == null
}

/** 地点编辑器里的一份草稿。position 为 null 表示「用户还没给出位置」——这种状态下不允许保存。 */
data class PlaceDraft(
    val placeId: String? = null,
    val name: String = "",
    val address: String = "",
    val radiusMeters: String = "200",
    val coordinateSystem: CoordinateSystem = CoordinateSystem.WGS84,
    val latitude: Double? = null,
    val longitude: Double? = null,
    /** 这份位置是不是用户明确给出的（点了「使用当前位置」或用坐标输入框填的）。 */
    val positionFromUser: Boolean = false,
) {
    val isNew: Boolean get() = placeId == null
    val hasPosition: Boolean get() = latitude != null && longitude != null && positionFromUser
    val positionText: String
        get() = if (latitude == null || longitude == null) {
            "尚未选择位置"
        } else {
            "已选择位置：" + formatCoordinate(latitude) + ", " + formatCoordinate(longitude)
        }
}

/** 坐标的展示格式：小数点后 6 位约等于 0.1 米，再多就是假精度。 */
internal fun formatCoordinate(value: Double): String = String.format(java.util.Locale.US, "%.6f", value)

data class PlaceRuleItem(
    val rule: GeoRuleRecord,
    val readiness: GeoRuleReadiness?,
)

data class PlaceListItem(
    val place: PlaceRecord,
    val rules: List<PlaceRuleItem>,
)

data class PlaceUiState(
    val loading: Boolean = true,
    val capability: LocationCapability = LocationCapability.UNSUPPORTED,
    val locationRulesEnabled: Boolean = false,
    val places: List<PlaceListItem> = emptyList(),
    val openTasks: List<TaskRecord> = emptyList(),
    val draft: PlaceDraft? = null,
    val ruleDraft: RuleDraft? = null,
    val message: String? = null,
    val error: String? = null,
) {
    /** 规则链路当前是不是真的在工作。界面所有「会不会触发」的措辞都以它为前提。 */
    val locationReady: Boolean get() = capability.isUsable && locationRulesEnabled
}

/** 界面读取地点 / 规则 / 能力 / 任务的口子。 */
interface PlaceCatalog {
    /** 未删除的地点。用 Flow 而不是一次性快照：地点栏在被别处改动时这一页要跟着变。 */
    fun places(): Flow<List<PlaceRecord>>

    fun rules(): Flow<List<GeoRuleRecord>>

    /** 可以关联的任务（未完成、未取消）。 */
    fun tasks(): Flow<List<TaskRecord>>

    suspend fun capability(): LocationCapability

    suspend fun locationRulesEnabled(): Boolean
}

/**
 * 地点与规则管理。
 *
 * 一条贯穿的约束：**任何写入之后都必须通知围栏链路**。
 * 只写库不通知，用户看到的是「规则建好了」，系统里却什么都没注册——
 * 「写了类但没有调用方」在数据层看不出来，只在用户收不到提醒时才暴露。
 * 所以每个写操作的最后一步都是 [GeoRuleChangeListener]：保存 / 开关走 onRuleChanged，
 * 删除规则走 onRulesRemoved（它还会取消那条已经排上的通知）。
 *
 * 位置来源：只接受用户自己给出的点（当前位置或手工经纬度）。
 * 没有位置就不保存，读不到位置时明确报错，绝不静默填一个坐标。
 */
class PlaceViewModel(
    private val repository: PlaceRepository,
    private val geoChanges: GeoRuleChangeListener,
    private val locationPicker: LocationPicker,
    private val catalog: PlaceCatalog,
    private val zone: ZoneId = ZoneId.systemDefault(),
    /** 「现在」由外界给出：界面用系统时钟，测试给固定时刻，判定结果才不会随运行时间变化。 */
    private val timeSource: TimeSource = SystemTimeSource,
) : ViewModel() {

    private val _state = MutableStateFlow(PlaceUiState())
    val state: StateFlow<PlaceUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            catalog.places().collect { records ->
                _state.update { it.copy(places = mergePlaces(records, it.places)) }
                refreshReadiness()
            }
        }
        viewModelScope.launch {
            catalog.rules().collect { records ->
                _state.update { it.copy(places = mergeRules(records, it.places)) }
                refreshReadiness()
            }
        }
        viewModelScope.launch {
            catalog.tasks().collect { records -> _state.update { it.copy(openTasks = records) } }
        }
        // 能力与总开关每次进入这一页都重新读一次：用户可能刚从系统设置里改了权限，
        // 缓存下来的结论会让界面显示成「可以触发」而实际不会。
        refreshAvailability()
    }

    // ---- 列表 ----

    fun refreshAvailability() {
        viewModelScope.launch {
            val capability = runCatching { catalog.capability() }.getOrDefault(LocationCapability.UNSUPPORTED)
            val enabled = runCatching { catalog.locationRulesEnabled() }.getOrDefault(false)
            _state.update { it.copy(loading = false, capability = capability, locationRulesEnabled = enabled) }
            refreshReadiness()
        }
    }

    fun clearMessages() = _state.update { it.copy(message = null, error = null) }

    // ---- 地点编辑 ----

    /** 打开编辑器。placeId 为 null 时是新地点，草稿里不带任何位置。 */
    fun startPlaceDraft(placeId: String?) {
        if (placeId == null) {
            _state.update { it.copy(draft = PlaceDraft(), error = null, message = null) }
            return
        }
        viewModelScope.launch {
            val place = runCatching { repository.findPlace(placeId) }.getOrNull()
            if (place == null) {
                _state.update { it.copy(error = "这个地点已经不存在了") }
                return@launch
            }
            _state.update {
                it.copy(
                    draft = PlaceDraft(
                        placeId = place.id,
                        name = place.name,
                        address = place.address.orEmpty(),
                        radiusMeters = trimNumber(place.radiusMeters),
                        coordinateSystem = place.coordinateSystem,
                        latitude = place.latitude,
                        longitude = place.longitude,
                        positionFromUser = true,
                    ),
                    error = null,
                    message = null,
                )
            }
        }
    }

    fun closeDraft() = _state.update { it.copy(draft = null) }

    fun updateDraft(transform: (PlaceDraft) -> PlaceDraft) =
        _state.update { current -> current.draft?.let { current.copy(draft = transform(it)) } ?: current }

    fun updateDraftField(value: String) = updateDraft { it.copy(name = value) }

    fun updateDraftAddress(value: String) = updateDraft { it.copy(address = value) }

    fun updateDraftRadius(value: String) = updateDraft { it.copy(radiusMeters = value) }

    /** 手工输入纬度。输入框里无法表达「没填」，所以清空即把位置退回「未选择」。 */
    fun updateDraftLatitude(value: String) {
        val parsed = value.trim().toDoubleOrNull()
        updateDraft { draft ->
            if (value.isBlank() || parsed == null) {
                draft.copy(latitude = null, positionFromUser = false)
            } else {
                draft.copy(latitude = parsed, positionFromUser = draft.longitude != null)
            }
        }
    }

    fun updateDraftLongitude(value: String) {
        val parsed = value.trim().toDoubleOrNull()
        updateDraft { draft ->
            if (value.isBlank() || parsed == null) {
                draft.copy(longitude = null, positionFromUser = false)
            } else {
                draft.copy(longitude = parsed, positionFromUser = draft.latitude != null)
            }
        }
    }

    /**
     * 使用当前位置。
     *
     * 读不到就**明确报错**并把位置保持为「未选择」：静默填一个默认点会让用户以为
     * 规则设在了家里，实际围栏挂在了别处，而且完全看不出来。
     */
    fun useCurrentLocation() {
        viewModelScope.launch {
            val point = runCatching { locationPicker.currentPoint() }.getOrNull()
            if (point == null) {
                _state.update {
                    it.copy(
                        error = "读不到当前位置（可能是没有定位权限、系统定位已关闭，或设备还没有拿到过定位）。" +
                            "可以手工输入经纬度，或者稍后再试；在拿到位置之前不能保存。",
                        message = null,
                    )
                }
                return@launch
            }
            updateDraft {
                it.copy(latitude = point.latitude, longitude = point.longitude, positionFromUser = true)
            }
            _state.update { it.copy(message = "已取到当前位置，保存前请确认半径", error = null) }
        }
    }

    /** 保存地点。校验失败只报错，绝不落库。 */
    fun savePlace(onSaved: (String) -> Unit = {}) {
        val draft = _state.value.draft ?: return
        val problem = validate(draft)
        if (problem != null) {
            _state.update { it.copy(error = problem, message = null) }
            return
        }
        val latitude = draft.latitude!!
        val longitude = draft.longitude!!
        viewModelScope.launch {
            val result = runCatching {
                if (draft.placeId == null) {
                    repository.createConfirmedPlace(
                        name = draft.name,
                        latitude = latitude,
                        longitude = longitude,
                        radiusMeters = draft.radiusMeters.trim().toDouble(),
                        coordinateSystem = draft.coordinateSystem,
                        address = draft.address.ifBlank { null },
                    )
                } else {
                    // 编辑不新建：id 必须是既有那条，否则会多出一个地点、
                    // 而旧地点上的规则仍然指向旧的那条，用户会看到两份同名地点。
                    val existing = repository.findPlace(draft.placeId)
                        ?: error("这个地点已经不存在了")
                    repository.updatePlace(
                        existing.copy(
                            name = draft.name.trim(),
                            latitude = latitude,
                            longitude = longitude,
                            radiusMeters = draft.radiusMeters.trim().toDouble(),
                            coordinateSystem = draft.coordinateSystem,
                            address = draft.address.trim().ifBlank { null },
                        ),
                    )
                    existing.id
                }
            }
            result
                .onSuccess { placeId ->
                    // 地点变化会改变围栏本身（坐标 / 半径），必须重新对账注册。
                    notifyRuleChanged("地点已保存，但围栏注册更新失败：")
                    _state.update { it.copy(draft = null, message = "地点已保存，围栏已按新位置重新注册。", error = null) }
                    onSaved(placeId)
                }
                .onFailure { error ->
                    _state.update { it.copy(error = "保存地点失败：" + (error.message ?: error::class.java.simpleName)) }
                }
        }
    }

    // ---- 规则编辑 ----

    fun startRuleDraft(placeId: String, ruleId: String?) {
        if (ruleId == null) {
            val usable = _state.value.capability.isUsable
            _state.update {
                it.copy(
                    ruleDraft = RuleDraft(placeId = placeId, enabled = usable),
                    error = null,
                    message = null,
                )
            }
            return
        }
        viewModelScope.launch {
            val rule = runCatching { repository.findRule(ruleId) }.getOrNull()
            if (rule == null) {
                _state.update { it.copy(error = "这条规则已经不存在了") }
                return@launch
            }
            _state.update {
                it.copy(
                    ruleDraft = RuleDraft(
                        ruleId = rule.id,
                        placeId = rule.placeId,
                        trigger = rule.trigger,
                        title = rule.title,
                        body = rule.body.orEmpty(),
                        minDwellSeconds = rule.minDwellSeconds.toString(),
                        cooldownSeconds = rule.cooldownSeconds.toString(),
                        weekdays = rule.weekdays.toSet(),
                        activeFrom = rule.activeFromLocal?.toString().orEmpty(),
                        activeTo = rule.activeToLocal?.toString().orEmpty(),
                        expiresAtLocalDate = rule.expiresAtUtc?.let { instant ->
                            instant.atZone(zone).toLocalDate().toString()
                        }.orEmpty(),
                        linkedTaskId = rule.linkedTaskId,
                        enabled = rule.enabled,
                    ),
                    error = null,
                    message = null,
                )
            }
        }
    }

    fun closeRuleDraft() = _state.update { it.copy(ruleDraft = null) }

    fun updateRuleDraft(transform: (RuleDraft) -> RuleDraft) =
        _state.update { current -> current.ruleDraft?.let { current.copy(ruleDraft = transform(it)) } ?: current }

    fun toggleWeekday(day: Int) = updateRuleDraft { draft ->
        draft.copy(weekdays = if (day in draft.weekdays) draft.weekdays - day else draft.weekdays + day)
    }

    /**
     * 保存规则。
     *
     * 编辑时必须把既有 ruleId 传给仓储：upsertRule 是 @Insert(ABORT) 语义，
     * 不传 id 就会在库里多出一条规则，两条规则同源会让同一次进入触发两次通知。
     */
    fun saveRule() {
        val draft = _state.value.ruleDraft ?: return
        val problem = validate(draft)
        if (problem != null) {
            _state.update { it.copy(error = problem, message = null) }
            return
        }
        val placeId = draft.placeId
        val ruleId = draft.ruleId
        viewModelScope.launch {
            runCatching {
                repository.upsertRule(
                    placeId = placeId,
                    trigger = draft.trigger,
                    title = draft.title,
                    availability = catalog.capability(),
                    body = draft.body.ifBlank { null },
                    minDwellSeconds = draft.minDwellSeconds.trim().toIntOrNull() ?: 0,
                    cooldownSeconds = draft.cooldownSeconds.trim().toIntOrNull() ?: 0,
                    weekdays = draft.weekdays.toList(),
                    activeFrom = parseTime(draft.activeFrom),
                    activeTo = parseTime(draft.activeTo),
                    expiresAt = parseExpiry(draft.expiresAtLocalDate),
                    ruleId = ruleId ?: newRuleId(),
                    enabled = draft.enabled,
                    linkedTaskId = draft.linkedTaskId,
                )
            }
                .onSuccess { saved ->
                    notifyRuleChanged("规则已保存，但围栏注册更新失败：")
                    _state.update {
                        it.copy(
                            ruleDraft = null,
                            message = if (saved.enabled) {
                                "规则已保存，围栏与通知链路已重新注册。"
                            } else {
                                "规则已保存（当前为暂停状态），围栏不会为它注册。"
                            },
                            error = null,
                        )
                    }
                }
                .onFailure { error ->
                    _state.update { it.copy(error = "保存规则失败：" + (error.message ?: error::class.java.simpleName)) }
                }
        }
    }

    /**
     * 新建规则 id。
     *
     * 用仓储生成的 id 更好，但 upsertRule 的 ruleId 是普通参数；这里复用同一个生成器，
     * 保证新建的 id 与其它实体同一形状（而不是界面自己拼一个）。
     */
    private fun newRuleId(): String = DayCueId.new()

    // ---- 开关与删除 ----

    fun setRuleEnabled(ruleId: String, enabled: Boolean) {
        viewModelScope.launch {
            runCatching { repository.setEnabled(ruleId, enabled) }
                .onSuccess {
                    notifyRuleChanged("开关已保存，但围栏注册更新失败：")
                    _state.update {
                        it.copy(
                            message = if (enabled) "规则已启用，围栏已注册。" else "规则已关闭，围栏已注销。",
                            error = null,
                        )
                    }
                    refreshReadiness()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = "切换规则开关失败：" + (error.message ?: "未知原因")) }
                }
        }
    }

    /** 删除规则：先取消它已经排上的通知，再注销围栏，最后才重新对账。 */
    fun deleteRule(ruleId: String) {
        viewModelScope.launch {
            runCatching { repository.deleteRule(ruleId) }
                .onSuccess {
                    runCatching { geoChanges.onRulesRemoved(listOf(ruleId)) }
                        .onFailure { error ->
                            _state.update { it.copy(error = "规则已删除，但取消失败：" + (error.message ?: "未知原因")) }
                        }
                    _state.update { it.copy(message = "规则已删除，它排队中的提醒也已取消。", error = null) }
                    refreshReadiness()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = "删除规则失败：" + (error.message ?: "未知原因")) }
                }
        }
    }

    /**
     * 删除地点。
     *
     * 仓储会连带软删除它下面的规则并返回这些规则 id，这里再把这些 id 交给 onRulesRemoved：
     * 只注销围栏而不取消已经排上的通知，用户删掉地点后仍会收到那条提醒，看起来像删除没生效。
     */
    fun deletePlace(placeId: String) {
        viewModelScope.launch {
            runCatching { repository.deletePlace(placeId) }
                .onSuccess { removedRuleIds ->
                    if (removedRuleIds.isNotEmpty()) {
                        runCatching { geoChanges.onRulesRemoved(removedRuleIds) }
                            .onFailure { error ->
                                _state.update { it.copy(error = "地点已删除，但取消失败：" + (error.message ?: "未知原因")) }
                            }
                    }
                    notifyRuleChanged("地点已删除，但围栏注册更新失败：")
                    _state.update { it.copy(message = "地点已删除，它下面的规则与排队提醒都已取消。", error = null) }
                    refreshReadiness()
                }
                .onFailure { error ->
                    _state.update { it.copy(error = "删除地点失败：" + (error.message ?: "未知原因")) }
                }
        }
    }

    // ---- 校验 ----

    private fun validate(draft: PlaceDraft): String? {
        if (draft.name.isBlank()) return "地点名称不能为空"
        if (!draft.hasPosition) {
            return "还没有位置：请点「使用当前位置」读一次真实定位，或手工输入经纬度。" +
                "DayCue 不会替你填一个坐标。"
        }
        val latitude = draft.latitude!!
        val longitude = draft.longitude!!
        if (latitude !in -90.0..90.0) return "纬度必须在 -90 到 90 之间（当前 " + latitude + "）"
        if (longitude !in -180.0..180.0) return "经度必须在 -180 到 180 之间（当前 " + longitude + "）"
        val radius = draft.radiusMeters.trim().toDoubleOrNull()
        if (radius == null || radius <= 0) return "半径必须是大于 0 的米数"
        return null
    }

    private fun validate(draft: RuleDraft): String? {
        if (draft.title.isBlank()) return "规则标题不能为空"
        if (draft.placeId.isBlank()) return "规则必须挂在一个地点上"
        val dwell = draft.minDwellSeconds.trim().toIntOrNull()
        if (draft.trigger == PlaceTrigger.DWELL && (dwell == null || dwell <= 0)) {
            return "「停留一段时间后」必须给出大于 0 的最短停留秒数"
        }
        val cooldown = draft.cooldownSeconds.trim().toIntOrNull()
        if (cooldown == null || cooldown < 0) return "冷却秒数必须是不小于 0 的整数"
        if (draft.activeFrom.isNotBlank() && parseTime(draft.activeFrom) == null) return "生效起点需要写成 08:00 这样的时间"
        if (draft.activeTo.isNotBlank() && parseTime(draft.activeTo) == null) return "生效终点需要写成 08:00 这样的时间"
        if (draft.expiresAtLocalDate.isNotBlank() && parseExpiry(draft.expiresAtLocalDate) == null) {
            return "过期日期需要写成 2026-12-31 这样的日期"
        }
        return null
    }

    // ---- 内部 ----

    /**
     * 通知围栏链路。
     *
     * 失败只提示、不回滚写库：库里已经是用户确认过的状态，
     * 下一次进入这一页或进程重启时的 refreshRegistration 会再对账一次；
     * 把写库回滚反而会让「界面说保存失败、其实库里有」更难解释。
     */
    private suspend fun notifyRuleChanged(prefix: String) {
        runCatching { geoChanges.onRuleChanged() }
            .onFailure { error ->
                _state.update { it.copy(error = prefix + (error.message ?: "未知原因")) }
            }
    }

    private fun refreshReadiness() {
        viewModelScope.launch {
            val current = _state.value
            val capability = runCatching { catalog.capability() }.getOrDefault(current.capability)
            val enabled = runCatching { catalog.locationRulesEnabled() }.getOrDefault(current.locationRulesEnabled)
            // 这里刻意各取一次首帧而不是长期订阅：readiness 只需要「现在」的库状态，
            // 而库变化本身已经由 init 里的两个收集器驱动着重新算一遍，再订阅一次就是重复。
            val rules = runCatching { catalog.rules().first() }.getOrDefault(emptyList())
            val places = runCatching { catalog.places().first() }.getOrDefault(emptyList())
            val placeSpecs = places.associate { it.id to it.toSpec() }
            val ruleSpecs = rules.associate { it.id to it.toSpec() }
            val now = timeSource.now()
            _state.update { state ->
                state.copy(
                    capability = capability,
                    locationRulesEnabled = enabled,
                    places = state.places.map { item ->
                        item.copy(
                            rules = item.rules.map { entry ->
                                val spec = ruleSpecs[entry.rule.id]
                                entry.copy(
                                    readiness = spec?.let {
                                        // 判定口径与协调器完全一致（用的是同一个 Evaluator），
                                        // 所以界面上「为什么不会触发」与系统实际行为不会各说一套。
                                        GeoRuleReadinessEvaluator.evaluate(
                                            rule = it,
                                            place = placeSpecs[it.placeId],
                                            capability = capability,
                                            locationRulesEnabled = enabled,
                                            now = now,
                                        )
                                    },
                                )
                            },
                        )
                    },
                )
            }
        }
    }

    /** 地点记录变化时保留已经算好的规则列表，避免每次刷新都把规则数闪成 0。 */
    private fun mergePlaces(incoming: List<PlaceRecord>, existing: List<PlaceListItem>): List<PlaceListItem> {
        val byId = existing.associateBy { it.place.id }
        return incoming.map { place -> PlaceListItem(place = place, rules = byId[place.id]?.rules.orEmpty()) }
    }

    /** 实体 -> 领域视图。与 PlaceRepository 里那份是同一套换算，只是方向相反，界面不能直接改库。 */
    private fun PlaceRecord.toSpec() = GeoPlaceSpec(
        id = id,
        name = name,
        latitude = latitude,
        longitude = longitude,
        radiusMeters = radiusMeters,
        confirmedByUser = confirmedByUser,
        deleted = deletedAt != null,
    )

    private fun GeoRuleRecord.toSpec() = GeoRuleSpec(
        id = id,
        placeId = placeId,
        trigger = trigger,
        title = title,
        body = body,
        minDwellSeconds = minDwellSeconds,
        cooldownSeconds = cooldownSeconds,
        activeFromLocal = activeFromLocal,
        activeToLocal = activeToLocal,
        weekdays = weekdays,
        enabled = enabled,
        expiresAt = expiresAtUtc,
        linkedTaskId = linkedTaskId,
    )

    private fun mergeRules(incoming: List<GeoRuleRecord>, existing: List<PlaceListItem>): List<PlaceListItem> =
        existing.map { item ->
            val readiness = item.rules.associate { it.rule.id to it.readiness }
            item.copy(
                rules = incoming
                    .filter { it.placeId == item.place.id }
                    .sortedBy { it.createdAt }
                    .map { PlaceRuleItem(rule = it, readiness = readiness[it.id]) },
            )
        }

    private fun parseTime(raw: String): LocalTime? =
        if (raw.isBlank()) null else runCatching { LocalTime.parse(raw.trim()) }.getOrNull()

    /**
     * 过期时刻按用户本地日的**结束**（次日零点前的最后一刻）解释。
     * 不用当地 00:00：那会让「过期日 12-31」在 12-31 当天零点就失效，
     * 用户读到的是「年底前有效」，实际提前一天就不响了。
     */
    private fun parseExpiry(raw: String): Instant? {
        if (raw.isBlank()) return null
        val date = runCatching { LocalDate.parse(raw.trim()) }.getOrNull() ?: return null
        return date.plusDays(1).atStartOfDay(zone).toInstant()
    }

    private fun trimNumber(value: Double): String =
        if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()

    companion object {
        fun factory(
            repository: PlaceRepository,
            geoChanges: GeoRuleChangeListener,
            locationPicker: LocationPicker,
            catalog: PlaceCatalog,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer { PlaceViewModel(repository, geoChanges, locationPicker, catalog) }
        }
    }
}
