package com.daycue.android.platform.notify

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.daycue.android.R
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.permission.PermissionCenter
import java.time.Instant

/** 平台层共用的日志标签，便于在 logcat 里一次过滤出所有提醒相关问题。 */
internal const val NOTIFY_LOG_TAG = "DayCueNotify"

/**
 * 通知渠道。
 *
 * 渠道 id 是写进用户设备的稳定值，不能改名；名称与说明必须来自 strings.xml，
 * 因为后台组件拿不到 Compose 的资源上下文。
 */
object NotificationChannels {

    const val REMINDER = "reminder"
    const val FOLLOW_UP = "follow_up"
    const val SYSTEM = "system"

    fun ensure(context: Context) {
        val appContext = context.applicationContext
        val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        // 重要性分级不是装饰：任务提醒是用户自己设定的时刻，必须能弹出来（HIGH）；
        // 课后追问与系统消息属于「可以等一会看」，用 DEFAULT，避免和真正的闹钟抢注意力。
        val reminder = NotificationChannel(
            REMINDER,
            appContext.getString(R.string.notify_channel_reminder_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = appContext.getString(R.string.notify_channel_reminder_desc)
        }
        val followUp = NotificationChannel(
            FOLLOW_UP,
            appContext.getString(R.string.notify_channel_follow_up_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = appContext.getString(R.string.notify_channel_follow_up_desc)
        }
        val system = NotificationChannel(
            SYSTEM,
            appContext.getString(R.string.notify_channel_system_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = appContext.getString(R.string.notify_channel_system_desc)
        }
        manager.createNotificationChannels(listOf(reminder, followUp, system))
    }
}

/**
 * 本地提醒的排程器。
 *
 * 精确到点一律走 AlarmManager：WorkManager 只保证「最终会跑」，用它冒充到点提醒会违反
 * 「不许用 WorkManager 假装准点」这条设计约束。精确闹钟不可用时按系统规则降级为
 * 最长 10 分钟的窗口，并在通知正文里如实告诉用户，而不是假装准点。
 */
class ReminderScheduler(private val context: Context) {

    private val appContext: Context = context.applicationContext

    /**
     * 用户明确设定时刻的任务提醒。
     *
     * [exact] 的语义是「这条提醒要求准点」：为 true 且系统给了精确闹钟能力时用 setExactAndAllowWhileIdle，
     * 否则退回 10 分钟窗口。无论走哪条路，通知正文都会说明是否发生了降级。
     */
    fun scheduleLocalAlarm(taskId: String, at: Instant, exact: Boolean, title: String, body: String) {
        // 权限判断必须发生在安排之前：没有通知权限时闹钟响了也只会静默消失，
        // 提前拦下来能让界面把「这条提醒不会弹」如实显示出来（安排也省掉了无意义的唤醒）。
        if (!PermissionCenter.hasNotifications(appContext)) {
            Log.w(NOTIFY_LOG_TAG, "通知权限未开启，跳过任务提醒安排：taskId=" + taskId)
            return
        }
        arm(
            key = taskKey(taskId),
            at = at,
            exact = exact,
            channelId = NotificationChannels.REMINDER,
            title = title,
            body = body,
            followUp = false,
        )
    }

    fun cancelLocalAlarm(taskId: String) {
        cancel(taskKey(taskId))
    }

    /** 课后追问。追问本身允许一个窗口，所以默认不要求精确能力。 */
    fun scheduleFollowUp(followUpId: String, at: Instant, courseName: String, exact: Boolean) {
        if (!PermissionCenter.hasNotifications(appContext)) {
            Log.w(NOTIFY_LOG_TAG, "通知权限未开启，跳过课后追问安排：followUpId=" + followUpId)
            return
        }
        arm(
            key = followUpKey(followUpId),
            at = at,
            exact = exact,
            channelId = NotificationChannels.FOLLOW_UP,
            title = courseName,
            body = "刚上完的这门课，有什么想先记下来的吗？",
            followUp = true,
        )
    }

    fun cancelFollowUp(followUpId: String) {
        cancel(followUpKey(followUpId))
    }

    /** 系统消息（同步失败、权限降级）。这类消息没有到点语义，直接发。 */
    fun notifySystem(title: String, body: String) {
        postNotification(
            context = appContext,
            channelId = NotificationChannels.SYSTEM,
            notificationId = notificationId("system:" + title),
            title = title,
            body = body,
        )
    }

    private fun arm(key: String, at: Instant, exact: Boolean, channelId: String, title: String, body: String, followUp: Boolean) {
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: run {
            Log.w(NOTIFY_LOG_TAG, "本机没有 AlarmManager，无法安排提醒：" + key)
            return
        }

        val canExact = CapabilityProbe.exactAlarmAllowed(appContext)
        val useExact = exact && canExact
        val triggerAtMillis = at.toEpochMilli()

        // 精确闹钟不可用时只有两种诚实的选择：不安排，或安排一个明确不精确的窗口。
        // 这里选后者（10 分钟），因为「晚几分钟」远好于「完全收不到」。
        val showDegradedNotice = !useExact && (exact || channelId == NotificationChannels.REMINDER)
        val text = if (showDegradedNotice) body + "\n" + appContext.getString(R.string.notify_exact_alarm_degraded) else body

        val pendingIntent = buildPendingIntent(key, channelId, title, text, followUp, PendingIntent.FLAG_UPDATE_CURRENT)
        try {
            if (useExact) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
            } else {
                alarmManager.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMillis, INEXACT_WINDOW_MILLIS, pendingIntent)
            }
        } catch (e: SecurityException) {
            // 用户在最后一刻撤销了精确闹钟授权，或系统策略变化：降级而不是让调用方崩溃。
            Log.w(NOTIFY_LOG_TAG, "安排精确闹钟被系统拒绝，降级为窗口提醒：" + key, e)
            alarmManager.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMillis, INEXACT_WINDOW_MILLIS, pendingIntent)
        }
    }

