package com.daycue.android.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.daycue.android.ui.theme.DayCueSpacing
import com.daycue.android.ui.theme.MinTouchTarget

/**
 * 设置项的编辑弹窗。
 *
 * 为什么用「点一行 → 弹窗里改」而不是把输入框全铺在页面上：
 * 上一版设置页把 6 个输入框全部展开，一屏只能看到一个分组，
 * 而这些值平时根本不需要改——它们是配置，不是内容。
 */
@Composable
fun EditTextDialog(
    title: String,
    initial: String,
    label: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
    keyboardType: KeyboardType = KeyboardType.Text,
    supportingText: String? = null,
) {
    var draft by remember(initial) { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    label = { Text(label) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (supportingText != null) {
                    Text(
                        text = supportingText,
                        style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = DayCueSpacing.Small),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(draft) },
                modifier = Modifier.heightIn(min = MinTouchTarget),
            ) { Text("保存") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = MinTouchTarget)) { Text("取消") }
        },
    )
}

/** 两个值的编辑弹窗（学期基准、静默时段都是「一对值」放在一起改）。 */
@Composable
fun EditPairDialog(
    title: String,
    firstLabel: String,
    firstInitial: String,
    secondLabel: String,
    secondInitial: String,
    onDismiss: () -> Unit,
    onConfirm: (String, String) -> Unit,
    firstKeyboardType: KeyboardType = KeyboardType.Text,
    secondKeyboardType: KeyboardType = KeyboardType.Text,
    supportingText: String? = null,
) {
    var first by remember(firstInitial) { mutableStateOf(firstInitial) }
    var second by remember(secondInitial) { mutableStateOf(secondInitial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                OutlinedTextField(
                    value = first,
                    onValueChange = { first = it },
                    label = { Text(firstLabel) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = firstKeyboardType),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = second,
                    onValueChange = { second = it },
                    label = { Text(secondLabel) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = secondKeyboardType),
                    modifier = Modifier.fillMaxWidth().padding(top = DayCueSpacing.Medium),
                )
                if (supportingText != null) {
                    Text(
                        text = supportingText,
                        style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = DayCueSpacing.Small),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(first, second) },
                modifier = Modifier.heightIn(min = MinTouchTarget),
            ) { Text("保存") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = MinTouchTarget)) { Text("取消") }
        },
    )
}

/**
 * 危险操作的二次确认。
 *
 * 确认按钮刻意不用主色：主色意味着「推荐的下一步」，
 * 而删除是这条流程里唯一不应该被顺手点的东西。
 */
@Composable
fun ConfirmDangerDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = onConfirm, modifier = Modifier.heightIn(min = MinTouchTarget)) {
                Text(confirmLabel, color = androidx.compose.material3.MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = MinTouchTarget)) { Text("取消") }
        },
    )
}
