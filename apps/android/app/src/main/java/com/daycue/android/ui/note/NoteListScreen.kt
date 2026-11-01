package com.daycue.android.ui.note

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import com.daycue.android.ui.common.AudioPlaybackBar
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.window.Dialog
import com.daycue.android.domain.model.CaptureKind
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.ui.common.LocalImage
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.List
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.ui.DayCueRoutes
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.DayCueIcons
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyStateGlyph
import com.daycue.android.ui.common.FilterChipsRow
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.MiniTag
import com.daycue.android.ui.common.MiniTagTone
import com.daycue.android.ui.common.RowDivider
import com.daycue.android.ui.common.SearchField
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget
import java.time.Instant
import java.time.ZoneId

/**
 * 记录列表。
 *
 * 空的时候把「记一笔」放在正中，并提供文字 / 语音 / 拍照三个直接入口：
 * 搜索框只在已经有记录之后才出现——一条记录都没有时，搜索框是这一页最显眼、
 * 却完全用不上的东西。
 */
@Composable
fun NoteListScreen(
    onOpenNote: (String) -> Unit,
    onNewCapture: (String) -> Unit,
) {
    val container = rememberContainer()
    val viewModel: NoteListViewModel = viewModel(factory = NoteListViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    NoteListContent(
        state = state,
        onKeywordChange = viewModel::onKeywordChange,
        onFilterChange = viewModel::onFilterChange,
        onOpenNote = onOpenNote,
        onNewCapture = onNewCapture,
        onDeleteCapture = viewModel::deleteCapture,
    )
}

@Composable
fun NoteListContent(
    state: NoteListUiState,
    onKeywordChange: (String) -> Unit,
    onFilterChange: (NoteOriginKind?) -> Unit,
    onOpenNote: (String) -> Unit,
    onNewCapture: (String) -> Unit,
    onDeleteCapture: (MediaCaptureItem) -> Unit = {},
) {
    // 有笔记或图片/录音，都算「有记录」：只有一张图片的用户不该看到「还没有记录」。
    val hasAnyRecord = state.notes.isNotEmpty() || state.mediaCaptures.isNotEmpty()
    var preview by remember { mutableStateOf<MediaCaptureItem?>(null) }

    DayCueScreen(
        title = "记录",
        actions = {
            if (hasAnyRecord) {
                DayCueButton(
                    text = "记一笔",
                    onClick = { onNewCapture(DayCueRoutes.CAPTURE_INTENT_TEXT) },
                    style = DayCueButtonStyle.Text,
                )
            }
        },
    ) { padding ->
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
            state.error?.let { error ->
                item {
                    MessageCard(text = error, isError = true)
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                }
            }

            if (!hasAnyRecord) {
                item {
                    // 空态放在视口高度的 78% 里居中：直接顶在列表开头会留下大半屏死白，
                    // 让人以为下面还有没加载出来的内容；略高于正中是因为视觉重心比几何中心略高。
                    Column(
                        modifier = Modifier.fillParentMaxHeight(0.78f).fillMaxWidth(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        RecordsEmptyBlock(onNewCapture = onNewCapture)
                    }
                }
            } else {
                // 搜索与来源筛选只覆盖笔记的文字。本机只有图片/录音时，
                // 摆一个搜不到任何东西的搜索框和四个筛不出东西的档位，等于在骗用户。
                if (state.notes.isNotEmpty()) {
                    item {
                        SearchField(
                            value = state.keyword,
                            onValueChange = onKeywordChange,
                            placeholder = "搜索标题或正文",
                        )
                    }
                    item {
                        Spacer(Modifier.height(DayCueSpacing.Medium))
                        FilterChipsRow(
                            options = FILTER_OPTIONS,
                            selected = state.filter,
                            labelOf = { kind -> kind?.displayName ?: "全部" },
                            onSelect = onFilterChange,
                        )
                        Spacer(Modifier.height(DayCueSpacing.Small))
                    }
                }

                // 图片与录音排在笔记前面：它们没有文字，用户只能靠缩略图认出自己存了什么，
                // 藏到列表末尾等于逼他一直往下翻。搜索时不参与——搜索搜的是文字，图片没有文字参与不了。
                if (state.mediaCaptures.isNotEmpty() && state.keyword.isBlank()) {
                    item {
                        MediaSectionHeader(count = state.mediaCaptures.size)
                    }
                    items(state.mediaCaptures, key = { it.captureId }) { item ->
                        MediaCaptureRow(
                            item = item,
                            now = state.now,
                            modifier = Modifier.animateItem(),
                            onClick = { preview = item },
                        )
                        RowDivider()
                    }
                    if (state.notes.isNotEmpty()) {
                        item { NotesSectionHeader(count = state.visibleNotes.size) }
                    }
                }

                if (state.visibleNotes.isEmpty() && state.mediaCaptures.isEmpty()) {
                    item {
                        Text(
                            text = if (state.keyword.isBlank()) {
                                "这个来源下还没有记录。"
                            } else {
                                "没有匹配「" + state.keyword + "」的记录，换个词试试。"
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(vertical = DayCueSpacing.XLarge),
                        )
                    }
                }
                if (state.visibleNotes.isNotEmpty()) {
                    itemsIndexed(state.visibleNotes, key = { _, note -> note.id }) { index, note ->
                        NoteRow(
                            note = note,
                            now = state.now,
                            // animateItem 是 LazyItemScope 的成员扩展，必须在 items 的 lambda 里调用。
                            modifier = Modifier.animateItem(),
                            onClick = { onOpenNote(note.id) },
                        )
                        // 列表是连续三行的文字，没有分隔线时会糊成一整块。
                        if (index < state.visibleNotes.lastIndex) RowDivider()
                    }
                }
            }
        }

        preview?.let { item ->
            MediaPreviewDialog(
                item = item,
                now = state.now,
                onDismiss = { preview = null },
                onDelete = {
                    preview = null
                    onDeleteCapture(item)
                },
            )
        }
    }
}

/** 筛选档位：null 代表「全部」，其余按来源分。 */
private val FILTER_OPTIONS: List<NoteOriginKind?> = listOf(
    null,
    NoteOriginKind.CAPTURE,
    NoteOriginKind.FOLLOW_UP,
    NoteOriginKind.MANUAL,
)

/**
 * 一条记录都没有时的引导区。
 *
 * 三个入口都在这里，且和今天页的快速记录区用同一套颜色与尺寸：
 * 用户从今天页点「写文字」和从记录页点「写文字」，落到的是同一个捕获流程。
 */
@Composable
private fun RecordsEmptyBlock(onNewCapture: (String) -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        EmptyStateGlyph(Icons.Outlined.List)
        Spacer(Modifier.height(DayCueSpacing.Medium))
        Text("还没有记录", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(DayCueSpacing.XSmall + 2.dp))
        // 说明文字限宽并居中：不限宽时它会被拉成一整行横贯屏幕，字号一大就散成两截。
        Text(
            text = "说一句、写几个字，或者拍一页板书；内容会先存在这台设备上。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 280.dp),
        )
        Spacer(Modifier.height(DayCueSpacing.XLarge))
        // 三个入口共用同一栏宽：主操作占满，两个次操作等分，视觉上是一组而不是三段拼贴。
        Column(Modifier.widthIn(max = 300.dp).fillMaxWidth()) {
            DayCueButton(
                text = "说一句",
                onClick = { onNewCapture(DayCueRoutes.CAPTURE_INTENT_VOICE) },
                icon = DayCueIcons.Mic,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(DayCueSpacing.Medium))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium),
            ) {
                DayCueButton(
                    text = "写文字",
                    onClick = { onNewCapture(DayCueRoutes.CAPTURE_INTENT_TEXT) },
                    style = DayCueButtonStyle.Tonal,
                    icon = Icons.Outlined.Edit,
                    modifier = Modifier.weight(1f),
                )
                DayCueButton(
                    text = "拍一张",
                    onClick = { onNewCapture(DayCueRoutes.CAPTURE_INTENT_IMAGE) },
                    style = DayCueButtonStyle.Outline,
                    icon = DayCueIcons.Camera,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/**
 * 列表行：标题 + 摘要 + 类型/时间 + 右箭头。
 *
 * 类型用标签而不是拼进说明文字里：拼进字符串后，不同来源的记录看上去完全一样，
 * 而来源决定了这条记录是「自己写的」还是「课后追问生成的」，用户需要一眼分清。
 */
@Composable
private fun NoteRow(note: NoteRecord, now: Instant?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val zone = ZoneId.systemDefault()
    val at = note.occurredAt ?: note.createdAt
    // 没有基准时刻时退回只显示时刻：宁可少一个日期，也不显示一个可能算错的「今天」。
    val timeText = if (now == null) DayCueTime.displayClock(at, zone) else DayCueTime.displayDayTime(at, now, zone)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .clickable(onClick = onClick)
            .padding(vertical = DayCueSpacing.Medium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MiniTag(text = note.originKind.displayName, tone = MiniTagTone.Neutral)
                if (note.userEdited) {
                    Spacer(Modifier.size(DayCueSpacing.XSmall))
                    MiniTag(text = "已修订", tone = MiniTagTone.Accent)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    text = timeText,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                // 箭头跟着标题行走：正文变长时，居中悬在整块右侧的箭头会浮在第二行，
                // 看不出它属于哪一行。
                Spacer(Modifier.size(DayCueSpacing.XSmall))
                Icon(
                    imageVector = Icons.Outlined.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
            Spacer(Modifier.height(DayCueSpacing.XSmall))
            Text(note.title, style = MaterialTheme.typography.titleMedium, maxLines = 2)
            if (note.body.isNotBlank()) {
                Text(
                    text = note.body,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                )
            }
        }
    }
}

/**
 * 分区标题：还没整理成笔记的本机记录。
 *
 * 名字不叫「图片与录音」：没解析成功的文字记录也在这里，
 * 而它们恰恰是最容易被漏掉的一类——用户明明写了字，记录页却一条都找不到。
 */
@Composable
private fun MediaSectionHeader(count: Int) {
    Column(Modifier.padding(top = DayCueSpacing.Medium, bottom = DayCueSpacing.XSmall)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("本机记录", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            Text(
                text = count.toString() + " 条",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = "这些还没整理成笔记，先按原样留在这台设备上。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 分区标题：笔记。只在上面已经有图片/录音时出现，否则它和页面标题重复。 */
@Composable
private fun NotesSectionHeader(count: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = DayCueSpacing.Large, bottom = DayCueSpacing.XSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("笔记", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
        Text(
            text = count.toString() + " 条",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * 一条图片 / 录音记录：缩略图 + 类型状态 + 时间。
 *
 * 缩略图是这一行的主角：用户想确认的就是「我存的是不是这张」，
 * 所以图片给 56dp 方图，录音给同样大小的图标块，两者的行高一致，列表才不会高低起伏。
 */
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun MediaCaptureRow(
    item: MediaCaptureItem,
    now: Instant?,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = MinTouchTarget)
            .clickable(onClick = onClick)
            .padding(vertical = DayCueSpacing.Small),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (item.kind == CaptureKind.IMAGE && item.path != null) {
            LocalImage(
                path = item.path,
                contentDescription = "图片记录缩略图",
                modifier = Modifier.size(56.dp),
                cornerRadius = 10.dp,
            )
        } else {
            // 录音没有封面也没有波形（播放还没做），文字记录没有缩略图，
            // 都用图标块占住同样的位置，保证每行左边都有一个 56dp 的方块。
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (item.kind == CaptureKind.AUDIO) DayCueIcons.Mic else Icons.Outlined.Edit,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        Spacer(Modifier.width(DayCueSpacing.Medium))
        Column(Modifier.weight(1f)) {
            // 用 FlowRow 而不是固定 Row：「已保存到本机」这类状态标签在系统字号放大后
            // 会和右侧时间抢位置，固定 Row 只能把它压成两行或截断；
            // FlowRow 让时间自然换到下一行，谁也不挤谁。
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.XSmall),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                MiniTag(text = item.kind.displayName, tone = MiniTagTone.Neutral)
                // 状态如实写：图片 OCR 与转写都还没接入，这些记录会一直停在「待处理」，
                // 写「待处理」比写「已解析」诚实。
                MiniTag(
                    text = item.status.displayName,
                    tone = if (item.status == CaptureStatus.FAILED) MiniTagTone.Warning else MiniTagTone.Neutral,
                )
                Text(
                    text = mediaTimeText(item.recordedAt, now),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            Spacer(Modifier.height(2.dp))
            Text(
                text = item.text ?: "还没有文字内容",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        Spacer(Modifier.size(DayCueSpacing.XSmall))
        Icon(
            imageVector = Icons.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * 图片 / 录音的全屏预览。
 *
 * 用 Dialog 而不是新开一个页面：这里只需要「看大图 + 删掉」，一个新路由加上返回栈
 * 反而多一层。图片用 Fit 显示——缩略图可以裁，确认是不是这张的时候裁掉一半就没意义了。
 */
@Composable
private fun MediaPreviewDialog(
    item: MediaCaptureItem,
    now: Instant?,
    onDismiss: () -> Unit,
    onDelete: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.padding(DayCueSpacing.Medium)) {
                if (item.kind == CaptureKind.IMAGE && item.path != null) {
                    LocalImage(
                        path = item.path,
                        contentDescription = "记录的图片",
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 420.dp)
                            .height(420.dp),
                        cornerRadius = 12.dp,
                        contentScale = ContentScale.Fit,
                    )
                } else if (item.kind == CaptureKind.AUDIO && item.path != null) {
                    Text(
                        text = "录音",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.height(DayCueSpacing.Small))
                    AudioPlaybackBar(path = item.path)
                } else if (!item.text.isNullOrBlank()) {
                    // 纯文字记录以前会掉进下面的兜底分支，显示「没有可预览的内容」——
                    // 明明列表上就有正文，点开却什么都没有（ISSUE-20261029-030）。
                    Text(
                        text = "正文",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(DayCueSpacing.XSmall))
                    Text(
                        text = item.text!!,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
                    )
                } else {
                    Text(
                        text = "这条记录没有可预览的内容。",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                // 录音：转写文字单独一块。没有转写就什么都不说，不拿「录音 8 秒」冒充内容。
                if (item.kind == CaptureKind.AUDIO && item.transcriptText != null) {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    Text(
                        text = "转写全文",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(DayCueSpacing.XSmall))
                    Text(
                        text = item.transcriptText,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.heightIn(max = 160.dp).verticalScroll(rememberScrollState()),
                    )
                }
                // 图片：把识别到的文字整段放出来，用户可以对着图核对哪几个字认错了。
                if (item.kind == CaptureKind.IMAGE && item.text != null) {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    Text(
                        text = "识别到的文字",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(DayCueSpacing.XSmall))
                    Text(
                        text = item.text,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.heightIn(max = 160.dp).verticalScroll(rememberScrollState()),
                    )
                }
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Text(
                    text = item.kind.displayName + " · " + mediaTimeText(item.recordedAt, now) + " · " + item.status.displayName,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium),
                ) {
                    TextButton(onClick = onDelete) {
                        Text("删除这条", color = MaterialTheme.colorScheme.error)
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("关闭") }
                }
            }
        }
    }
}

/** 记录里的时间写法与笔记行一致：今天 / 昨天 / 10月20日 + 时刻。 */
private fun mediaTimeText(at: Instant, now: Instant?): String {
    val zone = ZoneId.systemDefault()
    return if (now == null) DayCueTime.displayClock(at, zone) else DayCueTime.displayDayTime(at, now, zone)
}
