package com.daycue.android.ui.followup

import androidx.activity.compose.rememberLauncherForActivityResult
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
import androidx.compose.material3.HorizontalDivider
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
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.rememberContainer

/**
 * 课后追问页。
 *
 * 分「待回复」与「已回复」两段：待回复的每条都必须说明「为什么现在问」，
 * 已回复的保留回复原文（语音回复只有音频路径时也要如实说明，不能显示成有文字）。
 */
@Composable
fun FollowUpScreen(
    onBack: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    val container = rememberContainer()
    val viewModel: FollowUpViewModel = viewModel(factory = FollowUpViewModel.factory(container))
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current

    // 权限弹窗是异步的，回来时必须知道「用户当初点的是哪一条」，否则会把录音记到别的追问上。
    var pendingRecordId by remember { mutableStateOf<String?>(null) }

    val recordPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val target = pendingRecordId
        pendingRecordId = null
        if (granted && target != null) {
            viewModel.startRecording(target)
        } else {
            viewModel.clearMessages()
        }
    }

    DayCueScreen(title = "课后追问", onBack = onBack) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            state.error?.let { MessageCard(text = it, isError = true) }
            state.message?.let { MessageCard(text = it) }

            SectionHeader(
                title = "待回复",
                subtitle = "由课表与课程策略生成；停课、调课后会自动重排",
            )
            if (state.outstanding.isEmpty()) {
                EmptyState(
                    title = "没有待回复的追问",
                    description = "如果课程没开启课后追问，或者这周还没上过课，这里就会是空的。",
                )
            } else {
                state.outstanding.forEach { item ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        Text(item.courseName, style = MaterialTheme.typography.titleSmall)
                        Text(
                            text = item.state.displayName + " · 计划 " + formatDateTime(item.snoozeUntil ?: item.scheduledAt),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(item.whyNow, style = MaterialTheme.typography.bodySmall)

                        OutlinedTextField(
                            value = state.drafts[item.followUpId].orEmpty(),
                            onValueChange = { text -> viewModel.onDraftChange(item.followUpId, text) },
                            modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                            minLines = 2,
                            label = { Text("这节课你学到了什么、还有什么疑问") },
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { viewModel.answer(item.followUpId) }, enabled = !state.busy) {
                                Text("发送回复")
                            }
                            if (state.recordingId == item.followUpId) {
                                OutlinedButton(onClick = { viewModel.stopRecording() }) { Text("停止并保存") }
                                TextButton(onClick = { viewModel.cancelRecording() }) { Text("取消录音") }
                            } else {
                                OutlinedButton(
                                    onClick = {
                                        if (PermissionCenter.hasRecording(context)) {
                                            viewModel.startRecording(item.followUpId)
                                        } else {
                                            pendingRecordId = item.followUpId
                                            recordPermission.launch(PermissionCenter.RECORD_AUDIO)
                                        }
                                    },
                                    enabled = state.recordingId == null && !state.busy,
                                ) { Text("语音回复") }
                            }
                        }
                        if (state.recordingId == item.followUpId) {
                            Text(
                                text = "已录 " + state.elapsedSeconds.toString() + " 秒",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }

                        Text("稍后再说", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            SnoozeOption.entries.forEach { option ->
                                TextButton(onClick = { viewModel.snooze(item.followUpId, option) }) {
                                    Text(option.displayName)
                                }
                            }
                            TextButton(onClick = { viewModel.skip(item.followUpId) }) { Text("跳过") }
                        }
                        HorizontalDivider()
                    }
                }
            }

            SectionHeader(
                title = "已回复",
                subtitle = "回复会归档成课堂记录，可以继续在记录页编辑",
            )
            if (state.answered.isEmpty()) {
                EmptyState(
                    title = "还没有回复过追问",
                    description = "回复过的追问会连同课堂记录一起留在这里，方便回看。",
                )
            } else {
                state.answered.forEach { item ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        Text(item.courseName, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            text = formatDateTime(item.answeredAt ?: java.time.Instant.EPOCH),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        val replyText = item.replyText
                        if (replyText != null) {
                            Text(replyText, style = MaterialTheme.typography.bodyMedium)
                        } else if (item.audioPath != null) {
                            Text(
                                text = "这条是语音回复，还没有转写文本（音频保存在本机：" + item.audioPath + "）。",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        } else {
                            Text(
                                text = "这条追问已标记为回答，但没有找到归档的回复内容。",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                        item.noteId?.let { noteId ->
                            TextButton(onClick = { onOpenNote(noteId) }) { Text("查看归档记录") }
                        }
                        HorizontalDivider()
                    }
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }
}
