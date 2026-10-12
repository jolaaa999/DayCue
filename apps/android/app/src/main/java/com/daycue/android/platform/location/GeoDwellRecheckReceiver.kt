package com.daycue.android.platform.location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.daycue.android.platform.platformDependenciesOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.ZoneId

/**
 * 停留规则的到点复查。
 *
 * 为什么需要它：围栏广播只在跨越时来一次，「已经待了 30 分钟」不是一个系统事件。
 * 没有这条复查，minDwellSeconds > 0 的规则会被求值、会被记录成「还没到点」，
 * 然后永远不会再被想起——那正是「写了类但没有调用方」的另一种形态。
 */
class GeoDwellRecheckReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val placeId = intent.getStringExtra(EXTRA_PLACE_ID) ?: return
        val appContext = context.applicationContext
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val dependencies = appContext.platformDependenciesOrNull()
                if (dependencies == null) {
                    Log.e(TAG, "AppContainer 尚不可用，停留复查被丢弃：" + placeId)
                    return@launch
                }
                val handling = dependencies.geoCoordinator.onDwellRecheck(placeId, ZoneId.systemDefault())
                Log.i(TAG, "停留复查已处理：place=" + placeId + " accepted=" + handling.accepted)
            } catch (e: Throwable) {
                Log.w(TAG, "处理停留复查失败：" + placeId, e)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val TAG = "GeoDwellRecheck"
        const val ACTION_DWELL_RECHECK = "com.daycue.android.action.GEO_DWELL_RECHECK"
        const val EXTRA_PLACE_ID = "daycue.extra.place_id"
    }
}
