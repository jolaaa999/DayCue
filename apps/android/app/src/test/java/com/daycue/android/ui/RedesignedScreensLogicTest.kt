package com.daycue.android.ui

import com.daycue.android.core.DayCueTime
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.ui.capture.SavedText
import com.daycue.android.ui.capture.resolveExtractTarget
import com.daycue.android.ui.capture.savedTextAfterEdit
import com.daycue.android.ui.note.NoteListUiState
import com.daycue.android.ui.settings.hostOf
import com.daycue.android.ui.theme.ThemeMode
import com.daycue.android.ui.today.TodayUiState
import com.daycue.android.ui.today.greetingFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * 这一轮界面重构里「决定看到什么」的那些纯规则。
 *
 * 为什么这些值得单测：它们决定今天页是铺开分区还是给一句引导、记录页是空态还是列表，
 * 而这类判断一旦写错，表现是「明明有数据却显示空」——在真机上很难一眼看出来，
 * 但用状态对象直接断言就能钉住。
 */
class RedesignedScreensLogicTest {

    // ---- 今天页：有没有内容 ----

    @Test
    fun emptyTodayHasNoContent() {
        assertFalse(TodayUiState().hasContent)
    }

    @Test
    fun anyRealDataCountsAsContent() {
        assertTrue(TodayUiState(dueTodayTasks = listOf(sampleTask())).hasContent)
        // 「下一次课」的提示也算内容：用户能看到下一次课在哪天，就不该再说「今天还没有安排」。
        assertTrue(TodayUiState(laterCourseHint = "高等数学 A · 2026-10-28 08:00").hasContent)
    }

    @Test
    fun noticesAloneAreNotContent() {
        // 「同步异常」「待处理记录」是提示，不是今天要做的事：只有它们的时候，
        // 页面仍然要给出「今天还没有安排」的引导，而不是一片空白加一条提示。
        assertFalse(
            TodayUiState(
                pendingCaptures = listOf(
                    com.daycue.android.ui.today.TodayCaptureItem(
                        captureId = "c-1",
                        kindName = "录音",
                        status = com.daycue.android.domain.model.CaptureStatus.LOCAL,
                        recordedAt = Instant.parse("2026-10-26T10:00:00Z"),
                        preview = "这段录音还没有文字内容",
                    ),
                ),
            ).hasContent,
        )
    }

    @Test
    fun outboxBacklogAloneIsNotContent() {
        // outboxPending 是等待重试的操作数，不是「今天要做什么」；
        // 它只在同步异常里体现，单独一个积压不应该把「今天还没有安排」的引导顶掉。
        assertFalse(TodayUiState(outboxPending = 5).hasContent)
    }

    // ---- 今天页：问候 ----

    @Test
    fun greetingSegmentsHaveExplicitBoundaries() {
        assertEquals("早上好", greetingFor(5))
        assertEquals("早上好", greetingFor(10))
        assertEquals("中午好", greetingFor(11))
        assertEquals("下午好", greetingFor(17))
        assertEquals("晚上好", greetingFor(18))
        assertEquals("晚上好", greetingFor(22))
        assertEquals("夜深了", greetingFor(23))
        assertEquals("夜深了", greetingFor(3))
    }

    // ---- 记录页：筛选 ----

    @Test
    fun filterNullKeepsOriginalList() {
        val state = NoteListUiState(
            notes = listOf(sampleNote("1", NoteOriginKind.CAPTURE), sampleNote("2", NoteOriginKind.MANUAL)),
        )
        assertEquals(2, state.visibleNotes.size)
    }

    @Test
    fun filterKeepsOnlyMatchingOriginAndLeavesSourceIntact() {
        val state = NoteListUiState(
            notes = listOf(sampleNote("1", NoteOriginKind.CAPTURE), sampleNote("2", NoteOriginKind.MANUAL)),
            filter = NoteOriginKind.MANUAL,
        )
        assertEquals(1, state.visibleNotes.size)
        assertEquals("2", state.visibleNotes.first().id)
        assertEquals(2, state.notes.size)
    }

    @Test
    fun emptyStateOnlyWhenThereIsReallyNoRecord() {
        assertTrue(NoteListUiState(loaded = true).trulyEmpty)
        // 有关键词时不算「一条都没有」：这时该显示「没有匹配」而不是「还没有记录」。
        assertFalse(NoteListUiState(loaded = true, keyword = "矩阵").trulyEmpty)
    }

    // ---- 设置：地址摘要 ----

    @Test
    fun hostOnlyKeepsHostAndPort() {
        assertEquals("192.168.1.10:8787", hostOf("http://192.168.1.10:8787"))
        assertEquals("192.168.1.10:8787", hostOf("http://192.168.1.10:8787/"))
        assertEquals("未配置后端", hostOf(""))
        assertEquals("未配置后端", hostOf("   "))
    }

    // ---- 外观：偏好解析 ----

