package com.daycue.android.ui.note

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.KeyValueLine
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.MiniTag
import com.daycue.android.ui.common.MiniTagTone
import com.daycue.android.ui.common.RowDivider
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.SettingGroup
import com.daycue.android.ui.common.WriteStateBadge
import com.daycue.android.core.DayCueTime
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.common.formatTaskDue
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget
import java.time.Instant
import java.time.ZoneId

/**
 * 记录详情：编辑、软删除、溯源。
 *
 * 来源区是这一页的重点：「这条笔记从哪来」决定了它可不可信，
 * 所以 originKind 与来源记录的原文都必须显示出来，而不是只显示笔记本身。
 *
 * 排版上换成「先读后改」：标题和正文是两块无边框的编辑区（进入页面时看起来就是正文），
 * 只有改过之后保存按钮才生效。原来一进页面就是两个带 label 的描边输入框加两个按钮，
 * 视觉上像一张表单，而用户多数时候只是想看一眼这条记录。
 */
@Composable
fun NoteDetailScreen(
    noteId: String,
    onBack: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: NoteDetailViewModel = viewModel(
        factory = NoteDetailViewModel.factory(container, noteId),
    )
    val state by viewModel.state.collectAsState()

    NoteDetailContent(
        state = state,
        onBack = onBack,
        onTitleChange = viewModel::onTitleChange,
        onBodyChange = viewModel::onBodyChange,
        onSave = viewModel::save,
        onDelete = viewModel::delete,
    )
}

/** 纯展示部分：状态与回调都由外部给，调试画廊与 Compose Preview 直接复用。 */
@Composable
fun NoteDetailContent(
    state: NoteDetailUiState,
    onBack: () -> Unit,
    onTitleChange: (String) -> Unit,
    onBodyChange: (String) -> Unit,
    onSave: () -> Unit,
    onDelete: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    val note = state.note

    DayCueScreen(title = "记录详情", onBack = onBack) { padding ->
        if (note == null && !state.loading) {
            Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = DayCueSpacing.Screen)) {
                state.notice?.let { MessageCard(text = it) }
                EmptyState(
                    title = if (state.deleted) "这条记录已删除" else "找不到这条记录",
                    description = if (state.deleted) {
                        "删除是软删除：内容仍在本机数据库里，时间线之外的页面不再显示它。"
                    } else {
                        "它可能已经被删除，或者数据库里没有这个 id。"
                    },
                    actionLabel = "返回",
                    onAction = onBack,
                )
            }
            return@DayCueScreen
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            state.error?.let { MessageCard(text = it, isError = true) }
            state.notice?.let { MessageCard(text = it) }

            // 标题：进入页面时就是正文的样子，只有聚焦时才露出输入框底色。
            BorderlessField(
                value = state.titleDraft,
                onValueChange = onTitleChange,
                placeholder = "无标题",
                textStyle = MaterialTheme.typography.titleLarge,
                singleLine = true,
            )
            if (note != null) {
                MetaLine(note = note, now = state.now)
            }
            BorderlessField(
                value = state.bodyDraft,
                onValueChange = onBodyChange,
                placeholder = "写点什么",
                textStyle = MaterialTheme.typography.bodyLarge,
                // 只留三行的高度：正文通常只有两三句，留六行会在正文和按钮之间留出一大块空白。
                minLines = 3,
            )

            Spacer(Modifier.height(DayCueSpacing.Medium))
            // 没改动时整行只留「删除」：灰着一个不可用的「保存」既占地方又让人怀疑是不是坏了。
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (state.dirty) {
                    DayCueButton(
                        text = "保存修订",
                        onClick = onSave,
                        enabled = !state.busy,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Text(
                        text = "没有改动",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                }
                Spacer(Modifier.width(DayCueSpacing.Medium))
                // 删除是低频且不可撤销的动作，放成一行小字，不放主按钮旁边抢位置。
                TextButton(onClick = { confirmDelete = true }, enabled = !state.busy) {
                    Text(
                        text = "删除",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }

            SectionHeader(title = "来源", subtitle = "这条记录从哪来，决定它可不可信")
            SettingGroup {
                val rows = buildList {
                    add("来源类型" to (note?.originKind?.displayName ?: "未知"))
                    add("是否由你修订" to if (note?.userEdited == true) "是（识别结果不会覆盖）" else "否")
                    add("发生时间" to timeText(note?.occurredAt, state.now, "未记录"))
                    add("创建时间" to timeText(note?.createdAt, state.now, "未知"))
                    note?.courseHint?.takeIf { it.isNotBlank() }?.let { add("关联课程" to it) }
                }
                rows.forEachIndexed { index, (label, value) ->
                    Column {
                        Column(Modifier.padding(horizontal = DayCueSpacing.Large)) {
                            KeyValueLine(label = label, value = value)
                        }
                        if (index < rows.lastIndex) RowDivider()
                    }
                }
            }

            Spacer(Modifier.height(DayCueSpacing.Medium))
            val sourceKind = state.sourceCaptureKind
            if (sourceKind != null) {
                SourceQuote(
                    label = "来源记录原文 · " + sourceKind,
                    text = state.sourceCaptureText
                        ?: "来源记录没有文本内容（录音或图片尚未补充文字）。",
                )
            } else {
                Text(
                    text = "这条笔记没有关联的记录来源。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            SectionHeader(title = "同一来源的待办", subtitle = "任务与笔记分开存，这里只做展示，不改状态")
            if (state.relatedTasks.isEmpty()) {
                // 一段小字而不是整块空态：这里「没有」是常态，不值得占掉半屏。
                QuietEmpty("没有关联的待办——笔记默认不提醒，只有写出明确动作才会生成待办。")
            } else {
                SettingGroup {
                    state.relatedTasks.forEachIndexed { index, task ->
                        Column {
                            TaskRow(task = task, now = state.now)
                            if (index < state.relatedTasks.lastIndex) RowDivider()
                        }
                    }
                }
            }

            SectionHeader(title = "同一来源的其他笔记")
            if (state.relatedNotes.isEmpty()) {
                QuietEmpty("没有其他笔记——一次记录通常只产出一条。")
            } else {
                SettingGroup {
                    state.relatedNotes.forEachIndexed { index, other ->
                        Column {
                            RelatedNoteRow(note = other, now = state.now)
                            if (index < state.relatedNotes.lastIndex) RowDivider()
                        }
                    }
                }
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }

        if (confirmDelete) {
            AlertDialog(
                onDismissRequest = { confirmDelete = false },
                title = { Text("删除这条记录？") },
                text = { Text("删除后它不会再出现在列表里；内容仍以软删除的形式保留在本机数据库中，外部同步期间不做物理删除。") },
                confirmButton = {
                    TextButton(onClick = {
                        confirmDelete = false
                        onDelete()
                    }) { Text("删除") }
                },
                dismissButton = {
                    TextButton(onClick = { confirmDelete = false }) { Text("取消") }
                },
            )
        }
    }
}

/**
 * 无边框输入区。
 *
 * 用 TextField 而不是 BasicTextField：IME、光标、选择这些交给 Material 处理，
 * 只把容器色和指示线抹成透明——看起来是正文，点进去才是输入框。
 */
@Composable
private fun BorderlessField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    textStyle: androidx.compose.ui.text.TextStyle,
    singleLine: Boolean = false,
    minLines: Int = 1,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        textStyle = textStyle,
        singleLine = singleLine,
        minLines = minLines,
        placeholder = {
            Text(placeholder, style = textStyle, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
        },
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            focusedIndicatorColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
        ),
    )
}

/** 标题下方的一行元信息：来源 · 时间 · 是否修订。 */
@Composable
private fun MetaLine(note: NoteRecord, now: Instant?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = timeText(note.occurredAt ?: note.createdAt, now, "时间未记录"),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (note.userEdited) {
            Spacer(Modifier.width(DayCueSpacing.Small))
            MiniTag(text = "已修订", tone = MiniTagTone.Accent)
        }
    }
}

/** 来源原文：左侧一条主色竖线，明确「这段文字不是这条笔记本身，而是它的来源」。 */
@Composable
private fun SourceQuote(label: String, text: String) {
    Row(modifier = Modifier.height(IntrinsicSize.Min)) {
        Box(
            Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.45f), RoundedCornerShape(2.dp)),
        )
        Spacer(Modifier.width(DayCueSpacing.Medium))
        Column {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(DayCueSpacing.XSmall))
            Text(text = text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun QuietEmpty(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = DayCueSpacing.Small),
    )
}

