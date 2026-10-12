package com.daycue.android.domain.contract

import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExtractionMode
import com.daycue.android.domain.model.ProposalItemKind
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// 本文件是 contracts/v1/*.schema.json 在 Kotlin 侧的镜像。
// 规则与 iOS Contract.swift 一致：字段名与 schema 完全一致；客户端只关心已声明字段。

object ContractVersion {
    const val V1 = "1.0"
}

// ---------------- 请求 ----------------

@Serializable
data class ExtractionRequestSource(
    val type: SourceType,
    val text: String,
    val language: String? = null,
) {
    @Serializable
    enum class SourceType {
        @SerialName("text")
        TEXT,

        @SerialName("asr")
        ASR,

        @SerialName("ocr")
        OCR,
    }
}

@Serializable
data class ExtractionClientContext(
    @SerialName("has_course_schedule") val hasCourseSchedule: Boolean? = null,
    @SerialName("known_places") val knownPlaces: List<String>? = null,
)

@Serializable
data class ExtractionRequest(
    @SerialName("schema_version") val schemaVersion: String = ContractVersion.V1,
    @SerialName("capture_id") val captureId: String,
    val source: ExtractionRequestSource,
    @SerialName("recorded_at") val recordedAt: String,
    val timezone: String,
    @SerialName("client_context") val clientContext: ExtractionClientContext? = null,
)

// ---------------- 解析响应 ----------------

// DueKind / ExtractionMode / ProposalItemKind 定义在 domain.model（与 iOS 的 DomainModels.swift 同构），
// 这里直接复用，避免同一组取值在两端出现两份定义。

/** due。utc 只在 kind=datetime 时有值；date 型不允许伪造 UTC 时刻。 */
@Serializable
data class ContractDue(
    val kind: DueKind,
    val local: String? = null,
    val utc: String? = null,
    val timezone: String? = null,
)

/** remind。为 null 表示没有提醒时刻，但不等于没有截止时间。 */
@Serializable
data class ContractRemind(
    val kind: String = "absolute",
    val local: String,
    val utc: String,
    val timezone: String,
)

/**
 * 歧义。
 *
 * code 故意用 String 而不是枚举：契约里明确允许出现未列出的 code，
 * 而「未知 code」必须按「需要澄清」处理，不能因为解析不出枚举值就整条响应失败。
 */
@Serializable
data class ContractAmbiguity(
    val code: String,
    val field: String,
    val message: String,
) {
    val requiresClarification: Boolean get() = AmbiguityCodes.requiresClarification(code)
}

object AmbiguityCodes {
    const val DEADLINE_ONLY = "deadline_only"
    const val MISSING_YEAR = "missing_year"
    const val WEEKDAY_DATE_CONFLICT = "weekday_date_conflict"
    const val AMBIGUOUS_AMPM = "ambiguous_ampm"
    const val AMBIGUOUS_PLACE = "ambiguous_place"
    const val UNRESOLVED_DATE = "unresolved_date"
    const val PAST_TIME = "past_time"
    const val DST_NONEXISTENT = "dst_nonexistent"
    const val DST_AMBIGUOUS = "dst_ambiguous"
    const val ASSUMED_NEXT_DAY = "assumed_next_day"
    const val MODEL_UNCERTAIN = "model_uncertain"

    /**
     * 只有「能自动处理的提示」才返回 false。
     * deadline_only 排在第一位：它表示「只设了截止日」，界面只要显示「尚未设置提醒时间」，不需要追问。
     */
    fun requiresClarification(code: String): Boolean = when (code) {
        DEADLINE_ONLY -> false
        MISSING_YEAR, WEEKDAY_DATE_CONFLICT, AMBIGUOUS_AMPM, AMBIGUOUS_PLACE,
        UNRESOLVED_DATE, PAST_TIME, DST_NONEXISTENT, DST_AMBIGUOUS, ASSUMED_NEXT_DAY,
        MODEL_UNCERTAIN,
        -> true
        // 未知 code：宁可多问一次，也不要替用户猜一个日期。
        else -> true
    }
}

@Serializable
data class ContractExtractionItem(
    @SerialName("item_id") val itemId: String,
    val kind: ProposalItemKind,
    val title: String,
    val detail: String? = null,
    @SerialName("source_evidence") val sourceEvidence: String,
    @SerialName("date_expression") val dateExpression: String? = null,
    val due: ContractDue,
    val remind: ContractRemind? = null,
    @SerialName("course_hint") val courseHint: String? = null,
    @SerialName("place_hint") val placeHint: String? = null,
    val ambiguities: List<ContractAmbiguity> = emptyList(),
    val confidence: Double? = null,
) {
    val requiresClarification: Boolean get() = ambiguities.any { it.requiresClarification }

    /** 「只设了截止日」的标记：界面据此显示「尚未设置提醒时间」，绝不自动补一个时刻。 */
    val isDeadlineOnly: Boolean
        get() = remind == null && ambiguities.any { it.code == AmbiguityCodes.DEADLINE_ONLY }

    /**
     * 可以自动执行的前提：字段齐全、没有需要澄清的歧义。
     * confidence 只是参考，不参与这个判断——模型自报分数未经校准，不能作为自动执行的唯一依据。
     */
    val isAutoExecutable: Boolean
        get() = !requiresClarification && due.kind != DueKind.NONE && title.isNotBlank()
}

