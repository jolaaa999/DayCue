package com.daycue.android.ui.capture

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material3.Checkbox
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.window.Dialog
import com.daycue.android.ui.common.RowDivider
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.Surface
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import com.daycue.android.core.DayCueTime
import com.daycue.android.ui.common.AudioPlaybackBar
import com.daycue.android.ui.common.LocalImage
import java.time.Instant
import java.time.ZoneId
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.DayCueRoutes
import com.daycue.android.ui.common.DayCueButton
import com.daycue.android.ui.common.DayCueButtonStyle
import com.daycue.android.ui.common.DayCueIcons
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.MiniTag
import com.daycue.android.ui.common.MiniTagTone
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.rememberContainer
import com.daycue.android.ui.theme.DayCueSpacing

/**
 * 记录页：文字 / 录音 / 图片三条入口，都遵循「先落库」。
 *
 * initialIntent 只决定「进来先摆出哪种输入」，不改变任何写入顺序：
 * 今天页点麦克风进来会自动开始录音，点拍照进来会自动拉起相机，
 * 但保存、转写、解析这条链路与手动进来完全一样。
 *
 * 拍照没有用 FileProvider：本工程的 AndroidManifest 里没有声明 provider，而 manifest 不在本次改动范围内。
 * 所以这里借助系统相册的 content:// 地址把照片交给相机应用（ActivityResultContracts.TakePicture
 * 会给相机临时写权限），拍照完成后再由 MediaStore 复制进 App 目录。
 * 用 file:// 会直接抛 FileUriExposedException，那是被系统禁止的老做法。
 */
