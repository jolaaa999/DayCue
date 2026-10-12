package com.daycue.android.data.repository

import java.time.Instant

/**
 * 时间的注入点。
 *
 * 领域层一律要求把「现在」当参数传进来（见 DayCueTime 的注释），
 * 仓储层需要「现在」时则从注入的 TimeSource 取——这样后台作业、界面和测试
 * 三条路径都能用各自的时间基准，而不会有人偷偷调用 Instant.now()。
 */
fun interface TimeSource {
    fun now(): Instant
}

object SystemTimeSource : TimeSource {
    override fun now(): Instant = Instant.now()
}
