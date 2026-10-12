package com.daycue.android.platform.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.daycue.android.domain.proactive.ProactiveInteraction
import com.daycue.android.domain.proactive.ProactiveInteractionReceipt
import com.daycue.android.platform.platformDependenciesOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * 主动通知的交互回执。
 *
 * 点开与划掉都要回写账本：
 * - 不回写，「用户看没看到」无从判断；
 * - 更实际的是，账本会一直停在 pending，继续占着当天的打扰额度——用户会觉得自己被莫名其妙地限流。
 *
 * 点击后顺带把 App 拉到前台；拉起失败（例如系统限制后台启动 Activity）只记日志，
 * 因为回执已经落库，功能本身没有丢。
 */
class ProactiveReceiptReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val dedupeKey = intent.getStringExtra(ReminderAlarmReceiver.EXTRA_DEDUPE_KEY) ?: run {
            Log.w(TAG, "回执缺少 dedupeKey，无法归属到账本行，已忽略")
            return
        }
        val interaction = when (intent.action) {
            ACTION_DISMISSED -> ProactiveInteraction.DISMISSED
            else -> ProactiveInteraction.OPENED
        }
        val appContext = context.applicationContext
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val dependencies = appContext.platformDependenciesOrNull()
                if (dependencies == null) {
                    Log.e(TAG, "AppContainer 尚不可用，回执被丢弃：" + dedupeKey)
                    return@launch
                }
                val outcome = dependencies.receiptService.apply(
                    ProactiveInteractionReceipt(
                        dedupeKey = dedupeKey,
                        interaction = interaction,
                        at = dependencies.timeSource.now(),
                    ),
                )
                Log.i(TAG, "回执已处理：" + dedupeKey + " applied=" + outcome.applied + " state=" + outcome.state)
                if (interaction == ProactiveInteraction.OPENED) openApp(appContext)
            } catch (e: Throwable) {
                Log.w(TAG, "处理主动通知回执失败：" + dedupeKey, e)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun openApp(context: Context) {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(launchIntent) }
            .onFailure { Log.w(TAG, "点击通知后拉起界面失败（回执已落库）", it) }
    }

    companion object {
        const val TAG = "ProactiveReceipt"
        const val ACTION_OPENED = "com.daycue.android.action.PROACTIVE_OPENED"
        const val ACTION_DISMISSED = "com.daycue.android.action.PROACTIVE_DISMISSED"
    }
}
