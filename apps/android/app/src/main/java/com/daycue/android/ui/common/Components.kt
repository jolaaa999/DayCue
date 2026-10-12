package com.daycue.android.ui.common

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * 页面外壳：标题栏 + 可选返回 + 可选动作。
 *
 * 为什么统一成一个组件：返回入口、标题样式、内容内边距如果各页自己写，
 * 「有没有返回键」这种东西迟早会不一致，用户会以为页面卡住了。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DayCueScreen(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (onBack != null) {
                        TextButton(onClick = onBack) { Text("返回") }
                    }
                },
                actions = actions,
            )
        },
        content = content,
    )
}

/**
 * 空态：标题 + 说明 + 可选动作。
 *
 * 每一块列表都必须在没有数据时给出「为什么这里是空的」，
 * 否则用户分不清「还没记录」和「加载失败」。
 */
@Composable
fun EmptyState(
    title: String,
    description: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        Text(
            text = description,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onAction) { Text(actionLabel) }
        }
    }
}

/** 分区标题。副标题用来写清这一块的口径（例如「按用户时区统计」）。 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    trailing: @Composable (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 16.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        trailing?.invoke()
    }
}

/**
 * 外部写入状态标签。
 *
 * needsAttention 的状态（等待授权 / 等待写入 / 失败 / 未知 / 待对账）必须用警示色：
 * 这些状态一旦被渲染成和「已写入」一样的样式，就等于在界面上虚报同步成功，
 * 而这正是 ExternalWriteState 这条状态机存在的原因。
 */
@Composable
fun WriteStateBadge(state: ExternalWriteState, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val containerColor = if (state.needsAttention) colors.errorContainer else colors.secondaryContainer
    val contentColor = if (state.needsAttention) colors.onErrorContainer else colors.onSecondaryContainer
    Surface(color = containerColor, contentColor = contentColor, shape = MaterialTheme.shapes.small, modifier = modifier) {
        Text(
            text = state.displayName,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

/** 一行「标签 : 值」，用于设置页与详情页的字段展示。 */
@Composable
fun KeyValueLine(label: String, value: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(text = value, style = MaterialTheme.typography.bodyMedium)
    }
}

/** 提示条：正常提示用容器色，错误用错误色。真实错误信息必须原样显示，不能替换成「操作失败」。 */
@Composable
fun MessageCard(text: String, modifier: Modifier = Modifier, isError: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    Surface(
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
        color = if (isError) colors.errorContainer else colors.primaryContainer,
        contentColor = if (isError) colors.onErrorContainer else colors.onPrimaryContainer,
        shape = MaterialTheme.shapes.medium,
    ) {
        Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(10.dp))
    }
}

// ---------------- 时间展示 ----------------
// 界面对时间的唯一出口。这里只做「转发 + 补默认时区」，
// 不允许出现任何 DateTimeFormatter、SimpleDateFormat 或字符串拼接：
// 一旦界面自己拼格式，「日期型截止日被补成 00:00」这类错误就会从领域层漏回来。

/** 记录里存的是 IANA 时区名，脏数据不应该让页面崩溃，所以解析失败退回设备时区。 */
fun zoneOf(name: String?): ZoneId {
    if (name.isNullOrBlank()) return ZoneId.systemDefault()
    return runCatching { ZoneId.of(name) }.getOrDefault(ZoneId.systemDefault())
}

fun formatDateTime(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DayCueTime.displayDateTime(instant, zone)

fun formatDate(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DayCueTime.displayDate(instant, zone)

/**
 * 任务的截止时间文案。
 *
 * date 型只显示日期：DayCueTime 已经保证 due_utc 为空，界面同样不许替它补一个时刻，
 * 否则「周五之前交」会显示成「周五 00:00」。
 */
fun formatTaskDue(task: TaskRecord): String {
    val zone = zoneOf(task.timezone)
    return when (task.dueKind) {
        DueKind.NONE -> "无截止时间"
        DueKind.DATE -> task.dueLocal
            ?.let { raw -> DayCueTime.parseLocalDateOrNull(raw)?.let { date -> DayCueTime.localDateString(date) } }
            ?: "截止日缺失"
        DueKind.DATETIME -> task.dueUtc
            ?.let { DayCueTime.displayDateTime(it, zone) }
            ?: "截止时刻缺失"
    }
}

/** 提醒时刻文案；没有提醒时刻时返回 null，由调用方决定要不要显示「未设提醒」。 */
fun formatTaskReminder(task: TaskRecord): String? =
    task.remindUtc?.let { DayCueTime.displayDateTime(it, zoneOf(task.timezone)) }

/**
 * 本地时刻文案。
 *
 * 这里刻意用 java.time 自带的 ISO 输出（08:00）而不是自己拼 HH:mm：
 * 课表字段本身就是 LocalTime，没有绝对时刻，DayCueTime 里也就没有对应的格式化入口。
 */
fun formatLocalTime(time: LocalTime): String = time.toString()
