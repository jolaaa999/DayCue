package com.daycue.android.preview

import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.CaptureStatus
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExternalWriteState
import com.daycue.android.domain.model.FollowUpState
import com.daycue.android.domain.model.MemorySourceKind
import com.daycue.android.domain.model.MemoryStatus
import com.daycue.android.domain.model.NoteOriginKind
import com.daycue.android.domain.model.TaskStatus
import com.daycue.android.ui.memory.MemoryGroup
import com.daycue.android.ui.memory.MemorySourceRow
import com.daycue.android.ui.memory.MemoryUiState
import com.daycue.android.ui.note.NoteDetailUiState
import com.daycue.android.ui.note.NoteListUiState
import com.daycue.android.ui.settings.SettingsUiState
import com.daycue.android.ui.today.TodayCaptureItem
import com.daycue.android.ui.today.TodayCourseItem
import com.daycue.android.ui.today.TodayFollowUpItem
import com.daycue.android.ui.today.TodayUiState
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * 演示数据：只给 Compose Preview 与调试画廊用。
 *
 * 为什么要单独一份：要让「有课有待办」「同步异常」这些状态在改界面时可复现，
 * 但绝不能把这些假数据写进真实用户库（那样用户会在真机上看到别人的高数课）。
 * 所以这里全部是内存里的常量，不碰任何 DAO。
 */
object PreviewSamples {

    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")

    private fun at(year: Int, month: Int, day: Int, hour: Int, minute: Int): Instant =
        ZonedDateTime.of(year, month, day, hour, minute, 0, 0, zone).toInstant()

    // ---- 今天页 ----

    /** 全空：刚装完 App、什么都没导入时的样子。 */
    fun todayEmpty(): TodayUiState = TodayUiState(
        loading = false,
        now = at(2026, 10, 26, 20, 15),
    )

    /** 有行程 + 有待办 + 有追问 + 有记录：日常使用时的样子。 */
    fun todayFull(): TodayUiState = TodayUiState(
        loading = false,
        now = at(2026, 10, 26, 20, 15),
        nextCourse = TodayCourseItem(
            instanceId = "ci-1",
            courseName = "高等数学 A",
            startsAt = at(2026, 10, 26, 19, 0),
            endsAt = at(2026, 10, 26, 20, 40),
            location = "教三 201",
            status = CourseInstanceStatus.SCHEDULED,
        ),
        dueTodayTasks = listOf(
            task("t-1", "交数据结构实验报告", at(2026, 10, 26, 22, 0), at(2026, 10, 26, 21, 30)),
            task("t-2", "复习第三章矩阵", at(2026, 10, 26, 23, 30), null),
        ),
        pendingFollowUps = listOf(
            TodayFollowUpItem(
                followUpId = "f-1",
                courseName = "高等数学 A",
                at = at(2026, 10, 26, 20, 50),
                state = FollowUpState.DELIVERED,
                attempt = 1,
            ),
        ),
        todayNotes = listOf(
            note("n-1", "第三章 矩阵与行列式", "行列式按列展开，注意符号交替。", NoteOriginKind.CAPTURE),
            note("n-2", "线性代数作业要求", "第 5、7 题要写出推导过程。", NoteOriginKind.FOLLOW_UP),
        ),
    )

    /** 同步异常：外部写入没完成时，今天页只给一行提示。 */
    fun todayWithSyncIssues(): TodayUiState = todayFull().copy(
        syncIssues = listOf(
            task("t-3", "把课程作业登记到系统提醒", at(2026, 10, 27, 9, 0), null),
            task("t-4", "打印课程讲义", at(2026, 10, 27, 10, 0), null),
        ),
        pendingCaptures = listOf(
            TodayCaptureItem(
                captureId = "c-1",
                kindName = "录音",
                status = CaptureStatus.LOCAL,
                recordedAt = at(2026, 10, 26, 19, 50),
                preview = "这段录音还没有文字内容",
            ),
        ),
    )

    // ---- 记录页 ----

    fun recordsEmpty(): NoteListUiState = NoteListUiState(loaded = true)

    fun recordsList(): NoteListUiState = NoteListUiState(
        keyword = "",
        notes = listOf(
            note("n-1", "第三章 矩阵与行列式", "行列式按列展开，注意符号交替；对角化只对方阵有意义。", NoteOriginKind.CAPTURE),
            note("n-2", "线性代数作业要求", "第 5、7 题要写出推导过程，下周一交。", NoteOriginKind.FOLLOW_UP),
            note("n-3", "论文选题想法", "想做「校园场景下的主动提醒」这个方向，先找三篇近五年的文献。", NoteOriginKind.MANUAL).copy(
                createdAt = at(2026, 10, 25, 21, 10),
                occurredAt = at(2026, 10, 25, 21, 10),
            ),
            note("n-4", "英语听力练习安排", "每天早上 20 分钟，材料用上学期那套。", NoteOriginKind.CAPTURE).copy(userEdited = true),
        ),
        loaded = true,
        // 列表里的「今天/昨天」要有个基准时刻，否则样本只能显示 HH:mm。
        now = at(2026, 10, 26, 21, 0),
    )

    // ---- 记录详情 ----

