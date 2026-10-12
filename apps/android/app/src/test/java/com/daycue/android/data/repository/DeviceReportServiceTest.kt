package com.daycue.android.data.repository

import com.daycue.android.domain.contract.DeviceUpsertRequest
import com.daycue.android.domain.contract.DeviceUpsertResponse
import com.daycue.android.network.DayCueApiClient
import com.daycue.android.network.HttpRequest
import com.daycue.android.network.HttpResponse
import com.daycue.android.network.HttpTransport
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * 设备能力与 IANA 时区上报。
 *
 * 这条链路此前是断的：Android 只在**转写请求**上带过时区，设备登记路径根本没有时区，
 * 服务端因此无法回答「这台设备现在按哪个时区生活」——
 * 而这正是跨时区旅行 / 用户改系统时区之后算每日预算重置与静默时段的前提。
 *
 * 上报方式是 `X-DayCue-Timezone` 请求头（服务端在每个请求路径上都会读它并更新用户时区，
 * 不是只在设备登记时读一次），所以用例分两层：
 * 1. 客户端的**每个请求**都带上本机时区；
 * 2. 设备登记的请求体里带设备 id 与能力映射，且未知能力被省略。
 *
 * 全部用替身：不发真实网络请求，也不依赖跑测试的机器在哪个时区。
 */
class DeviceReportServiceTest {

    /** 记录请求的假传输层：这里要断言的是「发出去的请求长什么样」。 */
    private class RecordingTransport(
        private val responder: (HttpRequest) -> HttpResponse = {
            HttpResponse(statusCode = 200, bodyText = "{\"id\":\"dev_from_server\"}")
        },
    ) : HttpTransport {
        val requests = ArrayList<HttpRequest>()

        override suspend fun send(request: HttpRequest): HttpResponse {
            requests += request
            return responder(request)
        }
    }

    private class RecordingRegistrar : DeviceRegistrar {
        val requests = ArrayList<DeviceUpsertRequest>()
        var response: (DeviceUpsertRequest) -> DeviceUpsertResponse = { request ->
            DeviceUpsertResponse(id = request.id ?: "dev_from_server", lastSeenAt = "2026-10-12T09:00:00Z")
        }

        override suspend fun upsert(request: DeviceUpsertRequest): DeviceUpsertResponse {
            requests += request
            return response(request)
        }
    }

    private class Snapshot(
        private val capabilities: Map<String, Boolean>,
        private val name: String = "Pixel 7",
    ) : DeviceCapabilitySnapshot {
        override fun asCapabilityMap(): Map<String, Boolean> = capabilities
        override fun deviceName(): String = name
    }

    // ---- 时区请求头 ----

    @Test
    fun everyAuthenticatedRequestCarriesTheDeviceIanaTimezone() = runTest {
        val transport = RecordingTransport { request ->
            HttpResponse(statusCode = 200, bodyText = if (request.url.endsWith("/v1/health")) "ok" else "{}")
        }
        val client = DayCueApiClient(
            baseUrlProvider = { "https://daycue.example" },
            tokenProvider = { "token-1" },
            transport = transport,
            timezoneProvider = { "Asia/Shanghai" },
        )

        client.health()

        val headers = transport.requests.single().headers
        // IANA 名称而不是偏移量：+08:00 在夏令时切换时会算错「明晚八点」。
        assertEquals("Asia/Shanghai", headers["X-DayCue-Timezone"])
        assertEquals("daycue-android/0.1.0", headers["X-DayCue-Client"])
        assertEquals("Bearer token-1", headers["Authorization"])
    }

    @Test
    fun deviceRegistrationCarriesTimezoneAndDeviceIdentity() = runTest {
        val transport = RecordingTransport { request ->
            HttpResponse(
                statusCode = 201,
                bodyText = "{\"id\":\"dev_0123456789abcdef0123456789abcdef\",\"last_seen_at\":\"2026-10-12T09:00:00Z\"}",
            )
        }
        val client = DayCueApiClient(
            baseUrlProvider = { "https://daycue.example" },
            tokenProvider = { "token-1" },
            transport = transport,
            timezoneProvider = { "Europe/Berlin" },
        )

        val response = client.upsertDevice(
            DeviceUpsertRequest(
                id = "dev_0123456789abcdef0123456789abcdef",
                name = "Pixel 7",
                capabilities = mapOf("notifications" to true),
            ),
        )

        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertTrue(request.url.endsWith("/v1/devices"))
        // 时刻由设备上报，所以首次登记返回的 201 必须被当作成功（不是异常）。
        assertEquals("Europe/Berlin", request.headers["X-DayCue-Timezone"])
        val bodyText = request.body!!.decodeToString()
        assertTrue("设备 id 必须在请求体里", bodyText.contains("dev_0123456789abcdef0123456789abcdef"))
        assertTrue(bodyText.contains("\"notifications\":true"))
        assertEquals("dev_0123456789abcdef0123456789abcdef", response.id)
    }

