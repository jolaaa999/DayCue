package com.daycue.android.network

import com.daycue.android.core.DayCueJson
import com.daycue.android.domain.contract.DeviceUpsertRequest
import com.daycue.android.domain.contract.DeviceUpsertResponse
import com.daycue.android.domain.contract.ErrorResponse
import com.daycue.android.domain.contract.ExtractionRequest
import com.daycue.android.domain.contract.ExtractionResponse
import com.daycue.android.domain.contract.TranscriptionResponse
import java.io.IOException

/**
 * 后端调用失败。
 *
 * 带 retryable 是为了让调用方（outbox worker）能区分「换个时间再来」和「这条请求本身有问题」，
 * 但这里绝不自动重试：失败之后怎么办属于业务决策，传输层不替业务做决定。
 */
class DayCueApiException(message: String, val retryable: Boolean = false) : Exception(message)

/**
 * DayCue 后端客户端。
 *
 * 只做三件事：拼 URL、发请求、把响应翻译成契约类型或 [DayCueApiException]。
 * 请求头与 iOS 的 DayCueAPIClient 逐项对齐（X-DayCue-Client / Accept / Authorization / X-DayCue-Timezone），
 * 因为后端会按这些头做来源识别与鉴权，两端不一致会出现「一边能通、一边 401」这种最难查的问题。
 */