@Serializable
data class ContractUsage(
    val provider: String? = null,
    val model: String? = null,
    @SerialName("latency_ms") val latencyMs: Long? = null,
    @SerialName("prompt_tokens") val promptTokens: Long? = null,
    @SerialName("completion_tokens") val completionTokens: Long? = null,
)

@Serializable
data class ExtractionResponse(
    @SerialName("schema_version") val schemaVersion: String,
    @SerialName("capture_id") val captureId: String,
    val mode: ExtractionMode,
    val items: List<ContractExtractionItem> = emptyList(),
    val warnings: List<String> = emptyList(),
    val usage: ContractUsage? = null,
)

// ---------------- 转写响应 ----------------

@Serializable
data class TranscriptionResponse(
    @SerialName("schema_version") val schemaVersion: String,
    val text: String,
    val mode: ExtractionMode,
    val language: String? = null,
    @SerialName("duration_ms") val durationMs: Long? = null,
    val warnings: List<String>? = null,
)

// ---------------- 设备登记 ----------------

/**
 * 设备登记 / 更新（POST /v1/devices）。
 *
 * capabilities 用 Map<String, Boolean>：服务端只认「键存在 = 已确认」，
 * 所以未知的能力必须省略而不是填 false（填 false 会让服务端以为设备确实收不到通知）。
 *
 * 刻意**没有** timezone 字段：IANA 时区是跟着每个已鉴权请求走的请求头
 * （X-DayCue-Timezone，见 DayCueApiClient），服务端在每个请求上都会读它并更新用户时区。
 * 放进请求体会多出一条只有设备登记才更新的路径，两条路径迟早不一致。
 */
@Serializable
data class DeviceUpsertRequest(
    @SerialName("id") val id: String? = null,
    val platform: String = "android",
    val name: String,
    val capabilities: Map<String, Boolean> = emptyMap(),
    @SerialName("push_token") val pushToken: String? = null,
)

/** 设备登记的响应，取服务端确认后的最终值（id / last_seen_at 可能被服务端修正）。 */
@Serializable
data class DeviceUpsertResponse(
    val id: String,
    val platform: String? = null,
    val name: String? = null,
    val capabilities: Map<String, Boolean> = emptyMap(),
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
)

// ---------------- 错误响应 ----------------

/**
 * 契约错误码。
 *
 * 同样用 String + 映射表而不是枚举：新增错误码时老客户端不能整体解析失败。
 */
object ContractErrorCodes {
    const val INVALID_REQUEST = "invalid_request"
    const val UNAUTHORIZED = "unauthorized"
    const val NOT_FOUND = "not_found"
    const val PAYLOAD_TOO_LARGE = "payload_too_large"
    const val UNSUPPORTED_MEDIA_TYPE = "unsupported_media_type"
    const val UNPROCESSABLE = "unprocessable"
    const val RATE_LIMITED = "rate_limited"
    const val UPSTREAM_TIMEOUT = "upstream_timeout"
    const val UPSTREAM_ERROR = "upstream_error"
    const val MODEL_OUTPUT_INVALID = "model_output_invalid"
    const val INTERNAL = "internal"

    /** 模型输出非法时客户端只能提示「已保留记录」，绝不触发任何系统写操作。 */
    fun isModelOutputInvalid(code: String): Boolean = code == MODEL_OUTPUT_INVALID

    fun userFacingMessage(code: String): String = when (code) {
        INVALID_REQUEST -> "请求内容不合法，记录已保留。"
        UNAUTHORIZED -> "服务未授权，请检查设置里的 Bearer Token。"
        NOT_FOUND -> "服务接口不存在，请确认版本。"
        PAYLOAD_TOO_LARGE -> "内容过大，请缩短或改用录音。"
        UNSUPPORTED_MEDIA_TYPE -> "服务不支持该媒体类型。"
        UNPROCESSABLE -> "无法处理这条记录，已保留可稍后重试。"
        RATE_LIMITED -> "请求过于频繁，已保留记录，稍后自动重试。"
        UPSTREAM_TIMEOUT -> "AI 服务超时，已保留记录，可稍后重试。"
        UPSTREAM_ERROR -> "AI 服务出错，已保留记录，可稍后重试。"
        MODEL_OUTPUT_INVALID -> "已保留记录，可稍后重试（模型返回无法解析的结果）。"
        INTERNAL -> "服务内部错误，已保留记录，可稍后重试。"
        else -> "服务返回错误（" + code + "），记录已保留。"
    }
}

@Serializable
data class ContractError(
    val code: String,
    val message: String,
    val retryable: Boolean,
    @SerialName("trace_id") val traceId: String,
) {
    val userFacingMessage: String get() = ContractErrorCodes.userFacingMessage(code)
}

@Serializable
data class ErrorResponse(
    val error: ContractError,
)