    /**
     * 一条来自录音的记录：标题、正文、来源原文、同一来源的待办与其他笔记都在。
     *
     * 这一页的状态最难在真机上凑出来（要先录一段音、等识别、再生成笔记），
     * 所以固定数据放在这里，用来做视觉验收。
     */
    fun noteDetail(): NoteDetailUiState {
        val main = note("n-1", "第三章 矩阵与行列式", "行列式按列展开，注意符号交替；对角化只对方阵有意义。", NoteOriginKind.CAPTURE)
        return NoteDetailUiState(
            loading = false,
            note = main,
            now = at(2026, 10, 26, 21, 0),
            titleDraft = main.title,
            bodyDraft = main.body,
            sourceCaptureKind = "录音（已转写）",
            sourceCaptureText = "今天讲了第三章，行列式可以按列展开，符号是交替的；对角化只对方阵有意义，作业里第 5、7 题要写推导。",
            relatedTasks = listOf(
                task("t-1", "交数据结构实验报告", at(2026, 10, 26, 22, 0), at(2026, 10, 26, 21, 30)),
            ),
            relatedNotes = listOf(
                note("n-5", "线性代数作业要求", "第 5、7 题要写出推导过程，下周一交。", NoteOriginKind.CAPTURE),
            ),
        )
    }

    // ---- 记忆页 ----

    fun memoryPending(): MemoryUiState = MemoryUiState(
        // 记忆行的日期要显示成「10月20日」，样本同样需要一个基准时刻。
        now = at(2026, 10, 26, 21, 0),
        attention = listOf(
            memoryItem(
                id = "m-1",
                kind = "learning_state",
                statement = "你通常在晚上复习数学，早上更愿意背英语",
                status = MemoryStatus.CANDIDATE,
                source = MemorySourceKind.INFERRED,
            ),
        ),
        groups = listOf(
            MemoryGroup(
                status = MemoryStatus.CANDIDATE,
                items = listOf(
                    memoryItem(
                        id = "m-1",
                        kind = "learning_state",
                        statement = "你通常在晚上复习数学，早上更愿意背英语",
                        status = MemoryStatus.CANDIDATE,
                        source = MemorySourceKind.INFERRED,
                    ),
                    memoryItem(
                        id = "m-2",
                        kind = "preference",
                        statement = "复习时希望先看例题再看定义",
                        status = MemoryStatus.CANDIDATE,
                        source = MemorySourceKind.INFERRED,
                    ),
                ),
            ),
            MemoryGroup(
                status = MemoryStatus.CONFIRMED,
                items = listOf(
                    memoryItem(
                        id = "m-3",
                        kind = "goal",
                        statement = "这学期想把绩点提到 3.8",
                        status = MemoryStatus.CONFIRMED,
                        source = MemorySourceKind.USER_STATEMENT,
                    ),
                    memoryItem(
                        id = "m-4",
                        kind = "preference",
                        statement = "提醒希望提前 30 分钟，不要更早",
                        status = MemoryStatus.CONFIRMED,
                        source = MemorySourceKind.USER_SETTING,
                    ),
                ),
            ),
        ),
        sourcePolicy = sourcePolicy(),
        loaded = true,
    )

    fun memoryEmpty(): MemoryUiState = MemoryUiState(
        sourcePolicy = sourcePolicy(),
        loaded = true,
    )

    private fun sourcePolicy(): List<MemorySourceRow> = listOf(
        MemorySourceRow(MemorySourceKind.USER_STATEMENT, "你自己说过的话。App 记下的是你的说法，不代表它一定成立"),
        MemorySourceRow(MemorySourceKind.USER_SETTING, "你在设置里选定的偏好，直接按它执行"),
        MemorySourceRow(MemorySourceKind.INFERRED, "系统推断，只作为待确认候选，等你确认后才算事实"),
    )

    // ---- 设置页 ----

    fun settingsHome(): SettingsUiState = SettingsUiState(
        loading = false,
        backendUrl = "http://192.168.1.10:8787",
        tokenStored = true,
        offlineMode = false,
        purelyLocal = false,
        recordingGranted = true,
        cameraGranted = true,
        notificationsGranted = true,
        exactAlarmGranted = false,
        locationName = "GPS",
        locationUsable = true,
        locationRulesEnabled = true,
        termFirstMonday = "2026-09-07",
        termWeeks = "18",
        dailyLimit = "3",
        minIntervalMinutes = "90",
        quietStart = "22:30",
        quietEnd = "08:00",
        noteCount = 12,
        openTaskCount = 3,
        outboxPending = 0,
        themeMode = "system",
    )

    fun settingsHomeLocal(): SettingsUiState = SettingsUiState(
        loading = false,
        tokenStored = false,
        purelyLocal = true,
        termWeeks = "",
        noteCount = 0,
        openTaskCount = 0,
    )

    // ---- 构造小工具 ----

    private fun task(id: String, title: String, dueUtc: Instant?, remindUtc: Instant?): TaskRecord = TaskRecord(
        id = id,
        title = title,
        status = TaskStatus.OPEN,
        dueKind = DueKind.DATETIME,
        dueUtc = dueUtc,
        timezone = zone.id,
        remindUtc = remindUtc,
        externalWriteState = ExternalWriteState.NOT_REQUESTED,
        createdAt = at(2026, 10, 26, 18, 0),
        updatedAt = at(2026, 10, 26, 18, 0),
    )

    private fun note(id: String, title: String, body: String, origin: NoteOriginKind): NoteRecord = NoteRecord(
        id = id,
        title = title,
        body = body,
        originKind = origin,
        occurredAt = at(2026, 10, 26, 19, 30),
        createdAt = at(2026, 10, 26, 19, 30),
        updatedAt = at(2026, 10, 26, 19, 30),
    )

    private fun memoryItem(
        id: String,
        kind: String,
        statement: String,
        status: MemoryStatus,
        source: MemorySourceKind,
    ): MemoryItemRecord = MemoryItemRecord(
        id = id,
        kind = kind,
        statement = statement,
        status = status,
        sourceKind = source,
        createdAt = at(2026, 10, 20, 21, 0),
    )
}
