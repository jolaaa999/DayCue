package com.daycue.android.network

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 一次 HTTP 请求的纯数据描述。
 *
 * 单独抽出来是为了让「怎么发」与「发什么」分开：业务逻辑只构造这个对象，
 * 单测就能换成假传输层断言请求头/请求体，而不必起一个真实服务器。
 */
data class HttpRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    /** 超时按业务定：健康检查要快，转写会长得多，统一超时只会让其中一端不合适。 */
    val timeoutSeconds: Long,
)

/** 响应只需要状态码与文本：契约里的响应体和错误体都是文本。 */
data class HttpResponse(
    val statusCode: Int,
    val bodyText: String,
) {
    val isSuccess: Boolean get() = statusCode in 200..299
}

/** 传输层的唯一职责：把 [HttpRequest] 发出去，把结果原样带回来（失败就抛 IO 异常）。 */
interface HttpTransport {
    suspend fun send(request: HttpRequest): HttpResponse
}

/**
 * OkHttp 实现。
 *
 * 用 OkHttp 而不是别的：它不依赖 GMS，无 Google 服务的设备上同样可用，
 * 且本工程已经在 build.gradle.kts 里声明了这个依赖。
 */
class OkHttpTransport(private val client: OkHttpClient = OkHttpClient()) : HttpTransport {

    override suspend fun send(request: HttpRequest): HttpResponse = suspendCancellableCoroutine { continuation ->
        val builder = Request.Builder().url(request.url)
        val body = request.body?.toRequestBody(null)
        builder.method(request.method, body)
        for ((name, value) in request.headers) {
            builder.header(name, value)
        }

        // 每个请求单独设超时，而不是改全局 client：转写要 120 秒，健康检查只要 10 秒，
        // 用同一个超时值必然有一端不合理。newBuilder() 会复用连接池，不会重复建连接。
        val perRequestClient = client.newBuilder()
            .callTimeout(request.timeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(request.timeoutSeconds, TimeUnit.SECONDS)
            .build()
        val call = perRequestClient.newCall(builder.build())

        // 协程被取消时立刻中断底层请求，避免后台白白占用连接。
        continuation.invokeOnCancellation { call.cancel() }

        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use {
                        HttpResponse(statusCode = it.code, bodyText = it.body?.string().orEmpty())
                    }
                } catch (e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(e)
                    return
                }
                if (continuation.isActive) continuation.resume(result)
            }
        })
    }
}