@Composable
fun CaptureScreen(
    onBack: () -> Unit,
    initialIntent: String = "",
    /** 保存为笔记之后可以直达那条笔记；没接回调时按钮不显示。 */
    onOpenNote: (String) -> Unit = {},
) {
    val container = rememberContainer()
    val viewModel: CaptureViewModel = viewModel(factory = CaptureViewModel.factory(container))
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    // 相机拍下的原图临时落在系统相册里，复制完成后记录引用的是 App 内的那份。
    var cameraUri by remember { mutableStateOf<Uri?>(null) }

    val takePicture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val uri = cameraUri
        cameraUri = null
        if (saved && uri != null) viewModel.submitImage(uri) else viewModel.reportCancelled()
    }

    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) viewModel.submitImage(uri) else viewModel.reportCancelled()
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) {
            viewModel.reportPermissionDenied("相机权限未授予。可以直接用「选图」挑一张已有照片。")
        } else {
            val uri = createCameraUri(context)
            if (uri == null) {
                viewModel.reportCameraUnavailable()
            } else {
                cameraUri = uri
                takePicture.launch(uri)
            }
        }
    }

    val recordPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) viewModel.startRecording() else viewModel.reportPermissionDenied("录音权限未授予，仍可用文字记录。")
    }

    val launchCamera = {
        if (PermissionCenter.hasCamera(context)) {
            val uri = createCameraUri(context)
            if (uri == null) {
                viewModel.reportCameraUnavailable()
            } else {
                cameraUri = uri
                takePicture.launch(uri)
            }
        } else {
            cameraPermission.launch(PermissionCenter.CAMERA)
        }
    }

    // 只处理一次入口意图：旋转屏幕或重组不应该让麦克风再开一次。
    var intentHandled by remember { mutableStateOf(false) }
    LaunchedEffect(initialIntent) {
        if (intentHandled) return@LaunchedEffect
        intentHandled = true
        when (initialIntent) {
            DayCueRoutes.CAPTURE_INTENT_VOICE -> {
                if (PermissionCenter.hasRecording(context)) viewModel.startRecording()
                else recordPermission.launch(PermissionCenter.RECORD_AUDIO)
            }
            DayCueRoutes.CAPTURE_INTENT_IMAGE -> launchCamera()
            else -> Unit
        }
    }

    DayCueScreen(
        title = "记一笔",
        onBack = onBack,
        actions = {
            if (state.error != null || state.notice != null) {
                TextButton(onClick = { viewModel.clearMessages() }) { Text("清除提示") }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                // 键盘弹出时把内容区顶到键盘上方。不加这条，底部的「保存 / 提取待办」
                // 会落在输入法下面，用户点的是键盘而不是按钮（ISSUE-20261029-029）。
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DayCueSpacing.Screen),
        ) {
            // ---- 三个入口 ----
            Column(Modifier.fillMaxWidth()) {
                if (state.isRecording) {
                    Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium)) {
                        DayCueButton(
                            text = "停止并保存",
                            onClick = { viewModel.stopRecording() },
                            icon = DayCueIcons.Mic,
                            modifier = Modifier.weight(1f),
                        )
                        DayCueButton(
                            text = "取消",
                            onClick = { viewModel.cancelRecording() },
                            style = DayCueButtonStyle.Outline,
                            modifier = Modifier.weight(1f),
                        )
                    }
                } else {
                    // 录音单独占一行，拍照/选图并排在下面：
                    // 三个等宽挤在一行时，系统字号放大到 1.3 倍后「录音」会被折成两行；
                    // 而且录音本来就是这里的主操作，值得独占一行。
                    Column(Modifier.fillMaxWidth()) {
                        DayCueButton(
                            text = "录音",
                            onClick = {
                                if (PermissionCenter.hasRecording(context)) {
                                    viewModel.startRecording()
                                } else {
                                    recordPermission.launch(PermissionCenter.RECORD_AUDIO)
                                }
                            },
                            style = DayCueButtonStyle.Tonal,
                            icon = DayCueIcons.Mic,
                            enabled = !state.busy,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(DayCueSpacing.Medium))
                        Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium)) {
                            DayCueButton(
                                text = "拍照",
                                onClick = launchCamera,
                                style = DayCueButtonStyle.Outline,
                                icon = DayCueIcons.Camera,
                                enabled = !state.busy && !state.isRecording,
                                modifier = Modifier.weight(1f),
                            )
                            DayCueButton(
                                text = "选图",
                                onClick = {
                                    pickImage.launch(PickMediaRequest())
                                },
                                style = DayCueButtonStyle.Outline,
                                enabled = !state.busy && !state.isRecording,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
            // ---- 刚保存的图片 ----
            // 「已保存」这句话证明不了任何事：用户要看到的是那张图本身。
            state.savedImage?.let { saved ->
                Spacer(Modifier.height(DayCueSpacing.Large))
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    shape = MaterialTheme.shapes.medium,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                ) {
                    Column(Modifier.padding(DayCueSpacing.Medium)) {
                        LocalImage(
                            path = saved.path,
                            contentDescription = "刚保存的图片",
                            modifier = Modifier
                                .fillMaxWidth()
                                // 16:10 左右的固定高度：太高会挤掉下面的文字入口，太扁又认不出画面。
                                .height(190.dp),
                        )
                        Spacer(Modifier.height(DayCueSpacing.Small))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = "已保存到本机 · " + DayCueTime.displayClock(
                                    Instant.ofEpochMilli(saved.savedAtMillis),
                                    ZoneId.systemDefault(),
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f),
                            )
                        }
                        // 识别结果直接放在图下面：用户刚看完「是不是这张」，
                        // 紧接着想知道的就是「上面的字认对了吗」。
                        // 四种状态分别说清楚，尤其是「图上没字」和「识别失败」不能混成一句话。
                        Spacer(Modifier.height(DayCueSpacing.Small))
                        when (saved.ocrPhase) {
                            OcrPhase.RECOGNIZING -> Text(
                                text = "正在识别上面的文字…",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.primary,
                            )

                            OcrPhase.DONE -> {
                                val text = saved.ocrText.orEmpty()
                                Text(
                                    text = "识别到的文字（" + text.length + " 字）",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(Modifier.height(DayCueSpacing.XSmall))
                                // 一页板书记下来可能上千字，这里只给个开头：
                                // 整段铺开会把下面的按钮顶出屏幕，反而让人没法纠错。
                                Text(
                                    text = text,
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 4,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (text.length > 80) {
                                    Text(
                                        text = "全文可在「记录」页点开这条查看",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }

                            OcrPhase.EMPTY -> Text(
                                text = "未识别到文字，图片已保存。",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )

                            OcrPhase.FAILED -> Text(
                                text = "识别文字失败，图片已保存。",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        }

                        // 有文字才给这组动作：没有文字时「保存为笔记」只是个空洞的按钮。
                        if (saved.ocrText != null) {
                            Spacer(Modifier.height(DayCueSpacing.Medium))
                            Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium)) {
                                DayCueButton(
                                    text = "复制文字",
                                    onClick = {
                                        clipboard.setText(AnnotatedString(saved.ocrText))
                                        viewModel.reportCopied(saved.ocrText.length)
                                    },
                                    style = DayCueButtonStyle.Tonal,
                                    modifier = Modifier.weight(1f),
                                )
                                DayCueButton(
                                    text = "编辑文字",
                                    onClick = { viewModel.openOcrEdit() },
                                    style = DayCueButtonStyle.Outline,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            Spacer(Modifier.height(DayCueSpacing.Medium))
                            val savedNoteId = state.savedNoteId
                            if (savedNoteId != null) {
                                // 保存成功后按钮换成「打开笔记」：用户下一步通常就是想看看它。
                                DayCueButton(
                                    text = "打开笔记",
                                    onClick = { onOpenNote(savedNoteId) },
                                    icon = Icons.Outlined.KeyboardArrowRight,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                DayCueButton(
                                    text = if (state.savingNote) "保存中…" else "保存为笔记",
                                    onClick = { viewModel.openNoteDraft() },
                                    enabled = !state.savingNote,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                            Spacer(Modifier.height(DayCueSpacing.Medium))
                            // 「提取待办」是独立动作：调后端解析，结果进确认页，不自动写库。
                            DayCueButton(
                                text = if (state.extracting) "解析中…" else "提取待办",
                                onClick = { viewModel.extractFromImage() },
                                style = DayCueButtonStyle.Outline,
                                enabled = !state.extracting,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.height(DayCueSpacing.Medium))
                        Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium)) {
                            DayCueButton(
                                text = "换一张",
                                onClick = { pickImage.launch(PickMediaRequest()) },
                                style = DayCueButtonStyle.Tonal,
                                enabled = !state.busy,
                                modifier = Modifier.weight(1f),
                            )
                            DayCueButton(
                                text = "删除这张",
                                onClick = { viewModel.discardSavedImage() },
                                style = DayCueButtonStyle.Outline,
                                enabled = !state.busy,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            // ---- 刚录的音 ----
            // 只写一句「录音已保存」等于没保存：用户没法确认录进去的是不是自己想要的那段。
            state.savedAudio?.let { saved ->
                Spacer(Modifier.height(DayCueSpacing.Large))
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    shape = MaterialTheme.shapes.medium,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                ) {
                    Column(Modifier.padding(DayCueSpacing.Medium)) {
                        Text(
                            text = "刚录的 " + saved.seconds.toString() + " 秒",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Spacer(Modifier.height(DayCueSpacing.Small))
                        AudioPlaybackBar(path = saved.path)
                        Spacer(Modifier.height(DayCueSpacing.Small))
                        DayCueButton(
                            text = "删除这段录音",
                            onClick = { viewModel.discardSavedAudio() },
                            style = DayCueButtonStyle.Outline,
                            enabled = !state.busy && !state.isRecording,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            if (state.isRecording) {
                Spacer(Modifier.height(DayCueSpacing.Small))
                // 录音中不用 error 红：红色在别的页面专指「出问题了」，这里只是进行中的状态。
                Text(
                    text = "正在录音 · 已录 " + state.elapsedSeconds.toString() + " 秒",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
            }

            // ---- 文字 ----
            SectionHeader(title = "文字", subtitle = "先存到本机，之后自动整理")
            OutlinedTextField(
                value = state.text,
                onValueChange = { viewModel.onTextChange(it) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                shape = MaterialTheme.shapes.medium,
                placeholder = { Text("这节课讲了什么、要做什么") },
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Default),
                enabled = !state.isRecording,
            )
            Spacer(Modifier.height(DayCueSpacing.Medium))
            // 两个动作分开：保存只落库（离线可用），提取待办才走解析。
            Row(horizontalArrangement = Arrangement.spacedBy(DayCueSpacing.Medium)) {
                DayCueButton(
                    text = if (state.busy) "处理中…" else "保存",
                    onClick = { viewModel.submitText() },
                    enabled = !state.busy && !state.isRecording,
                    modifier = Modifier.weight(1f),
                )
                DayCueButton(
                    text = if (state.extracting) "解析中…" else "提取待办",
                    onClick = { viewModel.extractFromText() },
                    style = DayCueButtonStyle.Tonal,
                    enabled = !state.busy && !state.extracting && !state.isRecording,
                    modifier = Modifier.weight(1f),
                )
            }

            state.error?.let {
                Spacer(Modifier.height(DayCueSpacing.Medium))
                MessageCard(text = it, isError = true)
            }
            // 录音中不再显示 ViewModel 那条「正在录音，再次点击停止。」：
            // 上面的计时行已经把状态说清楚了，两句并列反而像两个互相无关的提示。
            if (!state.isRecording) {
                state.notice?.let {
                    Spacer(Modifier.height(DayCueSpacing.Medium))
                    MessageCard(text = it)
                }
            }

            state.transcript?.let { text ->
                SectionHeader(title = "转写结果")
                Text(text, style = MaterialTheme.typography.bodyMedium)
            }

            Spacer(Modifier.height(DayCueSpacing.XXLarge))
        }

        // 确认页用 Dialog 而不是新路由：解析结果只在这一次提交里有意义，
        // 新开一个页面还要处理「返回时候选要不要留」这种多余状态。
        state.noteDraft?.let { draft ->
            NoteDraftDialog(
                draft = draft,
                saving = state.savingNote,
                onTitleChange = viewModel::onNoteDraftTitleChange,
                onBodyChange = viewModel::onNoteDraftBodyChange,
                onDismiss = viewModel::dismissNoteDraft,
                onSave = viewModel::saveNoteDraft,
            )
        }

        state.ocrEditDraft?.let { draft ->
            OcrEditDialog(
                value = draft,
                onValueChange = viewModel::onOcrEditChange,
                onDismiss = viewModel::dismissOcrEdit,
                onSave = viewModel::saveOcrEdit,
            )
        }

        if (state.confirmVisible) {
            CandidatesDialog(
                candidates = state.candidates,
                selectedIds = state.selectedCandidateIds,
                modeName = state.extractionModeName,
                saving = state.savingCandidates,
                onToggle = viewModel::toggleCandidate,
                onDismiss = viewModel::dismissConfirm,
                onSave = viewModel::saveSelectedCandidates,
            )
        }
    }
}

/** 选图请求的简写，避免在点击回调里写一长串 ActivityResultContracts.PickVisualMedia.ImageOnly。 */
private fun PickMediaRequest(): PickVisualMediaRequest =
    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)

/**
 * 为相机应用准备一个可写的相册地址。
 *
 * 失败时返回 null 而不是抛异常：API 26–28 上写系统相册需要存储权限，
 * 没有权限时应该让用户改用「选图」，而不是让页面崩溃。
 */
private fun createCameraUri(context: Context): Uri? = runCatching {
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, "daycue-capture-" + System.currentTimeMillis().toString() + ".jpg")
        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
    }
    context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
}.getOrNull()

/**
 * 保存笔记前的确认框。
 *
 * 标题默认取首个非空行、正文默认是识别全文，两者都可以改——识别结果只是草稿，
 * 敲定写什么的是用户。只有点「保存笔记」才会写 note 表。
 */
@Composable
private fun NoteDraftDialog(
    draft: NoteDraft,
    saving: Boolean,
    onTitleChange: (String) -> Unit,
    onBodyChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
) {
    Dialog(onDismissRequest = { if (!saving) onDismiss() }) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.padding(DayCueSpacing.Large)) {
                Text("保存为笔记", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(DayCueSpacing.XSmall))
                Text(
                    text = draft.sourceLabel + " · 先核对标题与正文，保存后仍可修改",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                OutlinedTextField(
                    value = draft.title,
                    onValueChange = onTitleChange,
                    label = { Text("标题") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(DayCueSpacing.Small))
                OutlinedTextField(
                    value = draft.body,
                    onValueChange = onBodyChange,
                    label = { Text("正文") },
                    // 限高而不是限行：正文可能是几百字，框内自己滚动，不把对话框撑出屏幕。
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp, max = 220.dp),
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss, enabled = !saving) { Text("取消") }
                    Spacer(Modifier.weight(1f))
                    DayCueButton(
                        text = if (saving) "保存中…" else "保存笔记",
                        onClick = onSave,
                        enabled = !saving,
                    )
                }
            }
        }
    }
}

/** 编辑识别出来的文字。保存后置 user_edited，晚到的机器结果不能覆盖。 */
@Composable
private fun OcrEditDialog(
    value: String,
    onValueChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.padding(DayCueSpacing.Large)) {
                Text("编辑文字", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(DayCueSpacing.XSmall))
                Text(
                    text = "改完之后这条记录的展示文字就以你的版本为准",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                OutlinedTextField(
                    value = value,
                    onValueChange = onValueChange,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 160.dp, max = 320.dp),
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss) { Text("取消") }
                    Spacer(Modifier.weight(1f))
                    DayCueButton(text = "保存", onClick = onSave)
                }
            }
        }
    }
}

/**
 * 解析结果的确认页。
 *
 * 这是整条链路上唯一能把候选变成 task / note 的地方：
 * 默认全选是因为用户点「提取待办」的目的就是要整理，但每一条都能取消，
 * 保存按钮上写着会写几条，避免「点一下多出五条待办」。
 */
@Composable
private fun CandidatesDialog(
    candidates: List<CandidateItem>,
    selectedIds: Set<String>,
    modeName: String?,
    saving: Boolean,
    onToggle: (String) -> Unit,
    onDismiss: () -> Unit,
    onSave: () -> Unit,
) {
    val selectedCount = candidates.count { it.itemId in selectedIds }
    Dialog(onDismissRequest = { if (!saving) onDismiss() }) {
        Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.padding(DayCueSpacing.Large)) {
                Text("确认要保存的条目", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(DayCueSpacing.XSmall))
                Text(
                    text = (modeName?.let { "解析模式：" + it + " · " } ?: "") + "只保存你勾选的条目",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 380.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    candidates.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onToggle(item.itemId) }
                                .padding(vertical = DayCueSpacing.Small),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Checkbox(
                                checked = item.itemId in selectedIds,
                                onCheckedChange = { onToggle(item.itemId) },
                            )
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    MiniTag(text = item.kindName, tone = MiniTagTone.Accent)
                                    Spacer(Modifier.width(DayCueSpacing.XSmall))
                                    Text(item.title, style = MaterialTheme.typography.bodyLarge)
                                }
                                Text(
                                    text = "截止：" + item.dueText,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                // 证据原文要露出来：用户判断「这条要不要」靠的就是原话。
                                Text(
                                    text = "原话：" + item.evidence,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                item.notes.forEach { note ->
                                    Text(
                                        text = "· " + note,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.secondary,
                                    )
                                }
                            }
                        }
                        if (index < candidates.lastIndex) RowDivider()
                    }
                }
                Spacer(Modifier.height(DayCueSpacing.Medium))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onDismiss, enabled = !saving) { Text("取消") }
                    Spacer(Modifier.weight(1f))
                    DayCueButton(
                        text = if (saving) "保存中…" else "保存所选（" + selectedCount + "）",
                        onClick = onSave,
                        enabled = !saving && selectedCount > 0,
                    )
                }
            }
        }
    }
}
