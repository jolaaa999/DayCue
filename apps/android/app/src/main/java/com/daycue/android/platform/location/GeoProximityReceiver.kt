package com.daycue.android.platform.location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.util.Log
import com.daycue.android.platform.platformDependenciesOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.ZoneId

/**
 * 系统围栏广播的落地。
 *
 * class 名与 PendingIntent 里写死的类名必须一致，否则围栏跨越后找不到接收者，
 * 用户永远收不到进入 / 离开提醒，而且没有任何报错。
 *
 * 用 goAsync()：处理要读数据库、写账本、排通知，属于 IO，而 onReceive 返回后进程随时可能被杀；
 * goAsync() 把「还没做完」告诉系统，做完再 finish()。
 */
class GeoProximityReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val placeId = intent.getStringExtra(EXTRA_PLACE_ID) ?: run {
            // 没有 placeId 就无法归属，宁可什么都不做，也不要按错误的地点触发。
            Log.w(TAG, "围栏广播缺少 placeId，已忽略")
            return
        }
        if (!intent.hasExtra(LocationManager.KEY_PROXIMITY_ENTERING)) {
            // 方向未知时既不能当进入也不能当离开：猜错会产生一条彻底的假提醒。
            Log.w(TAG, "围栏广播没有方向标志（KEY_PROXIMITY_ENTERING），已忽略：" + placeId)
            return
        }
        val entering = intent.getBooleanExtra(LocationManager.KEY_PROXIMITY_ENTERING, false)

        val appContext = context.applicationContext
        val pendingResult = goAsync()
        // 自己开一个作用域而不是用 GlobalScope：生命周期与这次广播一一对应，做完即结束。
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val dependencies = appContext.platformDependenciesOrNull()
                if (dependencies == null) {
                    Log.e(TAG, "AppContainer 尚不可用，围栏事件被丢弃：" + placeId)
                    return@launch
                }
                val handling = dependencies.geoCoordinator.onProximityTransition(
                    placeId = placeId,
                    entering = entering,
                    zone = ZoneId.systemDefault(),
                )
                Log.i(
                    TAG,
                    "围栏事件已处理：place=" + placeId + " entering=" + entering +
                        " accepted=" + handling.accepted,
                )
            } catch (e: Throwable) {
                // 处理失败不能让进程崩：下一次围栏事件或界面恢复还会再来一次。
                Log.w(TAG, "处理围栏广播失败：" + placeId, e)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val TAG = "GeoProximity"

        /** 显式 action：PendingIntent 的匹配只看 action/component，加上它能让取消更可靠。 */
        const val ACTION_PROXIMITY = "com.daycue.android.action.GEO_PROXIMITY"

        const val EXTRA_PLACE_ID = "daycue.extra.place_id"
    }
}
