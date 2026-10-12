package com.daycue.android.platform.notify

import com.daycue.android.domain.location.GeoNotificationRequest
import com.daycue.android.domain.location.GeoNotificationScheduleResult
import com.daycue.android.domain.location.GeoNotificationScheduler

/**
 * 地点提醒的通知安排器，把领域层的安排请求接到系统 AlarmManager 上。
 *
 * 不做任何「假装排上了」的处理：排程器返回 false 时如实回报 NotScheduled，
 * 编排层会把账本落成 cancelled 并写明原因，用户查得到「为什么没提醒」。
 */
class AndroidGeoNotifier(private val scheduler: ReminderScheduler) : GeoNotificationScheduler {

    override suspend fun schedule(request: GeoNotificationRequest): GeoNotificationScheduleResult {
        val scheduled = scheduler.scheduleProactiveNotification(
            key = request.identifier,
            at = request.fireAt,
            title = request.title,
            body = request.body.orEmpty(),
            dedupeKey = request.dedupeKey,
        )
        return if (scheduled) {
            GeoNotificationScheduleResult.Scheduled(request.identifier, request.fireAt)
        } else {
            GeoNotificationScheduleResult.NotScheduled(
                "通知权限未开启或系统拒绝创建提醒，本次地点提醒没有安排。",
            )
        }
    }

    override suspend fun cancel(identifier: String) {
        scheduler.cancelProactiveNotification(identifier)
    }
}
