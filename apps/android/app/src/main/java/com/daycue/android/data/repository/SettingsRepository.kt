package com.daycue.android.data.repository

import com.daycue.android.data.local.dao.AppSettingDao
import com.daycue.android.data.local.entity.AppSettingRecord
import com.daycue.android.domain.proactive.BudgetPolicy
import com.daycue.android.domain.reminder.ReminderOwner
import com.daycue.android.domain.schedule.TermCalendar
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.time.LocalDate
import java.time.LocalTime

/**
 * 设置仓储。
 *
 * 只放非敏感偏好。后端令牌不进这里（那是 Keystore 的事），
 * 因为 app_setting 就是一张明文表，可以被备份、导出、误读。
 */
class SettingsRepository(
    private val dao: AppSettingDao,
    private val timeSource: TimeSource = SystemTimeSource,
) {

    // ---- 后端 ----

    /** 未配置时返回 null：App 必须能在纯本地模式下工作，所以这里不提供「默认地址」。 */
    suspend fun backendBaseUrl(): String? = dao.get(KEY_BACKEND_URL)?.takeIf { it.isNotBlank() }

    suspend fun setBackendBaseUrl(url: String?) {
        if (url.isNullOrBlank()) dao.delete(KEY_BACKEND_URL) else dao.put(AppSettingRecord(KEY_BACKEND_URL, url.trim()))
    }

    suspend fun offlineMode(): Boolean = dao.get(KEY_OFFLINE_MODE) == "1"

    suspend fun setOfflineMode(enabled: Boolean) =
        dao.put(AppSettingRecord(KEY_OFFLINE_MODE, if (enabled) "1" else "0"))

    /** 界面用：是否真的会走网络。后端没配或用户开了离线模式都属于纯本地。 */
    suspend fun isPurelyLocal(): Boolean = offlineMode() || backendBaseUrl() == null

    // ---- 学期基准 ----

    suspend fun termCalendar(): TermCalendar? {
        val start = dao.get(KEY_TERM_START)?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return null
        val weeks = dao.get(KEY_TERM_WEEKS)?.toIntOrNull() ?: return null
        return TermCalendar(firstWeekMonday = start, totalWeeks = weeks)
    }

    suspend fun setTermCalendar(term: TermCalendar) {
        dao.put(AppSettingRecord(KEY_TERM_START, term.firstWeekMonday.toString()))
        dao.put(AppSettingRecord(KEY_TERM_WEEKS, term.totalWeeks.toString()))
    }

    // ---- 提醒与预算 ----

    suspend fun defaultReminderOwner(): ReminderOwner {
        val raw = dao.get(KEY_REMINDER_OWNER) ?: return ReminderOwner.APP_LOCAL
        return runCatching { ReminderOwner.valueOf(raw) }.getOrDefault(ReminderOwner.APP_LOCAL)
    }

    suspend fun setDefaultReminderOwner(owner: ReminderOwner) =
        dao.put(AppSettingRecord(KEY_REMINDER_OWNER, owner.name))

    suspend fun budgetPolicy(): BudgetPolicy {
        val dailyLimit = dao.get(KEY_BUDGET_DAILY_LIMIT)?.toIntOrNull() ?: 3
        val minInterval = dao.get(KEY_BUDGET_MIN_INTERVAL)?.toLongOrNull() ?: 90L
        return BudgetPolicy(
            dailyLimit = dailyLimit.coerceAtLeast(0),
            minIntervalMinutes = minInterval.coerceAtLeast(0),
        )
    }

    suspend fun setBudgetPolicy(policy: BudgetPolicy) {
        dao.put(AppSettingRecord(KEY_BUDGET_DAILY_LIMIT, policy.dailyLimit.toString()))
        dao.put(AppSettingRecord(KEY_BUDGET_MIN_INTERVAL, policy.minIntervalMinutes.toString()))
    }

    suspend fun quietHours(): Pair<LocalTime, LocalTime> {
        val start = dao.get(KEY_QUIET_START)?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
            ?: LocalTime.of(22, 30)
        val end = dao.get(KEY_QUIET_END)?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
            ?: LocalTime.of(8, 0)
        return start to end
    }

    suspend fun setQuietHours(start: LocalTime, end: LocalTime) {
        dao.put(AppSettingRecord(KEY_QUIET_START, start.toString()))
        dao.put(AppSettingRecord(KEY_QUIET_END, end.toString()))
    }

    /** 位置规则总开关。默认关闭：位置是敏感能力，必须由用户显式开启。 */
    suspend fun locationRulesEnabled(): Boolean = dao.get(KEY_LOCATION_RULES) == "1"

    suspend fun setLocationRulesEnabled(enabled: Boolean) =
        dao.put(AppSettingRecord(KEY_LOCATION_RULES, if (enabled) "1" else "0"))

    /** 最近一次同步游标的时间，用于设置页显示「上次同步」。 */
    suspend fun lastSyncAt(): String? = dao.get(KEY_LAST_SYNC_AT)

    suspend fun setLastSyncAt(value: String) = dao.put(AppSettingRecord(KEY_LAST_SYNC_AT, value))

    fun observeOfflineMode(): Flow<Boolean> = dao.observe(KEY_OFFLINE_MODE).map { it == "1" }

    fun observeBackendUrl(): Flow<String?> = dao.observe(KEY_BACKEND_URL)

    suspend fun all(): Map<String, String> = dao.listAll().associate { it.key to it.value }

    companion object {
        const val KEY_BACKEND_URL = "backend.base_url"
        const val KEY_OFFLINE_MODE = "runtime.offline_mode"
        const val KEY_TERM_START = "term.first_week_monday"
        const val KEY_TERM_WEEKS = "term.total_weeks"
        const val KEY_REMINDER_OWNER = "reminder.default_owner"
        const val KEY_BUDGET_DAILY_LIMIT = "budget.daily_limit"
        const val KEY_BUDGET_MIN_INTERVAL = "budget.min_interval_minutes"
        const val KEY_QUIET_START = "budget.quiet_start"
        const val KEY_QUIET_END = "budget.quiet_end"
        const val KEY_LOCATION_RULES = "location.rules_enabled"
        const val KEY_LAST_SYNC_AT = "sync.last_at"
    }
}