    @Test
    fun themeModeFallsBackToSystemOnDirtyValue() {
        assertEquals(ThemeMode.SYSTEM, ThemeMode.fromRaw(null))
        assertEquals(ThemeMode.SYSTEM, ThemeMode.fromRaw(""))
        assertEquals(ThemeMode.SYSTEM, ThemeMode.fromRaw("purple"))
        assertEquals(ThemeMode.LIGHT, ThemeMode.fromRaw("light"))
        assertEquals(ThemeMode.DARK, ThemeMode.fromRaw("dark"))
    }

    // ---- 页头时间 ----

    @Test
    fun headerDateUsesFixedChineseWeekday() {
        val zone = ZoneId.of("Asia/Shanghai")
        val instant = Instant.parse("2026-10-26T12:15:00Z") // 上海时间 20:15，周一
        assertEquals("10月26日 周一", DayCueTime.displayMonthDayWeekday(instant, zone))
        assertEquals("20:15", DayCueTime.displayClock(instant, zone))
    }

    private fun sampleTask(): TaskRecord = TaskRecord(
        id = "t-1",
        title = "交作业",
        dueKind = DueKind.NONE,
        timezone = "Asia/Shanghai",
        createdAt = Instant.parse("2026-10-26T10:00:00Z"),
        updatedAt = Instant.parse("2026-10-26T10:00:00Z"),
    )

    private fun sampleNote(id: String, origin: NoteOriginKind): NoteRecord = NoteRecord(
        id = id,
        title = "标题" + id,
        body = "",
        originKind = origin,
        createdAt = Instant.parse("2026-10-26T10:00:00Z"),
        updatedAt = Instant.parse("2026-10-26T10:00:00Z"),
    )


    // ---- 列表里的时间语义 ----

    @Test
    fun listTimeUsesRelativeDayThenDate() {
        val zone = ZoneId.of("Asia/Shanghai")
        val now = instantAt(zone, 2026, 10, 26, 21, 0)
        // 记录行原来只印 HH:mm，隔天的记录看起来和刚写的一模一样。
        assertEquals("今天 19:30", DayCueTime.displayDayTime(instantAt(zone, 2026, 10, 26, 19, 30), now, zone))
        assertEquals("昨天 19:30", DayCueTime.displayDayTime(instantAt(zone, 2026, 10, 25, 19, 30), now, zone))
        // 同年更早补月日，跨年再补年份：只说「10月20日」会让用户误以为是今年。
        assertEquals("10月20日 08:05", DayCueTime.displayDayTime(instantAt(zone, 2026, 10, 20, 8, 5), now, zone))
        assertEquals("2025年12月31日 23:59", DayCueTime.displayDayTime(instantAt(zone, 2025, 12, 31, 23, 59), now, zone))
    }

    @Test
    fun minutesBetweenIsSigned() {
        val zone = ZoneId.of("Asia/Shanghai")
        val now = instantAt(zone, 2026, 10, 26, 20, 15)
        // 课程卡的「40 分钟后」直接来自这个差值，正负号不能反。
        assertEquals(40L, DayCueTime.minutesBetween(now, instantAt(zone, 2026, 10, 26, 20, 55)))
        assertEquals(-15L, DayCueTime.minutesBetween(now, instantAt(zone, 2026, 10, 26, 20, 0)))
    }


    // ---- 记一笔：「保存后提取」必须绑到明确的那条记录 ----

    @Test
    fun extractTargetPrefersWhatUserJustTyped() {
        // 输入框有字时永远解析新内容，哪怕手边还留着上一次的绑定。
        val target = resolveExtractTarget(
            typed = "  周五前交报告 ",
            saved = SavedText(captureId = "cap_old", text = "上一次的文字"),
        )
        assertEquals("周五前交报告", target?.text)
        assertEquals(null, target?.captureId)
        assertTrue(target!!.needsSave)
    }

    @Test
    fun extractTargetFallsBackToTheSavedCapture() {
        val target = resolveExtractTarget(typed = "", saved = SavedText(captureId = "cap_1", text = "已经存好的文字"))
        assertEquals("cap_1", target?.captureId)
        assertEquals("已经存好的文字", target?.text)
        assertFalse(target!!.needsSave)
    }

    @Test
    fun extractTargetIsNullWithoutAnyText() {
        // 什么都没写、也没有刚保存的记录：给 null，让界面如实说「没有可解析的文字」。
        assertEquals(null, resolveExtractTarget(typed = "   ", saved = null))
    }

    @Test
    fun typingNewTextDropsTheSavedBinding() {
        val saved = SavedText(captureId = "cap_1", text = "上一次的文字")
        // 开始写新内容 → 旧绑定作废，避免「输入框是 B、解析的却是 A」。
        assertEquals(null, savedTextAfterEdit("新的内容", saved))
        // 只是清空输入框（比如刚保存完）时绑定要保留，否则两个动作串不起来。
        assertEquals(saved, savedTextAfterEdit("   ", saved))
    }

    private fun instantAt(zone: ZoneId, year: Int, month: Int, day: Int, hour: Int, minute: Int): Instant =
        java.time.ZonedDateTime.of(year, month, day, hour, minute, 0, 0, zone).toInstant()
}