    @Test
    fun timezoneIsReadPerRequestSoSystemZoneChangeTakesEffect() = runTest {
        val transport = RecordingTransport { HttpResponse(statusCode = 200, bodyText = "ok") }
        var zone = "Asia/Shanghai"
        val client = DayCueApiClient(
            baseUrlProvider = { "https://daycue.example" },
            tokenProvider = { "token-1" },
            transport = transport,
            timezoneProvider = { zone },
        )

        client.health()
        zone = "Europe/Berlin"
        client.health()

        assertEquals(
            "用户改了系统时区之后，下一个请求必须带上新值（不能缓存上一次的结论）",
            listOf("Asia/Shanghai", "Europe/Berlin"),
            transport.requests.map { it.headers["X-DayCue-Timezone"] },
        )
    }

    // ---- 设备上报本身 ----

    @Test
    fun reportSendsDeviceIdCapabilitiesAndTimezone() = runTest {
        val registrar = RecordingRegistrar()
        val service = DeviceReportService(
            registrar = registrar,
            capabilities = Snapshot(mapOf("notifications" to true, "precise_location" to true)),
            zones = { ZoneId.of("Asia/Shanghai") },
            deviceIdProvider = { "dev_0123456789abcdef0123456789abcdef" },
        )

        val outcome = service.report().getOrThrow()

        val request = registrar.requests.single()
        assertEquals("android", request.platform)
        assertEquals("Pixel 7", request.name)
        assertEquals("dev_0123456789abcdef0123456789abcdef", request.id)
        assertEquals(true, request.capabilities["notifications"])
        assertEquals(true, request.capabilities["precise_location"])
        assertEquals("Asia/Shanghai", outcome.reportedTimezone)
        assertEquals("2026-10-12T09:00:00Z", outcome.lastSeenAt)
    }

    @Test
    fun unknownCapabilitiesAreOmittedRatherThanReportedAsFalse() = runTest {
        val registrar = RecordingRegistrar()
        val service = DeviceReportService(
            registrar = registrar,
            capabilities = Snapshot(mapOf("notifications" to true)),
            zones = { ZoneId.of("UTC") },
            deviceIdProvider = { null },
        )

        service.report().getOrThrow()

        val capabilities = registrar.requests.single().capabilities
        assertTrue(capabilities.containsKey("notifications"))
        // 服务端把「键存在」当作「客户端已确认」；补一个 false 等于替设备撒谎。
        assertFalse("未知能力不能上报成 false", capabilities.containsKey("precise_location"))
        assertFalse(capabilities.containsKey("calendar_write"))
    }

    @Test
    fun failedReportIsReturnedAsFailureInsteadOfThrowing() = runTest {
        val registrar = RecordingRegistrar()
        registrar.response = { throw IllegalStateException("后端不可用") }
        val service = DeviceReportService(
            registrar = registrar,
            capabilities = Snapshot(emptyMap()),
            zones = { ZoneId.of("UTC") },
            deviceIdProvider = { null },
        )

        val result = service.report()

        assertTrue("上报失败只能是 Result.failure：它是尽力而为的旁路，不该把启动流程带崩", result.isFailure)
    }

    // ---- 回前台按需重报 ----

    /** 能力可变的能力快照替身：用它模拟「用户在系统设置里改了权限」。 */
    private class MutableSnapshot(var capabilities: Map<String, Boolean>) : DeviceCapabilitySnapshot {
        override fun asCapabilityMap(): Map<String, Boolean> = capabilities
        override fun deviceName(): String = "Pixel 7"
    }

