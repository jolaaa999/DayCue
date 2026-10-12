package com.daycue.android.platform.outbox

import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.platform.OutboxExecution

/**
 * 单个操作类型的实际执行动作。
 *
 * 返回 OutboxExecution 而不是布尔：执行者比状态机更清楚这次失败是
 * 「稍后可以再来」「确定没写成」还是「不知道写没写」，分类必须由它给出。
 */
fun interface OutboxOperationHandler {
    suspend fun execute(operation: OutboxOperationRecord): OutboxExecution
}
