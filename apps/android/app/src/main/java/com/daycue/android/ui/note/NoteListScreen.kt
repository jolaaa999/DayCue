package com.daycue.android.ui.note

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.EmptyState
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.formatDateTime
import com.daycue.android.ui.rememberContainer

/**
 * 记录列表：搜索 + 浏览。
 *
 * 关键词为空时看最近记录，非空时看检索结果，两者都用同一份空态组件，
 * 因为用户需要知道「是没有记录」还是「只是没搜到」。
 */
@Composable
fun NoteListScreen(
    onOpenNote: (String) -> Unit,
    onNewCapture: () -> Unit,
) {
    val container = rememberContainer()
    val viewModel: NoteListViewModel = viewModel(factory = NoteListViewModel.factory(container))
    val state by viewModel.state.collectAsState()

    DayCueScreen(
        title = "记录",
        actions = { TextButton(onClick = onNewCapture) { Text("记一笔") } },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item {
                OutlinedTextField(
                    value = state.keyword,
                    onValueChange = { viewModel.onKeywordChange(it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp),
                    singleLine = true,
                    label = { Text("搜索标题或正文") },
                )
            }

            state.error?.let { error -> item { MessageCard(text = error, isError = true) } }

            if (state.notes.isEmpty()) {
                item {
                    if (state.keyword.isBlank()) {
                        EmptyState(
                            title = "还没有任何记录",
                            description = "文字、录音、图片都会先存到本机，解析结果会作为笔记留在这里。",
                            actionLabel = "记一笔",
                            onAction = onNewCapture,
                        )
                    } else {
                        EmptyState(
                            title = "没有匹配的记录",
                            description = "换个关键词试试，或者清空搜索框看全部记录。",
                        )
                    }
                }
            } else {
                items(state.notes, key = { it.id }) { note ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 8.dp),
                    ) {
                        Text(note.title, style = MaterialTheme.typography.titleSmall)
                        if (note.body.isNotBlank()) {
                            Text(
                                text = note.body,
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 3,
                            )
                        }
                        Text(
                            text = note.originKind.displayName +
                                " · " + formatDateTime(note.occurredAt ?: note.createdAt) +
                                (if (note.userEdited) " · 已由你修订" else ""),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        TextButton(onClick = { onOpenNote(note.id) }) { Text("打开") }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}