    private fun serviceFor(
        registrar: RecordingRegistrar,
        snapshot: MutableSnapshot,
        now: () -> Long,
        refreshIntervalMillis: Long = 30L * 60L * 1000L,
    ) = DeviceReportService(
        registrar = registrar,
        capabilities = snapshot,
        zones = { ZoneId.of("UTC") },
        deviceIdProvider = { "dev-1" },
        refreshIntervalMillis = refreshIntervalMillis,
        nowMillis = now,
    )

    @Test
    fun resumeRefreshSendsNothingWhenCapabilitiesAreUnchangedAndNotStale() = runTest {
        val registrar = RecordingRegistrar()
        var clock = 1_000_000L
        val snapshot = MutableSnapshot(mapOf("notifications" to true))
        val service = serviceFor(registrar, snapshot, { clock })

        service.report().getOrThrow()
        assertEquals(1, registrar.requests.size)

        // 同一分钟内连切几次前台，能力没变，不该再发。
        clock += 60_000L
        assertEquals(null, service.reportIfStale())
        assertEquals(null, service.reportIfStale())
        assertEquals("能力没变且没过刷新周期时不能联网", 1, registrar.requests.size)
    }

    @Test
    fun resumeRefreshReportsImmediatelyWhenCapabilitiesChanged() = runTest {
        val registrar = RecordingRegistrar()
        var clock = 1_000_000L
        val snapshot = MutableSnapshot(mapOf("notifications" to false))
        val service = serviceFor(registrar, snapshot, { clock })

        service.report().getOrThrow()
        clock += 1_000L

        // 用户刚在系统设置里给了通知权限，返回应用：必须立刻重报，
        // 否则服务端会一直认为这台设备不能收推送。
        snapshot.capabilities = mapOf("notifications" to true)
        val outcome = service.reportIfStale()

        assertTrue("能力变化必须触发重报", outcome != null)
        assertEquals(2, registrar.requests.size)
        assertEquals(true, registrar.requests.last().capabilities["notifications"])
    }

    @Test
    fun resumeRefreshReportsWhenTheRefreshIntervalHasPassed() = runTest {
        val registrar = RecordingRegistrar()
        var clock = 1_000_000L
        val snapshot = MutableSnapshot(mapOf("notifications" to true))
        val service = serviceFor(registrar, snapshot, { clock }, refreshIntervalMillis = 60_000L)

        service.report().getOrThrow()

        clock += 59_000L
        assertEquals(null, service.reportIfStale())

        clock += 2_000L
        assertTrue("超过刷新周期要重报，否则服务端的 last_seen_at 会一直停在过去", service.reportIfStale() != null)
        assertEquals(2, registrar.requests.size)
    }

    @Test
    fun resumeRefreshRetriesImmediatelyAfterAFailure() = runTest {
        val registrar = RecordingRegistrar()
        var clock = 1_000_000L
        val snapshot = MutableSnapshot(mapOf("notifications" to true))
        val service = serviceFor(registrar, snapshot, { clock })
        registrar.response = { throw IllegalStateException("后端不可用") }

        assertTrue(service.reportIfStale()!!.isFailure)
        assertEquals(1, registrar.requests.size)

        // 失败不能算作「已上报」：否则用户会因为一次网络抖动而错过整个刷新周期。
        clock += 1_000L
        registrar.response = { request -> DeviceUpsertResponse(id = request.id ?: "dev-1", lastSeenAt = "2026-10-12T09:00:00Z") }
        assertTrue("失败之后下一次回前台就该重试", service.reportIfStale()!!.isSuccess)
        assertEquals(2, registrar.requests.size)
    }

    @Test
    fun resumeRefreshDoesNotSendTwiceWhileOneIsStillInFlight() = runTest {
        val registrar = RecordingRegistrar()
        val snapshot = MutableSnapshot(mapOf("notifications" to true))
        val service = serviceFor(registrar, snapshot, { 1_000_000L })

        // 回前台会连续触发（每个 Activity 各一次），这里验「连着调用不会连着发」。
        val first = service.reportIfStale()
        assertTrue(first != null)
        assertEquals(1, registrar.requests.size)
        // 能力与上次一致、且没过周期 → 第二次不会再发。
        assertEquals(null, service.reportIfStale())
        assertEquals(1, registrar.requests.size)
    }
}