    private fun cancel(key: String) {
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        // FLAG_NO_CREATE：取消不存在的闹钟不该顺手创建一个 PendingIntent。
        val pendingIntent = buildPendingIntent(
            key = key,
            channelId = NotificationChannels.REMINDER,
            title = "",
            body = "",
            followUp = false,
            flags = PendingIntent.FLAG_NO_CREATE,
        ) ?: return
        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()
    }

    private fun buildPendingIntent(
        key: String,
        channelId: String,
        title: String,
        body: String,
        followUp: Boolean,
        flags: Int,
    ): PendingIntent? {
        val intent = Intent(appContext, ReminderAlarmReceiver::class.java).apply {
            action = ReminderAlarmReceiver.ACTION_REMIND
            putExtra(ReminderAlarmReceiver.EXTRA_KEY, key)
            putExtra(ReminderAlarmReceiver.EXTRA_TITLE, title)
            putExtra(ReminderAlarmReceiver.EXTRA_BODY, body)
            putExtra(ReminderAlarmReceiver.EXTRA_CHANNEL, channelId)
            putExtra(ReminderAlarmReceiver.EXTRA_FOLLOW_UP, followUp)
        }
        // request code 用 key 的稳定哈希，绝不用随机数：同一个 taskId 反复安排必须命中同一个
        // PendingIntent，否则取消时找不到旧的那个，用户会收到重复提醒。
        return PendingIntent.getBroadcast(
            appContext,
            notificationId(key),
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun taskKey(taskId: String) = "task:" + taskId

    private fun followUpKey(followUpId: String) = "follow_up:" + followUpId
}

/** PendingIntent 的 request code 与通知 id 共用同一个稳定哈希（String.hashCode 的算法由语言规定，不会随进程变化）。 */
internal fun notificationId(key: String): Int = key.hashCode() and 0x7FFFFFFF

/** 不精确提醒允许的窗口长度：10 分钟是系统对 setWindow 的常见容忍区间，也是「晚一点但仍有用」的上限。 */
internal const val INEXACT_WINDOW_MILLIS = 10L * 60L * 1000L

/**
 * 真正把通知发出去的地方。放在文件级函数里，是因为 BroadcastReceiver 与 ReminderScheduler
 * 都要用它，而 receiver 不该为了发一条通知再构造一个排程器。
 */
internal fun postNotification(context: Context, channelId: String, notificationId: Int, title: String, body: String) {
    val appContext = context.applicationContext
    NotificationChannels.ensure(appContext)
    if (!PermissionCenter.hasNotifications(appContext)) {
        Log.w(NOTIFY_LOG_TAG, "通知权限未开启，通知未发出：" + title)
        return
    }

    val builder = NotificationCompat.Builder(appContext, channelId)
        // 小图标必须来自 res/drawable；本工程暂时只有 ic_launcher_foreground 可用，
        // 等有了专门的通知图标再替换（不新造资源是为了不动平台层以外的文件）。
        .setSmallIcon(R.drawable.ic_launcher_foreground)
        .setContentTitle(title)
        .setContentText(body)
        .setStyle(NotificationCompat.BigTextStyle().bigText(body))
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)

    // 点击通知回到主界面。用 getLaunchIntentForPackage 而不是写死 MainActivity：
    // 平台层不该依赖界面层的类名，启动入口变化时这里也不需要改。
    val launchIntent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
    if (launchIntent != null) {
        builder.setContentIntent(
            PendingIntent.getActivity(
                appContext,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
    }

    try {
        NotificationManagerCompat.from(appContext).notify(notificationId, builder.build())
    } catch (e: SecurityException) {
        // 13 以上的权限可能在运行中被撤销，这里吞掉并留日志，不让后台组件崩掉。
        Log.w(NOTIFY_LOG_TAG, "发送通知被系统拒绝：" + title, e)
    }
}
