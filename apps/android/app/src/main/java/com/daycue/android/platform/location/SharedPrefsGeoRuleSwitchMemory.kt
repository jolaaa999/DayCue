package com.daycue.android.platform.location

import android.content.Context
import com.daycue.android.domain.location.GeoRuleSwitchMemory

/**
 * 「用户想要哪些规则开着」的记忆，落在 SharedPreferences。
 *
 * 不用数据库：它只是运行时的开关记忆，丢了最多让用户重新开一次规则；
 * 为它加一张表、写一次迁移，代价远大于收益。
 */
class SharedPrefsGeoRuleSwitchMemory(context: Context) : GeoRuleSwitchMemory {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(): Set<String> = prefs.getStringSet(KEY_ENABLED, emptySet())?.toSet() ?: emptySet()

    override fun write(ruleIds: Set<String>) {
        prefs.edit().putStringSet(KEY_ENABLED, ruleIds).apply()
    }

    private companion object {
        const val PREFS_NAME = "daycue_geo_switch_memory"
        const val KEY_ENABLED = "enabled_rule_ids"
    }
}