class DayCueApiClient(
    private val baseUrlProvider: () -> String?,
    private val tokenProvider: () -> String?,
    private val clientId: String = "daycue-android/0.1.0",
    private val transport: HttpTransport = OkHttpTransport(),
    /**
     * 本机 IANA 时区名（Asia/Shanghai）的来源。
     *
     * 每个请求都现读一次：用户可能改系统时区、也可能正在跨时区旅行，
     * 而服务端要按这个值算每日预算重置与静默时段——缓存下来的旧时区会让「今天」错位。
     */
    private val timezoneProvider: () -> String = { java.time.ZoneId.systemDefault().id },
) {

    /**
     * 上报给服务端的本机 IANA 时区名。
     *
     * 单独一个方法而不是内联进 buildHeaders：这个头是**跨所有已鉴权请求**的契约，
     * 服务端在每个请求上读它并更新用户时区（预算重置、静默时段都按它算），
     * 所以「值从哪来」需要有一个能被测试直接看见的落点。
     */
    private fun reportedTimezone(): String = timezoneProvider()

    /** GET /v1/health。健康检查的响应体没有进契约，所以只要求 2xx 并原样回传文本。 */
    suspend fun health(): String {
        val response = send(path = "/v1/health", method = "GET", timeoutSeconds = TIMEOUT_HEALTH)
        validate(response)
        return response.bodyText
    }

    /** POST /v1/extractions */
    suspend fun extract(request: ExtractionRequest): ExtractionResponse {
        val body = try {
            DayCueJson.encodeToString(ExtractionRequest.serializer(), request).encodeToByteArray()
        } catch (e: Exception) {
            // 自己拼出来的请求都序列化不了，说明是本地 bug，重试没有意义。
            throw DayCueApiException("请求内容无法序列化：" + (e.message ?: "未知原因"))
        }

        val response = send(
            path = "/v1/extractions",
            method = "POST",
            timeoutSeconds = TIMEOUT_EXTRACT,
            contentType = "application/json",
            body = body,
        )
        validate(response)
        return try {
            DayCueJson.decodeFromString(ExtractionResponse.serializer(), response.bodyText)
        } catch (e: Exception) {
            // 2xx 但结构不符合契约：当成「响应无法解析」，绝不猜内容凭空造候选。
            throw DayCueApiException("服务响应不符合契约，无法解析。")
        }
    }

    /**
     * POST /v1/devices：登记或更新本机设备。
     *
     * 首次登记服务端返回 201、更新返回 200，两者都算成功——这里只要求 2xx 并解析响应体，
     * 不把 201 当成异常。
     */
    suspend fun upsertDevice(request: DeviceUpsertRequest): DeviceUpsertResponse {
        val body = try {
            DayCueJson.encodeToString(DeviceUpsertRequest.serializer(), request).encodeToByteArray()
        } catch (e: Exception) {
            throw DayCueApiException("设备信息无法序列化：" + (e.message ?: "未知原因"))
        }
        val response = send(
            path = "/v1/devices",
            method = "POST",
            timeoutSeconds = TIMEOUT_HEALTH,
            contentType = "application/json",
            body = body,
        )
        validate(response)
        return try {
            DayCueJson.decodeFromString(DeviceUpsertResponse.serializer(), response.bodyText)
        } catch (e: Exception) {
            throw DayCueApiException("服务端返回的设备信息不符合契约，无法解析。")
        }
    }

    /** POST /v1/transcriptions：后端只接受原始音频字节，Content-Type 必须是 audio 类型。 */
    suspend fun transcribe(
        audioBytes: ByteArray,
        mimeType: String,
        language: String?,
        timezone: String,
    ): TranscriptionResponse {
        val headers = buildMap {
            put("X-DayCue-Timezone", timezone)
            if (!language.isNullOrBlank()) put("X-DayCue-Language", language)
        }
        val response = send(
            path = "/v1/transcriptions",
            method = "POST",
            timeoutSeconds = TIMEOUT_TRANSCRIBE,
            contentType = mimeType,
            body = audioBytes,
            extraHeaders = headers,
        )
        validate(response)
        return try {
            DayCueJson.decodeFromString(TranscriptionResponse.serializer(), response.bodyText)
        } catch (e: Exception) {
            throw DayCueApiException("服务响应不符合契约，无法解析。")
        }
    }

    private suspend fun send(
        path: String,
        method: String,
        timeoutSeconds: Long,
        contentType: String? = null,
        body: ByteArray? = null,
        extraHeaders: Map<String, String> = emptyMap(),
    ): HttpResponse {
        val request = HttpRequest(
            url = buildUrl(path),
            method = method,
            headers = buildHeaders(contentType, extraHeaders),
            body = body,
            timeoutSeconds = timeoutSeconds,
        )
        return try {
            transport.send(request)
        } catch (e: IOException) {
            // 网络层异常统一翻译成可重试：连不上、超时、连接被重置都属于「稍后再来」。
            throw DayCueApiException("网络不可用或请求超时，内容已保存在本机。", retryable = true)
        } catch (e: IllegalArgumentException) {
            // 后端地址是用户手填的，写错（缺协议头、有空格）会让 URL 解析失败。
            // 这是「请求本身有问题」，标成可重试只会让 worker 空转，所以 retryable 保持 false。
            throw DayCueApiException("后端地址不合法，请在设置里检查：" + (e.message ?: "无法解析"))
        }
    }

    /**
     * 未配置后端时必须显式失败，而不是悄悄用一个默认地址：
     * 纯本地模式是该产品的合法形态，静默发请求反而会暴露用户内容。
     */
    private fun buildUrl(path: String): String {
        val raw = baseUrlProvider()?.trim()
        if (raw.isNullOrEmpty()) throw DayCueApiException("未配置后端地址")
        val base = raw.trimEnd('/')
        val suffix = if (path.startsWith("/")) path else "/" + path
        return base + suffix
    }

    private fun buildHeaders(contentType: String?, extraHeaders: Map<String, String>): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        headers["X-DayCue-Client"] = clientId
        headers["Accept"] = "application/json"
        // 每个请求都带本机时区：服务端用它在请求路径上更新「用户现在按哪个时区生活」。
        // 只放在设备登记那一条请求里是不够的——用户可能几个月都不触发一次设备登记。
        headers[HEADER_TIMEZONE] = reportedTimezone()
        val token = tokenProvider()
        if (!token.isNullOrEmpty()) {
            headers["Authorization"] = "Bearer " + token
        }
        if (contentType != null) {
            headers["Content-Type"] = contentType
        }
        headers.putAll(extraHeaders)
        return headers
    }

    private fun validate(response: HttpResponse) {
        if (response.isSuccess) return

        // 先按契约错误体解析：这样「后端按契约报错」与「代理返回 HTML 错误页」在界面上能区分开。
        val parsed = try {
            DayCueJson.decodeFromString(ErrorResponse.serializer(), response.bodyText)
        } catch (e: Exception) {
            null
        }
        if (parsed != null) {
            throw DayCueApiException(parsed.error.userFacingMessage, retryable = parsed.error.retryable)
        }
        throw DayCueApiException(
            message = "服务返回了无法识别的错误",
            // 5xx / 408 / 429 之外的状态多半是请求本身的问题，标成可重试只会让 worker 空转。
            retryable = response.statusCode >= 500 || response.statusCode == 408 || response.statusCode == 429,
        )
    }

    private companion object {
        /**
         * 与 iOS 的 DayCueAPIClient、服务端 account.go 的 headerReportedTimezone 同名。
         * 名字写错不会报错，只会让服务端一直看到「没有时区」——所以只在这里定义一次。
         */
        const val HEADER_TIMEZONE = "X-DayCue-Timezone"

        const val TIMEOUT_HEALTH = 10L
        const val TIMEOUT_EXTRACT = 60L
        const val TIMEOUT_TRANSCRIBE = 120L
    }
}
