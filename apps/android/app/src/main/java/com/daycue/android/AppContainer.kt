package com.daycue.android

import android.content.Context
import com.daycue.android.data.local.DayCueDatabase
import com.daycue.android.data.repository.CaptureRepository
import com.daycue.android.data.repository.DeviceRegistrar
import com.daycue.android.data.repository.DeviceReportService
import com.daycue.android.data.repository.DeviceZoneProvider
import com.daycue.android.data.repository.FollowUpRepository
import com.daycue.android.data.repository.GeoProactiveCoordinator
import com.daycue.android.data.repository.MemoryRepository
import com.daycue.android.data.repository.NoteRepository
import com.daycue.android.data.repository.PlaceRepository
import com.daycue.android.data.repository.ProactiveReceiptService
import com.daycue.android.data.repository.ProactiveRepository
import com.daycue.android.data.repository.ScheduleRepository
import com.daycue.android.data.repository.SettingsRepository
import com.daycue.android.data.repository.SyncRepository
import com.daycue.android.data.repository.SystemTimeSource
import com.daycue.android.data.repository.TaskRepository
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.network.DayCueApiClient
import com.daycue.android.core.DayCueId
import com.daycue.android.platform.capability.AndroidDeviceCapabilitySnapshot
import com.daycue.android.platform.capability.CapabilityReport
import com.daycue.android.platform.capability.CapabilityProbe
import com.daycue.android.platform.media.AudioRecorder
import com.daycue.android.domain.location.LocationRuleSwitch
import com.daycue.android.platform.location.AndroidLocationEventSource
import com.daycue.android.platform.location.LocationCapabilityProbe
import com.daycue.android.platform.location.SharedPrefsGeoRuleSwitchMemory
import com.daycue.android.platform.media.MediaStore
import com.daycue.android.platform.notify.AndroidGeoNotifier
import com.daycue.android.platform.notify.ReminderScheduler
import com.daycue.android.platform.security.TokenStore
import com.daycue.android.platform.work.DayCueWorkScheduler
import com.daycue.android.ui.place.LocationPicker
import com.daycue.android.ui.place.PlaceCatalog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

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

    /**
     * 只给「必须由 Activity 发起」的事情用：申请运行时权限需要 Context，
     * 而权限只能在界面层申请。业务代码请直接用对应的仓储或平台能力，不要从这里取 Context。
     */
    val context: Context get() = appContext

    // ---- 内存副本（必须在 init 之前声明：Kotlin 不允许在声明之前使用属性） ----

    @Volatile
    private var cachedBaseUrl: String? = null

    @Volatile
    private var cachedOfflineMode: Boolean = false

    /** 设备 id 的内存副本，见 init 里的说明。 */
    @Volatile
    private var cachedDeviceId: String? = null

    /**
     * 设备时区的唯一取值口。
     *
     * DayCueApiClient 的请求头与设备上报共用它，两处不会各取一个值：
     * 分开取会出现「body 说上海、header 说柏林」这种自己跟自己矛盾的上报。
     */
    private val deviceZoneProvider = DeviceZoneProvider { java.time.ZoneId.systemDefault() }

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

    init {
        // 仓储之间的装配。
        //
        // TaskRepository 的这两个钩子声明成可空、注释写着「由 Application 装配时注入」，
        // 但装配这一步此前从来没做 —— 两个钩子永远是 null，于是：
        //   1) 任务被删除/完成时不写墓碑，对账缺了基准，"删除后同步不复活"就无从谈起；
        //   2) 拿到外部写入回执后不拍快照，三方对账永远拿不到上次的字段值。
        // 这里用回调而不是让两个仓储互相持有实例，避免构造顺序上的循环依赖。
        taskRepository.tombstoneRecorder = { taskId, _ ->
            syncRepository.recordTombstone(SyncRepository.ENTITY_TYPE_TASK, taskId)
        }
        // 快照钩子刻意保持为空。
        //
        // 它本来的语义是「拿到外部写入回执后拍一张字段快照」，但 SyncField 只列
        // "用户可能在任何一端改" 的字段（标题/备注/状态/截止/提醒/清单/地点），
        // 外部 id 不在这层，而且 task 表也还没有 external_id 列。
        // 硬把 id 塞进某个字段会污染对账语义（下次对账会把它当成用户可改的字段去比），
        // 所以这里如实不写：宁可少一张快照，也不要造一条假基准。
        // 接入真实外部提供方时，先给 task 表加 external_id 列，再在这里补真实快照。
    }

    // ---- 平台能力 ----

    val reminderScheduler = ReminderScheduler(appContext)
    val workScheduler = DayCueWorkScheduler(appContext)
    val mediaStore = MediaStore(appContext)
    val audioRecorder = AudioRecorder(appContext)
    val tokenStore = TokenStore(appContext)

    // ---- 地点规则链路 ----

    /**
     * 位置事件源走系统 addProximityAlert（AOSP 的 LocationManager），
     * 因此没有 Google 服务的设备上同样能注册围栏，不需要 GMS 定位依赖。
     */
    val locationEventSource = AndroidLocationEventSource(appContext)

    /** 「用户原本想开着哪些规则」的记忆：定位能力恢复时只放回这些，不会一恢复就全开。 */
    val geoRuleSwitchMemory = SharedPrefsGeoRuleSwitchMemory(appContext)

    val geoNotifier = AndroidGeoNotifier(reminderScheduler)

    /**
     * 地点事件 -> 新鲜度 -> 规则求值 -> 预算 -> 通知 的完整编排。
     *
     * 总开关直接读设置而不是读「规则还是不是 enabled」：位置是敏感能力，
     * 用户关掉总开关就必须真的什么都不做。
     */
    val geoCoordinator = GeoProactiveCoordinator(
        rules = placeRepository,
        ledger = proactiveRepository,
        notifier = geoNotifier,
        source = locationEventSource,
        ruleSwitch = LocationRuleSwitch { settingsRepository.locationRulesEnabled() },
        switchMemory = geoRuleSwitchMemory,
        timeSource = timeSource,
    )

    /** 通知交互回执的落库：地点提醒与课后追问共用同一份状态映射，避免两条路径各写一套。 */
    val receiptService = ProactiveReceiptService(proactiveRepository, timeSource)

    /**
     * 界面读「当前位置」的实现：直接读系统最近一次已知定位。
     *
     * 拿不到就返回 null（权限被拒 / 系统定位关闭 / 从没有过定位），
     * 由界面明确提示而不是填一个默认点——见 LocationPicker 的注释。
     */
    val locationPicker: LocationPicker = LocationPicker {
        LocationCapabilityProbe.lastFix(appContext)?.point
    }

    /** 地点界面需要的地点 / 规则 / 任务 / 能力读取口。 */
    val placeCatalog: PlaceCatalog = object : PlaceCatalog {
        override fun places() = placeRepository.observePlaces()

        override fun rules() = placeRepository.observeRules()

        override fun tasks() = taskRepository.observeOpen()

        override suspend fun capability() = LocationCapabilityProbe.availability(appContext)

        override suspend fun locationRulesEnabled() = settingsRepository.locationRulesEnabled()
    }

    // ---- 网络 ----

    /**
     * 后端地址与离线开关在内存里留一份副本（字段声明在类顶部）。
     *
     * 因为 DayCueApiClient 的 provider 是普通 lambda（不是 suspend），
     * 不能每次发请求都去查数据库；同时又必须让用户在设置页改完地址后立刻生效，
     * 所以用 Room 的 Flow 订阅来同步这份副本。
     */
    val apiClient: DayCueApiClient = DayCueApiClient(
        // 用户打开离线开关时直接当作「没有后端」：宁可在界面里明确说没联网，
        // 也不要一边写着离线一边偷偷发请求。
        baseUrlProvider = { if (cachedOfflineMode) null else cachedBaseUrl },
        tokenProvider = { tokenStore.read() },
        // 每个请求都带本机 IANA 时区：服务端据此维护「用户现在按哪个时区生活」，
        // 预算重置与静默时段都按它算。现读一次而不是缓存，跨时区旅行才不会错位。
        timezoneProvider = { deviceZoneProvider.zoneId().id },
    )

    init {
        applicationScope.launch {
            settingsRepository.observeBackendUrl().collect { cachedBaseUrl = it }
        }
        applicationScope.launch {
            settingsRepository.observeOfflineMode().collect { cachedOfflineMode = it }
        }
        // 设备 id 必须在上报之前就绪，所以这里同步读一次（Room 默认禁止主线程查询，所以走 IO）。
        // 放在异步收集里会有一个真实竞态：启动时的上报可能拿到 null，
        // 结果服务端为这台设备新生成一个 id，而本地之后一直用另一个——推送与能力上报就此分叉。
        cachedDeviceId = runBlocking(Dispatchers.IO) {
            val existing = settingsRepository.deviceId()
            if (existing != null) {
                existing
            } else {
                val created = "dev_" + DayCueId.new().replace("-", "").lowercase()
                settingsRepository.setDeviceId(created)
                created
            }
        }
    }

    // ---- 设备上报 ----

    /**
     * 设备登记 / 能力上报（POST /v1/devices）。
     *
     * 时区走 ZoneId.systemDefault()：这里是设备级时区，不是某条记录的时区，
     * 所以每次上报都现读一次——用户改系统时区之后，下一次上报就会带上新值。
     */
    val deviceReportService = DeviceReportService(
        registrar = DeviceRegistrar { request -> apiClient.upsertDevice(request) },
        capabilities = AndroidDeviceCapabilitySnapshot(appContext),
        zones = deviceZoneProvider,
        deviceIdProvider = { cachedDeviceId },
    )

    /** 是否处于纯本地模式（未配置后端，或用户显式离线）。界面据此决定「先落库」之后提示什么。 */
    fun isPurelyLocal(): Boolean = cachedOfflineMode || cachedBaseUrl.isNullOrBlank()

    /** 能力状态每次现查：用户可能刚从系统设置里改了权限，缓存反而会给出过期结论。 */
    fun capabilities(): CapabilityReport = CapabilityProbe.report(appContext)
}
