package com.daycue.android.domain.location

import com.daycue.android.domain.model.PlaceTrigger
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * 定位能力。
 *
 * 为什么放在领域层：产品底线是「定位不可用时绝不使用陈旧位置」，
 * 这条判断必须能在没有 Android 框架的环境里被测到。平台层（LocationCapabilityProbe）
 * 只负责探测，不参与判定。
 *
 * 全项目只保留这一个能力枚举：此前 data 层的 LocationAvailability 与它语义重复，
 * 两个枚举各自演化必然漂移，而「界面上说能用、实际排不上」正是漂移的典型后果。
 */
enum class LocationCapability(val displayName: String) {
    AVAILABLE("定位可用"),
    PERMISSION_DENIED("未授予定位权限"),
    PROVIDER_DISABLED("系统定位服务已关闭"),
    HARDWARE_MISSING("本机没有定位硬件"),
    UNSUPPORTED("当前设备不支持定位能力"),
    ;

    val isUsable: Boolean get() = this == AVAILABLE

    /**
     * 完全不可用时的中文原因；可用时为 null。
     * 界面直接展示这句话，所以不能出现「未知错误」这种没有信息量的兜底。
     */
    val unavailableReason: String?
        get() = when (this) {
            AVAILABLE -> null
            PERMISSION_DENIED ->
                "定位权限被拒绝或尚未授予，地点规则不会触发。DayCue 不会用其它线索推断你在哪里。"
            PROVIDER_DISABLED ->
                "系统定位服务已关闭，地点规则不会触发。请在系统设置里打开定位服务。"
            HARDWARE_MISSING -> "本机没有定位硬件，地点规则无法工作。"
            UNSUPPORTED -> "当前设备不支持定位能力，地点规则无法工作。"
        }
}

/**
 * 一次围栏状态变化的语义描述。
 *
 * 事件源只产出这四种，**不产出坐标**：坐标属于「观测」，语义属于「事件」，
 * 两者分开，规则判定才不必依赖任何定位框架。
 */
sealed interface LocationEventKind {

    /** 刚刚进入围栏。 */
    data object Entered : LocationEventKind

    /** 刚刚离开围栏。 */
    data object Exited : LocationEventKind

    /**
     * 仍在围栏内。insideSince 是本次连续停留的起始时刻；
     * 拿不到它就应当改发 Indeterminate，而不是用「现在」冒充。
     */
    data class Dwell(val insideSince: Instant) : LocationEventKind

    /** 系统给了变化但状态无法确定（拿不到坐标、状态未知、定位报错）。 */
    data class Indeterminate(val reason: String) : LocationEventKind

    /** 与 PlaceTrigger 的对应关系。无法确定时没有对应规则，因此返回 null。 */
    val trigger: PlaceTrigger?
        get() = when (this) {
            Entered -> PlaceTrigger.ENTER
            Exited -> PlaceTrigger.EXIT
            is Dwell -> PlaceTrigger.DWELL
            is Indeterminate -> null
        }

    /**
     * 事件蕴含的「上一次状态 -> 当前状态」。
     * enter 必然是 外部 -> 内部，exit 必然是 内部 -> 外部；
     * 这样调用方不必自己维护上一次状态，也就不会和事件语义打架。
     */
    val impliedTransition: GeoTransition?
        get() = when (this) {
            Entered -> GeoTransition.ENTERED
            Exited -> GeoTransition.EXITED
            is Dwell -> GeoTransition.NONE
            is Indeterminate -> null
        }
}

/**
 * 事件源递进来的原始观测。
 *
 * 刻意不带任何 Android 类型：适配层负责把系统给的坐标、时间戳与精度拆成标量，
 * 领域层只关心「这份观测还能不能代表现在」。
 */
data class RawLocationObservation(
    val placeId: String,
    val kind: LocationEventKind,
    /**
     * 观测时刻。用系统给出的定位时间（Location.time），而不是回调被执行的时刻——
     * 后者会把一份陈旧的坐标包装成新鲜的，正是新鲜度检查要防的事。
     * 系统围栏广播不提供事件时间，那种情况下由适配层传入收到广播的时刻，并在注释里说明。
     */
    val observedAt: Instant,
    /**
     * 系统给出的水平精度（米）。null 表示「系统没有提供精度」，
     * 与「精度为 0」是两回事：0 或负数是无效值，必须丢弃；null 只出现在系统围栏事件上，
     * 那种事件本来就不是坐标采样，不能因此把围栏整个废掉。
     */
    val horizontalAccuracyMeters: Double?,
    val capability: LocationCapability,
    /** 此前连续在围栏内的起始时刻（若已知）。离开事件靠它算出去重键里的「同一次进入」。 */
    val insideSince: Instant? = null,
)

