package com.daycue.android.ui.today

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.MailOutline
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.ui.DayCueRoutes
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.DayCueIcons
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyStateGlyph
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.MiniTag
import com.daycue.android.ui.common.MiniTagTone
import com.daycue.android.ui.common.NoticeRow
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.formatTaskScheduleToday
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId

/**
 * 今天页。
 *
 * 排布原则（与上一版的差别就在这里）：
 * 1. 顶部先给「现在就能用」的东西——记录入口，语音优先。用户打开 App 十次有九次是为了记一句。
 * 2. 有内容的分区才出现，且按重要程度排：行程 → 待办 → 追问 → 异常 → 记录摘要。
 * 3. 全空时不再铺开六块空态，只给一句说明 + 一行入口。
 * 4. 「今天页只做汇总，不做任何写入」这类实现说明一律不出现：用户要的是结果，不是架构。
 */
@Composable
fun TodayScreen(
    onOpenTasks: () -> Unit,
    onOpenSchedule: () -> Unit,
    onOpenFollowUp: () -> Unit,
    onOpenCapture: (String) -> Unit,
    onOpenRecords: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    val container = rememberContainer()
    val viewModel: TodayViewModel = viewModel(factory = TodayViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    TodayContent(
        state = state,
        onRefresh = viewModel::refresh,
        onCompleteTask = viewModel::completeTask,
        onOpenTasks = onOpenTasks,
        onOpenSchedule = onOpenSchedule,
        onOpenFollowUp = onOpenFollowUp,
        onOpenCapture = onOpenCapture,
        onOpenRecords = onOpenRecords,
        onOpenSettings = onOpenSettings,
        onOpenNote = onOpenNote,
    )
}

/**
 * 今天页的纯展示部分（状态由外部给，不自己取数据）。
 *
 * 拆成两部分是为了让 Compose Preview 与调试画廊能在不建数据库、不连后端的前提下
 * 渲染出「有课有待办」「同步异常」这些平时很难凑出来的状态。
 */
@Composable
fun TodayContent(
    state: TodayUiState,
    onRefresh: () -> Unit,
    onCompleteTask: (String) -> Unit,
    onOpenTasks: () -> Unit,
    onOpenSchedule: () -> Unit,
    onOpenFollowUp: () -> Unit,
    onOpenCapture: (String) -> Unit,
    onOpenRecords: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    DayCueScreen(title = "今天", showTopBar = false) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(
                start = DayCueSpacing.Screen,
                end = DayCueSpacing.Screen,
                top = DayCueSpacing.Small,
                bottom = DayCueSpacing.XXLarge,
            ),
        ) {
            item {
                TodayHeader(
                    now = state.now,
                    onRefresh = onRefresh,
                    onOpenSettings = onOpenSettings,
                )
            }

            item {
                Spacer(Modifier.height(DayCueSpacing.Large))
                QuickCaptureBlock(onOpenCapture = onOpenCapture)
            }

            state.notice?.let { notice ->
                item {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    MessageCard(text = notice, isError = true)
                }
            }

            // 同步异常：只在真有问题时出现，压成一行，点进去看具体哪几条。
            if (state.syncIssues.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    NoticeRow(
                        text = state.syncIssues.size.toString() + " 项同步没有完成",
                        actionLabel = "查看",
                        onAction = onOpenTasks,
                    )
                }
            }

            val course = state.nextCourse
            if (course != null) {
                item { SectionHeader(title = "接下来") }
                item { CourseCard(course = course, now = state.now) }
            } else if (state.laterCourseHint != null) {
                item {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    NoticeRow(
                        text = "今天没有课了 · 下一次 " + state.laterCourseHint,
                        actionLabel = "课表",
                        onAction = onOpenSchedule,
                        tone = MiniTagTone.Neutral,
                    )
                }
            }

            if (state.dueTodayTasks.isNotEmpty()) {
                item {
                    SectionHeader(
                        title = "今天到期",
                        subtitle = state.dueTodayTasks.size.toString() + " 条待办",
                    )
                }
                items(state.dueTodayTasks, key = { it.id }) { task ->
                    TodayTaskRow(task = task, now = state.now ?: Instant.now(), onComplete = { onCompleteTask(task.id) })
                }
            }

            if (state.pendingFollowUps.isNotEmpty()) {
                item {
                    SectionHeader(
                        title = "等你回复",
                        subtitle = "课后追问还没回",
                        trailing = { SmallLink("去回复", onOpenFollowUp) },
                    )
                }
                items(state.pendingFollowUps, key = { it.followUpId }) { item ->
                    // 整行可点：原来只有页头的「去回复」能点，行本身看着像纯文字，用户不会去试。
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = MinTouchTarget)
                            .clickable(onClick = onOpenFollowUp)
                            .padding(vertical = DayCueSpacing.Small),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(item.courseName, style = MaterialTheme.typography.bodyLarge)
                            Text(
                                text = item.state.displayName + " · " + DayCueTime.displayClock(item.at, ZoneId.systemDefault()),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Icon(
                            imageVector = Icons.Outlined.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }

            if (state.pendingCaptures.isNotEmpty()) {
                item {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    NoticeRow(
                        text = state.pendingCaptures.size.toString() + " 条记录还在处理",
                        actionLabel = "去看",
                        onAction = onOpenRecords,
                        tone = MiniTagTone.Neutral,
                    )
                }
            }

            if (state.todayNotes.isNotEmpty()) {
                item {
                    SectionHeader(
                        title = "今天记下的",
                        trailing = { SmallLink("全部记录", onOpenRecords) },
                    )
                }
                // 摘要只放最近三条：这一块是回看用的，不是列表页，给全部会让今天页重新变成长列表。
                items(state.todayNotes.take(3), key = { it.id }) { note ->
                    TodayNoteRow(
                        note = note,
                        now = state.now,
                        modifier = Modifier.animateItem(),
                        onClick = { onOpenNote(note.id) },
                    )
                }
            }

            if (!state.hasContent) {
                item {
                    // 空态拆成「标题 + 一句说明」并限宽居中：原来一整段长句顶在左边缘，
                    // 大字号下会折成三四行且左右参差，看起来像没排完版。
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = DayCueSpacing.Section),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        EmptyStateGlyph(Icons.Outlined.DateRange)
                        Spacer(Modifier.height(DayCueSpacing.Medium))
                        Text("今天还没有安排", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(DayCueSpacing.XSmall + 2.dp))
                        Text(
                            text = "导入课表后这里会排出课程；写下的事也会出现在这里。",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.widthIn(max = 270.dp),
                        )
                    }
                }
            }

            item {
                Spacer(Modifier.height(DayCueSpacing.Section))
                QuickLinksRow(
                    onOpenSchedule = onOpenSchedule,
                    onOpenTasks = onOpenTasks,
                    onOpenFollowUp = onOpenFollowUp,
                )
            }
        }
    }
}

