package com.daycue.android.ui.capture

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.rememberContainer

/**
 * 记录页：文字 / 录音 / 图片三条入口，都遵循「先落库」。
 *
 * 拍照没有用 FileProvider：本工程的 AndroidManifest 里没有声明 provider，而 manifest 不在本次改动范围内。
 * 所以这里借助系统相册的 content:// 地址把照片交给相机应用（ActivityResultContracts.TakePicture
 * 会给相机临时写权限），拍照完成后再由 MediaStore 复制进 App 目录。
 * 用 file:// 会直接抛 FileUriExposedException，那是被系统禁止的老做法。
 */
@Composable
fun CaptureScreen(onBack: () -> Unit) {
    val container = rememberContainer()
    val viewModel: CaptureViewModel = viewModel(factory = CaptureViewModel.factory(container))
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current

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
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            SectionHeader(
                title = "文字",
                subtitle = "先保存到本机，再尝试解析；解析失败不会丢内容",
            )
            OutlinedTextField(
                value = state.text,
                onValueChange = { viewModel.onTextChange(it) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                label = { Text("这节课讲了什么、要做什么") },
                enabled = !state.isRecording,
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { viewModel.submitText() }, enabled = !state.busy && !state.isRecording) {
                    Text(if (state.busy) "处理中…" else "保存并解析")
                }
            }

            SectionHeader(title = "录音", subtitle = "停止后音频立即写盘，转写是后一步")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.isRecording) {
                    Button(onClick = { viewModel.stopRecording() }) { Text("停止并保存") }
                    OutlinedButton(onClick = { viewModel.cancelRecording() }) { Text("取消录音") }
                } else {
                    OutlinedButton(
                        onClick = {
                            if (PermissionCenter.hasRecording(context)) {
                                viewModel.startRecording()
                            } else {
                                recordPermission.launch(PermissionCenter.RECORD_AUDIO)
                            }
                        },
                        enabled = !state.busy,
                    ) { Text("开始录音") }
                }
            }
            if (state.isRecording) {
                Text(
                    text = "已录 " + state.elapsedSeconds.toString() + " 秒",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }

            SectionHeader(title = "图片", subtitle = "图片识别没有接入，图片只保存不做 OCR")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = {
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
                    },
                    enabled = !state.busy && !state.isRecording,
                ) { Text("拍照") }

                OutlinedButton(
                    onClick = {
                        pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                    enabled = !state.busy && !state.isRecording,
                ) { Text("选图") }
            }
            Text(
                text = "拍照会先经过系统相册；保存到 App 之后，记录引用的是 App 内的副本。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            state.error?.let { item -> MessageCard(text = item, isError = true) }
            state.notice?.let { item -> MessageCard(text = item) }

            state.transcript?.let { text ->
                SectionHeader(title = "转写结果")
                Text(text, style = MaterialTheme.typography.bodyMedium)
            }

            state.extraction?.let { extraction ->
                SectionHeader(
                    title = "解析候选",
                    subtitle = "模式：" + extraction.modeName + "（候选只做展示，不会自动写入待办或笔记）",
                )
                if (extraction.items.isEmpty()) {
                    EmptyState(
                        title = "没有解析出候选条目",
                        description = "记录已经保存在本机，可以稍后在记录详情里补充文字。",
                    )
                } else {
                    extraction.items.forEach { item ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            Text(item.kindName + "：" + item.title, style = MaterialTheme.typography.bodyLarge)
                            Text("截止：" + item.dueText, style = MaterialTheme.typography.bodySmall)
                            item.notes.forEach { note ->
                                Text(
                                    text = "· " + note,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
                if (extraction.warnings.isNotEmpty()) {
                    SectionHeader(title = "服务端提示")
                    extraction.warnings.forEach { warning ->
                        Text(
                            text = "· " + warning,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                TextButton(onClick = { viewModel.dismissExtraction() }) { Text("收起候选") }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}

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