/**
 * 新鲜度阈值。
 *
 * 集中一处并允许显式传入，测试才能给出确定结论，产品也能按需要收紧。
 * 默认值对齐 iOS 的 LocationFreshnessPolicy.standard（2 分钟 / 150 米 / 30 秒）。
 */
data class LocationFreshnessPolicy(
    /** 观测时刻到「现在」的最大允许间隔（秒）。 */
    val maximumAgeSeconds: Long = 120,
    /** 允许的最大水平精度（米）。 */
    val maximumHorizontalAccuracyMeters: Double = 150.0,
    /** 时间戳最多允许超前多少秒。超过就判为设备时钟异常。 */
    val maximumFutureSkewSeconds: Long = 30,
) {
    companion object {
        val STANDARD = LocationFreshnessPolicy()
    }
}

/** 通过新鲜度检查的语义事件。 */
data class LocationSemanticEvent(
    val placeId: String,
    val kind: LocationEventKind,
    val observedAt: Instant,
    val horizontalAccuracyMeters: Double?,
    val capability: LocationCapability,
    val trigger: PlaceTrigger,
    val transition: GeoTransition,
    /** 进入围栏的时刻，用于停留判定；未知时为 null。 */
    val insideSince: Instant?,
)

/**
 * 被丢弃的观测。丢弃必须有名字和原因，
 * 否则「规则为什么没触发」就无法区分「没到条件」和「位置不可信」。
 */
data class LocationEventDiscard(
    val placeId: String,
    val reason: String,
    /** 静默降级（位置不可用、观测太旧）为 true；规则自身原因（规则关闭等）为 false。 */
    val isSilent: Boolean,
    val at: Instant,
)

/** 新鲜度判定的结果。 */
sealed interface LocationEventNormalization {

    data class Accepted(val event: LocationSemanticEvent) : LocationEventNormalization

    data class Discarded(val reason: String, val isSilent: Boolean) : LocationEventNormalization
}

/**
 * 标准化与新鲜度判定。
 *
 * 判定顺序刻意从「环境能不能信」开始：
 * 1. 能力不可用 -> 丢弃（静默降级）；
 * 2. 事件本身无法确定 -> 丢弃，绝不把「不知道」当成 outside；
 * 3. 时间戳过旧或来自未来 -> 丢弃；
 * 4. 精度不足 -> 丢弃；
 * 只有全部通过才产出语义事件。
 */
object LocationEventNormalizer {