/**
 * 紧凑页头：问候 + 日期。
 *
 * 不显示「数据来自哪个表」「只做汇总」之类的说明，只回答「今天是什么日子、几点」。
 */
@Composable
private fun TodayHeader(now: Instant?, onRefresh: () -> Unit, onOpenSettings: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val greeting = now?.let { greetingFor(DayCueTime.localTimeOf(it, zone).hour) } ?: "今天"
    val dateLine = now?.let {
        DayCueTime.displayMonthDayWeekday(it, zone) + " · " + DayCueTime.displayClock(it, zone)
    } ?: "正在读取今天的安排"

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(greeting, style = MaterialTheme.typography.headlineSmall)
            Text(
                text = dateLine,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
        IconButton(onClick = onRefresh) {
            Icon(
                imageVector = Icons.Outlined.Refresh,
                contentDescription = "刷新",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onOpenSettings) {
            Icon(
                imageVector = Icons.Outlined.Settings,
                contentDescription = "设置",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * 快速记录区。
 *
 * 语音是主操作（圆形实色按钮），文字与拍照是次操作。
 * 三个入口都走同一套捕获流程（先落库、再解析），这里只决定「进去之后先摆哪种输入」。
 */
@Composable
private fun QuickCaptureBlock(onOpenCapture: (String) -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = MaterialTheme.shapes.large,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
    ) {
        Column(Modifier.padding(DayCueSpacing.Large)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = MinTouchTarget)
                        .clickable { onOpenCapture(DayCueRoutes.CAPTURE_INTENT_TEXT) },
                ) {
                    Text("记一句", style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = "说一句、写几个字，或拍一页板书",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(DayCueSpacing.Medium))
                // 语音主按钮：56dp 圆形，按下即开始录音（已授权时）。
                Surface(
                    onClick = { onOpenCapture(DayCueRoutes.CAPTURE_INTENT_VOICE) },
                    color = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    shape = CircleShape,
                    modifier = Modifier.size(56.dp),
                ) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = DayCueIcons.Mic,
                            contentDescription = "按住说话",
                            modifier = Modifier.size(26.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(DayCueSpacing.Medium))
            // 两个次级入口等分整行：宽度跟着文字走时，这一排会显得没有对齐过。
            Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Small)) {
                DayCueButton(
                    text = "写文字",
                    onClick = { onOpenCapture(DayCueRoutes.CAPTURE_INTENT_TEXT) },
                    style = DayCueButtonStyle.Tonal,
                    icon = Icons.Outlined.Edit,
                    modifier = Modifier.weight(1f),
                )
                DayCueButton(
                    text = "拍一张",
                    onClick = { onOpenCapture(DayCueRoutes.CAPTURE_INTENT_IMAGE) },
                    style = DayCueButtonStyle.Outline,
                    icon = DayCueIcons.Camera,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** 下一节课（或正在上的课）。状态用标签而不是「状态：正常」这种整行文字。 */
@Composable
private fun CourseCard(course: TodayCourseItem, now: Instant?) {
    val zone = ZoneId.systemDefault()
    // 「还有多久 / 进行中」：课程卡上最想知道的不是 19:00 这个数字，而是「离现在还有多久」。
    val timingTag = now?.let {
        when {
            !it.isBefore(course.startsAt) && it.isBefore(course.endsAt) -> "进行中"
            it.isBefore(course.startsAt) -> {
                val minutes = DayCueTime.minutesBetween(it, course.startsAt)
                when {
                    minutes < 1 -> "马上开始"
                    minutes < 60 -> minutes.toString() + " 分钟后"
                    minutes < 60 * 12 -> (minutes / 60).toString() + " 小时后"
                    else -> null
                }
            }
            else -> null
        }
    }
    // 正在上的课给一层极淡的主色底：这一页只有它能说「现在正在发生什么」，
    // 值得和下面的待办、记录区分开；不是进行中时仍旧用中性容器色。
    val inProgress = timingTag == "进行中"
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = if (inProgress) {
            MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f)
        } else {
            MaterialTheme.colorScheme.surfaceContainer
        },
        shape = MaterialTheme.shapes.medium,
        border = BorderStroke(
            1.dp,
            if (inProgress) {
                MaterialTheme.colorScheme.primary.copy(alpha = 0.35f)
            } else {
                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)
            },
        ),
    ) {
        Column(Modifier.padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium + 2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = course.courseName,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                if (course.status != CourseInstanceStatus.SCHEDULED) {
                    MiniTag(
                        text = course.status.displayName,
                        tone = MiniTagTone.Warning,
                    )
                }
            }
            // 时间和地点排在同一行、时间用强调色：一屏里最常被确认的就是「几点、在哪」，
            // 分成两行反而要来回扫两遍。
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = timeRangeText(course.startsAt, course.endsAt, zone),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
                if (!course.location.isNullOrBlank()) {
                    Text(
                        text = "  ·  " + course.location,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (timingTag != null) {
                    Spacer(Modifier.width(DayCueSpacing.Small))
                    MiniTag(text = timingTag, tone = MiniTagTone.Accent)
                }
            }
        }
    }
}

/** 待办行：勾选即完成。取消本地闹钟由 ViewModel 负责，界面不直接碰提醒。 */
@Composable
private fun TodayTaskRow(
    task: TaskRecord,
    now: Instant,
    modifier: Modifier = Modifier,
    onComplete: () -> Unit,
) {
    // 三段反馈：勾上 → 划掉 → 收起。
    // 直接调 onComplete 的话，行会瞬间消失，用户既没看到「点中了」，也不确定是完成还是被删了。
    var completing by remember(task.id) { mutableStateOf(false) }
    LaunchedEffect(completing) {
        if (completing) {
            delay(420)
            onComplete()
            // 万一这一条没有被移除（比如写库失败），把状态放回去，避免永远停在划掉的样子。
            delay(1200)
            completing = false
        }
    }
    val contentAlpha by animateFloatAsState(
        targetValue = if (completing) 0.4f else 1f,
        animationSpec = tween(durationMillis = 220),
        label = "taskContentAlpha",
    )
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .clickable(enabled = !completing) { completing = true }
            .padding(vertical = DayCueSpacing.Small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 复选框只做视觉呈现，点击由整行接管：命中区域从 20dp 放大到整行。
        Checkbox(
            checked = completing,
            onCheckedChange = { checked -> if (checked && !completing) completing = true },
            enabled = !completing,
        )
        Column(Modifier.weight(1f)) {
            Text(
                text = task.title,
                style = MaterialTheme.typography.bodyLarge,
                textDecoration = if (completing) TextDecoration.LineThrough else null,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
            )
            Text(
                text = formatTaskScheduleToday(task, now = now),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha),
            )
        }
    }
}

/** 记录摘要行：标题 + 时间，整行可点。 */
@Composable
private fun TodayNoteRow(note: NoteRecord, now: Instant?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val at = note.occurredAt ?: note.createdAt
    // 这一块只放今天记下的，所以时刻够用；now 为空（还没读到当前时间）时同样退回时刻。
    val timeText = if (now == null) DayCueTime.displayClock(at, zone) else DayCueTime.displayDayTime(at, now, zone)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .clickable(onClick = onClick)
            .padding(vertical = DayCueSpacing.Small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(note.title, style = MaterialTheme.typography.bodyLarge)
            Text(
                text = note.originKind.displayName + " · " + timeText,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector = Icons.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** 次要入口：课表 / 待办 / 追问。只在页面底部出现一次，避免和上面的分区标题重复。 */
@Composable
private fun QuickLinksRow(onOpenSchedule: () -> Unit, onOpenTasks: () -> Unit, onOpenFollowUp: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Small),
    ) {
        QuickLink("课表", Icons.Outlined.DateRange, onOpenSchedule, Modifier.weight(1f))
        QuickLink("待办", Icons.Outlined.Check, onOpenTasks, Modifier.weight(1f))
        QuickLink("追问", Icons.Outlined.MailOutline, onOpenFollowUp, Modifier.weight(1f))
    }
}

/**
 * 快捷入口。
 *
 * 三个入口等宽铺满一行，并各带一个图标：原来只是三个等宽文字块贴在左侧，
 * 既看不出是三个并列的入口，也让人不确定点上去会发生什么。
 */
@Composable
private fun QuickLink(text: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        color = MaterialTheme.colorScheme.surfaceContainer,
        contentColor = MaterialTheme.colorScheme.onSurface,
        shape = MaterialTheme.shapes.medium,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f)),
        modifier = modifier.heightIn(min = MinTouchTarget),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DayCueSpacing.Medium, vertical = DayCueSpacing.Medium),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(text, style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
private fun SmallLink(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.heightIn(min = MinTouchTarget)) {
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

/**
 * 时段文案。
 *
 * 同一天的课只显示「09:00 – 10:40」；跨天（例如晚课到次日）才把日期带上，
 * 因为在同一天的课上重复写两遍日期，反而看不出这是几点的课。
 */
private fun timeRangeText(startsAt: Instant, endsAt: Instant, zone: ZoneId): String {
    val startDay = DayCueTime.localDateOf(startsAt, zone)
    val endDay = DayCueTime.localDateOf(endsAt, zone)
    val start = DayCueTime.displayClock(startsAt, zone)
    val end = DayCueTime.displayClock(endsAt, zone)
    return if (startDay == endDay) {
        start + " – " + end
    } else {
        DayCueTime.displayMonthDayWeekday(startsAt, zone) + " " + start + " – " +
            DayCueTime.displayMonthDayWeekday(endsAt, zone) + " " + end
    }
}

/**
 * 按小时给一句问候。
 *
 * 用整数小时而不是 LocalTime：界面只要「大概什么时候」，
 * 而整数让这条规则可以直接写单元测试（见 TodayGreetingTest）。
 */
internal fun greetingFor(hour: Int): String = when {
    hour in 5..10 -> "早上好"
    hour in 11..13 -> "中午好"
    hour in 14..17 -> "下午好"
    hour in 18..22 -> "晚上好"
    else -> "夜深了"
}
