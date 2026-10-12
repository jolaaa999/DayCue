package com.daycue.android.platform.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 到点提醒的落地点。
 *
 * class 名与 AndroidManifest.xml 里声明的 .platform.notify.ReminderAlarmReceiver 必须完全一致，
 * 否则 AlarmManager 到点后找不到接收者，提醒会静默丢失。
 *
 * 这里只做一件事：发通知。写数据库不做——BroadcastReceiver 只有约 10 秒预算，
 * 而且「用户是否已经看到」应该由界面上的回复/跳过动作决定，不能靠一条通知到达就替用户记账。
 */
class ReminderAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val key = intent.getStringExtra(EXTRA_KEY) ?: run {
            // 没有 key 就无法定位是谁的提醒，宁可什么都不发，也不要弹一条无法归属的通知。
            return
        }
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifEmpty { "DayCue" }
        val body = intent.getStringExtra(EXTRA_BODY).orEmpty()
        val followUp = intent.getBooleanExtra(EXTRA_FOLLOW_UP, false)
        val channelId = intent.getStringExtra(EXTRA_CHANNEL)
            ?: if (followUp) NotificationChannels.FOLLOW_UP else NotificationChannels.REMINDER

        postNotification(
            context = context.applicationContext,
            channelId = channelId,
            notificationId = notificationId(key),
            title = title,
            body = body,
        )
    }

    companion object {
        /** 显式 action：PendingIntent 的匹配只看 action/component，加上它能让取消更可靠。 */
        const val ACTION_REMIND = "com.daycue.android.action.REMIND"

        const val EXTRA_KEY = "daycue.extra.key"
        const val EXTRA_TITLE = "daycue.extra.title"
        const val EXTRA_BODY = "daycue.extra.body"
        const val EXTRA_CHANNEL = "daycue.extra.channel"
        const val EXTRA_FOLLOW_UP = "daycue.extra.follow_up"
    }
}
