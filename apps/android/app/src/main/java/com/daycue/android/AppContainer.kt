package com.daycue.android

import android.content.Context
import com.daycue.android.data.local.DayCueDatabase
import com.daycue.android.data.repository.CaptureRepository
import com.daycue.android.data.repository.FollowUpRepository
import com.daycue.android.data.repository.MemoryRepository
import com.daycue.android.data.repository.NoteRepository
import com.daycue.android.data.repository.PlaceRepository
import com.daycue.android.data.repository.ProactiveRepository
import com.daycue.android.data.repository.ScheduleRepository
import com.daycue.android.data.repository.SettingsRepository
import com.daycue.android.data.repository.SyncRepository
import com.daycue.android.data.repository.SystemTimeSource
import com.daycue.android.data.repository.TaskRepository
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.network.DayCueApiClient
import com.daycue.android.platform.capability.CapabilityReport
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.media.AudioRecorder
import com.daycue.android.platform.media.MediaStore
import com.daycue.android.platform.notify.ReminderScheduler
import com.daycue.android.platform.security.TokenStore
import com.daycue.android.platform.work.DayCueWorkScheduler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * 手写依赖容器。
 *
 * 为什么不用 Hilt：整个 App 只有一个生命周期作用域（Application），
 * 依赖关系是单向的一棵树，引入注解处理器只会让构建更慢、让 KSP 里多一个可能出错的环节。
 *
 * 所有字段都是**饿汉式**的：数据库与仓储的构造不能抛异常、也不能做 IO，
 * 所以它们是建好即用的对象，真正的 IO 都发生在 suspend 方法里。
 */
class AppContainer(context: Context) {

    private val appContext: Context = context.applicationContext

    val database: DayCueDatabase = DayCueDatabase.build(appContext)

    val timeSource: TimeSource = SystemTimeSource

    /** 应用级作用域：只用于「读设置到内存缓存」这类没有界面生命周期约束的活。 */
    val applicationScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // ---- 仓储 ----

    val captureRepository = CaptureRepository(database.captureDao(), timeSource)
    val noteRepository = NoteRepository(database.noteDao(), timeSource)
    val taskRepository = TaskRepository(database.taskDao(), database.outboxDao(), timeSource)
    val scheduleRepository = ScheduleRepository(
        database.courseDao(),
        database.courseScheduleRuleDao(),
        database.courseInstanceDao(),
        timeSource,
    )
    val proactiveRepository = ProactiveRepository(database.proactiveMessageDao(), timeSource)
    val followUpRepository = FollowUpRepository(
        database.followUpDao(),
        database.followUpReplyDao(),
        database.courseInstanceDao(),
        database.courseDao(),
        noteRepository,
        proactiveRepository,
        timeSource,
    )
    val memoryRepository = MemoryRepository(database.memoryDao(), timeSource)
    val placeRepository = PlaceRepository(database.placeDao(), database.geoRuleDao(), timeSource)
    val syncRepository = SyncRepository(
        database.outboxDao(),
        database.syncCursorDao(),
        database.syncTombstoneDao(),
        database.syncSnapshotDao(),
        database.taskDao(),
        timeSource,
    )
    val settingsRepository = SettingsRepository(database.appSettingDao(), timeSource)

    // ---- 平台能力 ----

    val reminderScheduler = ReminderScheduler(appContext)
    val workScheduler = DayCueWorkScheduler(appContext)
    val mediaStore = MediaStore(appContext)
    val audioRecorder = AudioRecorder(appContext)
    val tokenStore = TokenStore(appContext)

    // ---- 网络 ----

    /**
     * 后端地址与离线开关在内存里留一份副本。
     *
     * 因为 DayCueApiClient 的 provider 是普通 lambda（不是 suspend），
     * 不能每次发请求都去查数据库；同时又必须让用户在设置页改完地址后立刻生效，
     * 所以用 Room 的 Flow 订阅来同步这份副本。
     */
    @Volatile
    private var cachedBaseUrl: String? = null

    @Volatile
    private var cachedOfflineMode: Boolean = false

    val apiClient: DayCueApiClient = DayCueApiClient(
        // 用户打开离线开关时直接当作「没有后端」：宁可在界面里明确说没联网，
        // 也不要一边写着离线一边偷偷发请求。
        baseUrlProvider = { if (cachedOfflineMode) null else cachedBaseUrl },
        tokenProvider = { tokenStore.read() },
    )

    init {
        applicationScope.launch {
            settingsRepository.observeBackendUrl().collect { cachedBaseUrl = it }
        }
        applicationScope.launch {
            settingsRepository.observeOfflineMode().collect { cachedOfflineMode = it }
        }
    }

    /** 是否处于纯本地模式（未配置后端，或用户显式离线）。界面据此决定「先落库」之后提示什么。 */
    fun isPurelyLocal(): Boolean = cachedOfflineMode || cachedBaseUrl.isNullOrBlank()

    /** 能力状态每次现查：用户可能刚从系统设置里改了权限，缓存反而会给出过期结论。 */
    fun capabilities(): CapabilityReport = CapabilityProbe.report(appContext)
}