    fun normalize(
        observation: RawLocationObservation,
        now: Instant,
        policy: LocationFreshnessPolicy = LocationFreshnessPolicy.STANDARD,
    ): LocationEventNormalization {

        // 1. 能力。权限被拒 / 定位关闭时必须是明确的「不可用」，不是空结果。
        if (!observation.capability.isUsable) {
            val reason = observation.capability.unavailableReason
                ?: "定位当前不可用，本次不做任何地点判断。"
            return LocationEventNormalization.Discarded(reason, isSilent = true)
        }

        // 2. 事件可判定性。
        val kind = observation.kind
        if (kind is LocationEventKind.Indeterminate) {
            return LocationEventNormalization.Discarded(
                "位置状态无法确定（" + kind.reason + "），本次不触发地点规则，也不会用猜测代替。",
                isSilent = true,
            )
        }

        // 3. 时间戳。
        val ageSeconds = ChronoUnit.SECONDS.between(observation.observedAt, now)
        if (ageSeconds < -policy.maximumFutureSkewSeconds) {
            val ahead = -ageSeconds
            return LocationEventNormalization.Discarded(
                "位置观测的时间戳比当前时间还晚 " + ahead + " 秒，判定为设备时钟异常，本次不判断地点规则。",
                isSilent = true,
            )
        }
        if (ageSeconds > policy.maximumAgeSeconds) {
            return LocationEventNormalization.Discarded(
                "位置观测已经过去 " + ageSeconds + " 秒（上限 " + policy.maximumAgeSeconds +
                    " 秒），这条位置太旧，已丢弃，绝不用它触发提醒。",
                isSilent = true,
            )
        }

        // 4. 精度。null 表示系统没有提供精度（围栏事件），按「不因此拒绝」处理并留下说明。
        val accuracy = observation.horizontalAccuracyMeters
        if (accuracy != null) {
            if (!accuracy.isFinite() || accuracy <= 0.0) {
                return LocationEventNormalization.Discarded(
                    "系统给出的定位精度是无效值（" + accuracy + "），本次不判断地点规则。",
                    isSilent = true,
                )
            }
            if (accuracy > policy.maximumHorizontalAccuracyMeters) {
                return LocationEventNormalization.Discarded(
                    "定位精度不足（±" + accuracy.toInt() + " 米，要求 ±" +
                        policy.maximumHorizontalAccuracyMeters.toInt() + " 米以内），本次不触发地点规则。",
                    isSilent = true,
                )
            }
        }

        val trigger = kind.trigger
        val transition = kind.impliedTransition
        if (trigger == null || transition == null) {
            return LocationEventNormalization.Discarded(
                "这个位置事件无法对应任何规则触发条件，已忽略。",
                isSilent = true,
            )
        }

        // 进入时刻：停留事件由系统给出；进入事件就是这次观测；离开事件用事件源记住的上一次进入时刻。
        val insideSince = when (kind) {
            is LocationEventKind.Dwell -> kind.insideSince
            LocationEventKind.Entered -> observation.insideSince ?: observation.observedAt
            LocationEventKind.Exited -> observation.insideSince
            is LocationEventKind.Indeterminate -> null
        }

        return LocationEventNormalization.Accepted(
            LocationSemanticEvent(
                placeId = observation.placeId,
                kind = kind,
                observedAt = observation.observedAt,
                horizontalAccuracyMeters = accuracy,
                capability = observation.capability,
                trigger = trigger,
                transition = transition,
                insideSince = insideSince,
            ),
        )
    }
}

/**
 * 位置事件源。适配层实现它，编排层只通过它拿事件与能力状态。
 *
 * 之所以要有这个接口：规则求值与预算判定必须能在没有定位框架的环境里测试，
 * 所以「谁来产生事件」被隔离在接口后面，测试替身可以精确控制事件序列。
 *
 * 采用「拉」而不是「回调」：真正调用它的是 BroadcastReceiver 与界面恢复路径，
 * 它们本来就在自己的协程里，多一层回调只会让生命周期更难对齐。
 */
interface LocationEventSource {

    /** 当前定位能力。权限被拒 / 定位关闭时必须是明确不可用，不是空结果。 */
    val capability: LocationCapability

    /** 已经注册监控的地点 id。注册对账由此读取，避免适配层与编排层各记一份。 */
    val monitoredPlaceIds: Set<String>

    /** 重新读取系统权限与定位开关，并返回最新能力。 */
    fun refreshCapability(): LocationCapability

    fun startMonitoring(places: List<GeoMonitoredPlace>)

    fun stopMonitoring(placeIds: List<String>)

    fun stopAllMonitoring()

    /**
     * 系统围栏广播 -> 原始观测。
     *
     * 系统围栏广播既不提供坐标也不提供事件时间与精度，所以 observedAt 只能是收到广播的时刻、
     * 精度只能是 null。这是系统 API 的能力边界，不是我们省略了信息。
     */
    fun proximityObservation(placeId: String, entering: Boolean, now: Instant): RawLocationObservation

    /**
     * 用系统最近一次定位判断当前是否在围栏内，用于前台补偿检查与停留复查。
     * 拿不到可用定位（无权限、定位关闭、只有陈旧缓存）时返回 null，绝不返回 (0,0) 凑合。
     */
    fun currentObservation(placeId: String, now: Instant): RawLocationObservation?

    /** 为停留规则安排一次到点复查；实现方用 AlarmManager 唤醒，不依赖进程存活。 */
    fun scheduleDwellRecheck(placeId: String, at: Instant)

    fun cancelDwellRecheck(placeId: String)
}
