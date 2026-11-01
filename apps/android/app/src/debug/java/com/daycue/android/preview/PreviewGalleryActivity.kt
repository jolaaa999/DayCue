package com.daycue.android.preview

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import com.daycue.android.ui.memory.MemoryContent
import com.daycue.android.ui.note.NoteDetailContent
import com.daycue.android.ui.note.NoteListContent
import com.daycue.android.ui.settings.SettingsHomeContent
import com.daycue.android.ui.theme.DayCueTheme
import com.daycue.android.ui.today.TodayContent

/**
 * 调试用的「独立展示场景」。
 *
 * 为什么需要它：今天页的「同步异常」「有课有待办」这类状态要靠真实数据凑出来，
 * 而现在设备上还没有任何数据。把纯展示内容抽出来之后，这里就能用固定假数据
 * 渲染出一模一样的界面，用来做视觉验收——注意，这些假数据只活在这个 debug 源集里，
 * 不会进 release 包，更不会写进用户数据库。
 *
 * 用法（真机截图）：
 *   adb shell am start -n com.daycue.android/.preview.PreviewGalleryActivity \
 *     --es scene today_full --es dark 1
 */
class PreviewGalleryActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val scene = intent?.getStringExtra("scene").orEmpty()
        val dark = intent?.getStringExtra("dark") == "1"
        setContent {
            DayCueTheme(darkTheme = dark) {
                PreviewGalleryScene(scene = scene)
            }
        }
    }
}

/** 场景名与截图脚本里的 --es scene 取值一一对应。 */
@Composable
fun PreviewGalleryScene(scene: String) {
    when (scene) {
        "today_empty" -> TodayContent(
            state = PreviewSamples.todayEmpty(),
            onRefresh = {},
            onCompleteTask = {},
            onOpenTasks = {},
            onOpenSchedule = {},
            onOpenFollowUp = {},
            onOpenCapture = {},
            onOpenRecords = {},
            onOpenSettings = {},
            onOpenNote = {},
        )

        "today_full" -> TodayContent(
            state = PreviewSamples.todayFull(),
            onRefresh = {},
            onCompleteTask = {},
            onOpenTasks = {},
            onOpenSchedule = {},
            onOpenFollowUp = {},
            onOpenCapture = {},
            onOpenRecords = {},
            onOpenSettings = {},
            onOpenNote = {},
        )

        "today_sync" -> TodayContent(
            state = PreviewSamples.todayWithSyncIssues(),
            onRefresh = {},
            onCompleteTask = {},
            onOpenTasks = {},
            onOpenSchedule = {},
            onOpenFollowUp = {},
            onOpenCapture = {},
            onOpenRecords = {},
            onOpenSettings = {},
            onOpenNote = {},
        )

        "records_empty" -> NoteListContent(
            state = PreviewSamples.recordsEmpty(),
            onKeywordChange = {},
            onFilterChange = {},
            onOpenNote = {},
            onNewCapture = {},
        )

        "records_list" -> NoteListContent(
            state = PreviewSamples.recordsList(),
            onKeywordChange = {},
            onFilterChange = {},
            onOpenNote = {},
            onNewCapture = {},
        )

        "note_detail" -> NoteDetailContent(
            state = PreviewSamples.noteDetail(),
            onBack = {},
            onTitleChange = {},
            onBodyChange = {},
            onSave = {},
            onDelete = {},
        )

        "memory_pending" -> MemoryContent(
            state = PreviewSamples.memoryPending(),
            onConfirm = {},
            onRetire = {},
            onDelete = {},
            onOpenCapture = {},
        )

        "memory_empty" -> MemoryContent(
            state = PreviewSamples.memoryEmpty(),
            onConfirm = {},
            onRetire = {},
            onDelete = {},
            onOpenCapture = {},
        )

        "settings_home" -> SettingsHomeContent(
            state = PreviewSamples.settingsHome(),
            onOpenAccount = {},
            onOpenProactive = {},
            onOpenLocation = {},
            onOpenTerm = {},
            onOpenPermissions = {},
            onOpenAppearance = {},
            onOpenData = {},
            onOpenAdvanced = {},
            onOpenAssistant = {},
        )

        "settings_home_local" -> SettingsHomeContent(
            state = PreviewSamples.settingsHomeLocal(),
            onOpenAccount = {},
            onOpenProactive = {},
            onOpenLocation = {},
            onOpenTerm = {},
            onOpenPermissions = {},
            onOpenAppearance = {},
            onOpenData = {},
            onOpenAdvanced = {},
            onOpenAssistant = {},
        )

        else -> TodayContent(
            state = PreviewSamples.todayEmpty(),
            onRefresh = {},
            onCompleteTask = {},
            onOpenTasks = {},
            onOpenSchedule = {},
            onOpenFollowUp = {},
            onOpenCapture = {},
            onOpenRecords = {},
            onOpenSettings = {},
            onOpenNote = {},
        )
    }
}

// ---------------------------------------------------------------------------
// Android Studio 里的 Compose Preview：同样调用上面的纯展示内容，
// 数据集与调试画廊完全一致，避免「预览图与真机不一致」。
// ---------------------------------------------------------------------------

@Preview(name = "今天 · 全空 · 亮色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewTodayEmpty() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("today_empty") }

@Preview(name = "今天 · 全空 · 深色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewTodayEmptyDark() = DayCueTheme(darkTheme = true) { PreviewGalleryScene("today_empty") }

@Preview(name = "今天 · 有行程与任务", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewTodayFull() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("today_full") }

@Preview(name = "今天 · 同步异常", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewTodaySync() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("today_sync") }

@Preview(name = "今天 · 大字号", widthDp = 411, heightDp = 892, fontScale = 1.3f, showBackground = true)
@Composable
private fun PreviewTodayLargeFont() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("today_full") }

@Preview(name = "记录 · 空状态", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewRecordsEmpty() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("records_empty") }

@Preview(name = "记录 · 列表 · 深色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewRecordsListDark() = DayCueTheme(darkTheme = true) { PreviewGalleryScene("records_list") }

@Preview(name = "记录 · 详情 · 亮色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewNoteDetail() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("note_detail") }

@Preview(name = "记录 · 详情 · 深色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewNoteDetailDark() = DayCueTheme(darkTheme = true) { PreviewGalleryScene("note_detail") }

@Preview(name = "记忆 · 待确认", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewMemoryPending() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("memory_pending") }

@Preview(name = "记忆 · 空状态", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewMemoryEmpty() = DayCueTheme(darkTheme = true) { PreviewGalleryScene("memory_empty") }

@Preview(name = "设置 · 首页 · 亮色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewSettingsHome() = DayCueTheme(darkTheme = false) { PreviewGalleryScene("settings_home") }

@Preview(name = "设置 · 首页 · 深色", widthDp = 411, heightDp = 892, showBackground = true)
@Composable
private fun PreviewSettingsHomeDark() = DayCueTheme(darkTheme = true) { PreviewGalleryScene("settings_home") }
