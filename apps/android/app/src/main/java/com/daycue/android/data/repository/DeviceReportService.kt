package com.daycue.android.data.repository

import com.daycue.android.domain.contract.DeviceUpsertRequest
import com.daycue.android.domain.contract.DeviceUpsertResponse
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** 上报设备时需要的能力快照。用协议而不是直接依赖 CapabilityReport：服务端不认得 Android 的类。 */
interface DeviceCapabilitySnapshot {
    /** 能力键 -> 是否可用。未知的能力**不要**放进来（服务端把「键不存在」当作未知）。 */
    fun asCapabilityMap(): Map<String, Boolean>

    /** 设备的展示名（例如「Pixel 7」）。 */
    fun deviceName(): String
}

/**
 * 取当前设备的 IANA 时区名。
 *
 * 单独抽一个口子是为了让「上报的时区就是设备时区」这件事可以被断言：
 * 测试里给一个固定 ZoneId，就不必依赖跑测试的机器在哪。
 *
 * 时区不是请求体字段，而是每个已鉴权请求上的 X-DayCue-Timezone 头
 * （服务端在每个请求路径上都会读它）。AppContainer 把同一个取值口接到了 DayCueApiClient，
 * 所以设备上报这一次请求也自然带上了时区。
 */
fun interface DeviceZoneProvider {
    fun zoneId(): ZoneId
}

/** 设备登记客户端的窄口，便于测试替换（声明成 fun interface 才能直接用 lambda 适配真实客户端）。 */
fun interface DeviceRegistrar {
    suspend fun upsert(request: DeviceUpsertRequest): DeviceUpsertResponse
}

/**
 * 设备能力上报。
 *
 * 为什么要有这一步：服务端要靠 device.capabilities 决定「要不要给这台设备推送」，
 * 靠 device.timezone 决定「按哪个时区理解这台设备上的本地时间」。
 * 客户端一直只上报单条请求里的时区，设备级的时区从未上报过——
 * 于是服务端只知道「这条记录写的时候是 Asia/Shanghai」，
 * 不知道「这台设备现在生活在 Asia/Shanghai」。
 *
 * 失败语义：上报失败只记原因、不抛给调用方。它是尽力而为的旁路，
 * 没有后端（纯本地模式）时本就不该发生，也不该影响任何本地功能。
 */
class DeviceReportService(
    private val registrar: DeviceRegistrar,
    private val capabilities: DeviceCapabilitySnapshot,
    private val zones: DeviceZoneProvider,
    private val deviceIdProvider: () -> String?,
    /** 距上次成功上报多久算「该刷新一次」。<=0 表示只在能力变化时上报。 */
    private val refreshIntervalMillis: Long = DEFAULT_REFRESH_INTERVAL_MILLIS,
    /** 取当前毫秒时间。抽成参数是为了让「多久算过期」可以被确定性地断言。 */
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {

    /** 上次**成功**上报的能力快照。null 表示还没成功上报过。 */
    private val lastReported = AtomicReference<Map<String, Boolean>?>(null)

    /** 上次成功上报的时刻。失败不更新，这样下一次回前台能立刻重试而不是等满一个周期。 */
    private val lastAttemptAtMillis = AtomicLong(0L)

    /** 防并发重入：启动上报还没回来时用户又切了一次前台，不该再发一条。 */
    private val inFlight = AtomicBoolean(false)

    /**
     * 上报一次。返回结果供调用方记日志，不抛异常。
     *
     * capabilities 里的未知项由 DeviceCapabilitySnapshot 自己省略，
     * 这里不再做「补一个 false」这种看起来更完整、实际在撒谎的处理。
     */
    suspend fun report(): Result<DeviceReportOutcome> {
        var reportedSnapshot: Map<String, Boolean>? = null
        val result = runCatching {
            val snapshot = capabilities.asCapabilityMap()
            reportedSnapshot = snapshot
            val request = DeviceUpsertRequest(
                id = deviceIdProvider(),
                platform = "android",
                name = capabilities.deviceName(),
                capabilities = snapshot,
            )
            val response = registrar.upsert(request)
            DeviceReportOutcome(
                deviceId = response.id,
                // 时区走请求头，不在这份 body 里；记下来是为了日志能说清「这次按哪个时区上报的」。
                // 用 IANA 名称而不是偏移量：偏移量在夏令时切换时会算错「明晚八点」。
                reportedTimezone = zones.zoneId().id,
                lastSeenAt = response.lastSeenAt,
            )
        }
        // 只有成功才记：失败要能在下一次回前台立刻重试，而不是等满一个刷新周期后
        // 才「有资格」再试一次。
        if (result.isSuccess) {
            reportedSnapshot?.let { lastReported.set(it) }
            lastAttemptAtMillis.set(nowMillis())
        }
        return result
    }

    /**
     * 回前台时按需重报：返回 null 表示「这次不必发请求」。
     *
     * 为什么需要它：能力（尤其通知权限）用户随时可能改。改完返回应用时进程还活着，
     * 启动时那一次上报已经过去了。不重报的话服务端会一直按旧能力决定要不要推送——
     * 用户刚给了通知权限却仍收不到推送，或者刚禁用了通知却还在被推送。
     *
     * 为什么不是每次都发：切界面会频繁触发回前台，每次都发是白烧流量与服务端资源。
     * 只有「能力快照真的变了」或者「距上次成功上报已超过刷新周期」才发。
     */
    suspend fun reportIfStale(): Result<DeviceReportOutcome>? {
        val current = capabilities.asCapabilityMap()
        if (current == lastReported.get()) {
            val elapsed = nowMillis() - lastAttemptAtMillis.get()
            if (refreshIntervalMillis <= 0L || elapsed < refreshIntervalMillis) return null
        }
        // 启动上报还没回来时不必再发一条；那一条成功后会把状态写成最新的。
        if (!inFlight.compareAndSet(false, true)) return null
        return try {
            report()
        } finally {
            inFlight.set(false)
        }
    }

    companion object {
        /**
         * 默认刷新周期：30 分钟。
         *
         * 取值的理由：这个周期的用途是刷新服务端的 last_seen_at（判断设备是否还活着），
         * 不是能力同步——能力变化会立刻触发上报。所以它不需要太短；
         * 太长则设备被判定失效的时间会明显滞后。
         */
        const val DEFAULT_REFRESH_INTERVAL_MILLIS = 30L * 60L * 1000L
    }
}

/** 一次上报的结果。单独一个类型是为了让日志能说清「用的是哪个时区、服务端认的是哪台设备」。 */
data class DeviceReportOutcome(
    val deviceId: String,
    val reportedTimezone: String?,
    val lastSeenAt: String?,
)
