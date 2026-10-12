package com.daycue.android.data.repository

import com.daycue.android.domain.contract.DeviceUpsertRequest
import com.daycue.android.domain.contract.DeviceUpsertResponse
import java.time.ZoneId

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
) {

    /**
     * 上报一次。返回结果供调用方记日志，不抛异常。
     *
     * capabilities 里的未知项由 DeviceCapabilitySnapshot 自己省略，
     * 这里不再做「补一个 false」这种看起来更完整、实际在撒谎的处理。
     */
    suspend fun report(): Result<DeviceReportOutcome> = runCatching {
        val request = DeviceUpsertRequest(
            id = deviceIdProvider(),
            platform = "android",
            name = capabilities.deviceName(),
            capabilities = capabilities.asCapabilityMap(),
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
}

/** 一次上报的结果。单独一个类型是为了让日志能说清「用的是哪个时区、服务端认的是哪台设备」。 */
data class DeviceReportOutcome(
    val deviceId: String,
    val reportedTimezone: String?,
    val lastSeenAt: String?,
)