@Composable
private fun TaskRow(task: TaskRecord, now: Instant?) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = task.title,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
            WriteStateBadge(state = task.externalWriteState)
        }
        Spacer(Modifier.height(2.dp))
        Text(
            // 截止时刻也用「今天 22:00 / 明天 09:00」：这一页别的日期已经这么写了，
            // 再混一个 2026-10-26 22:00 会显得像两个来源的数据。
            text = "截止：" + dueText(task, now) + " · " + task.status.displayName,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RelatedNoteRow(note: NoteRecord, now: Instant?) {
    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .padding(horizontal = DayCueSpacing.Large, vertical = DayCueSpacing.Medium),
    ) {
        Text(note.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(2.dp))
        Text(
            text = timeText(note.occurredAt ?: note.createdAt, now, "时间未记录"),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * 截止时间：DATETIME 用相对日期（今天 / 明天 / 10月20日 + 时刻），
 * DATE 型仍然只给日期——那是领域层「日期型截止日不补时刻」的规则，界面不能破。
 */
private fun dueText(task: TaskRecord, now: Instant?): String {
    if (task.dueKind != com.daycue.android.domain.model.DueKind.DATETIME) return formatTaskDue(task)
    val due = task.dueUtc ?: return "截止时刻缺失"
    val zone = com.daycue.android.ui.common.zoneOf(task.timezone)
    return if (now == null) formatDateTime(due, zone) else DayCueTime.displayDayTime(due, now, zone)
}

/**
 * 详情页的时间写法与列表一致：今天 / 昨天 / 10月20日 + 时刻。
 * 没有基准时刻（理论上只会在极端情况下发生）时退回绝对时间，宁可难看也不显示错的「今天」。
 */
private fun timeText(instant: Instant?, now: Instant?, fallback: String): String {
    if (instant == null) return fallback
    val zone = ZoneId.systemDefault()
    return if (now == null) formatDateTime(instant, zone) else DayCueTime.displayDayTime(instant, now, zone)
}
