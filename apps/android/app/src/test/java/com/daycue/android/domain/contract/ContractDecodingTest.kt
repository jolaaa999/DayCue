package com.daycue.android.domain.contract

import com.daycue.android.core.DayCueJson
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.ExtractionMode
import com.daycue.android.domain.model.ProposalItemKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约解码。
 *
 * 用的是 contracts/v1/extraction-response.schema.json 里 declared 的字段形状，
 * 重点覆盖三件事：日期型截止日不能凭空多出 UTC、未知歧义码必须按「需要澄清」处理、
 * 后端新增字段不能让老客户端解析失败。
 */
class ContractDecodingTest {

    private val responseJson = """
        {
          "schema_version": "1.0",
          "capture_id": "capture_1",
          "mode": "fixture",
          "items": [
            {
              "item_id": "item_1",
              "kind": "task",
              "title": "交实验报告",
              "source_evidence": "周五之前交实验报告",
              "date_expression": "周五之前",
              "due": { "kind": "date", "local": "2026-10-16", "utc": null, "timezone": "Asia/Shanghai" },
              "remind": null,
              "ambiguities": [ { "code": "deadline_only", "field": "remind", "message": "只识别到截止日" } ]
            },
            {
              "item_id": "item_2",
              "kind": "note",
              "title": "PV 操作仍有疑问",
              "source_evidence": "操作系统讲了 PV 操作，我还是没理解",
              "due": { "kind": "none" },
              "remind": null,
              "ambiguities": []
            },
            {
              "item_id": "item_3",
              "kind": "task",
              "title": "复习 PV 操作",
              "source_evidence": "明晚八点提醒我复习",
              "due": { "kind": "datetime", "local": "2026-10-13T20:00:00", "utc": "2026-10-13T12:00:00Z", "timezone": "Asia/Shanghai" },
              "remind": { "kind": "absolute", "local": "2026-10-13T20:00:00", "utc": "2026-10-13T12:00:00Z", "timezone": "Asia/Shanghai" },
              "ambiguities": [ { "code": "some_future_code", "field": "date", "message": "未来的歧义码" } ],
              "confidence": 0.8
            }
          ],
          "warnings": ["识别到 3 条候选"],
          "usage": { "provider": "fixture", "model": "fixture-1", "latency_ms": 12 }
        }
    """.trimIndent()

    @Test
    fun decodesFullFixtureResponse() {
        val response = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson)
        assertEquals("1.0", response.schemaVersion)
        assertEquals("capture_1", response.captureId)
        assertEquals(ExtractionMode.FIXTURE, response.mode)
        assertEquals("模拟结果", response.mode.displayName)
        assertEquals(3, response.items.size)
        assertEquals("fixture-1", response.usage?.model)
        assertEquals(12L, response.usage?.latencyMs)
    }

    @Test
    fun dateOnlyDueCarriesNoUtcInstant() {
        val item = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson).items[0]
        assertEquals(DueKind.DATE, item.due.kind)
        assertEquals("2026-10-16", item.due.local)
        // 日期型截止日的 utc 必须是 null；补一个假的午夜会让「周五之前」变成「周五 00:00 提醒」。
        assertNull(item.due.utc)
    }

    @Test
    fun deadlineOnlyItemIsNotATaskClarification() {
        val item = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson).items[0]
        assertTrue(item.isDeadlineOnly)
        assertFalse(item.requiresClarification)
        // 只设截止日也能直接建任务，界面只需提示「尚未设置提醒时间」。
        assertTrue(item.isAutoExecutable)
        assertNull(item.remind)
    }

    @Test
    fun unknownAmbiguityCodeIsTreatedAsNeedingClarification() {
        val item = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson).items[2]
        assertEquals("some_future_code", item.ambiguities.single().code)
        assertTrue("无法识别的歧义码必须按需要澄清处理", item.requiresClarification)
        assertFalse(item.isAutoExecutable)
    }

    @Test
    fun noteWithoutDueCannotBeAutoExecuted() {
        val item = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson).items[1]
        assertEquals(ProposalItemKind.NOTE, item.kind)
        assertEquals(DueKind.NONE, item.due.kind)
        assertFalse(item.isAutoExecutable)
    }

    @Test
    fun absoluteReminderIsKeptAsIs() {
        val item = DayCueJson.decodeFromString(ExtractionResponse.serializer(), responseJson).items[2]
        assertEquals("absolute", item.remind?.kind)
        assertEquals("2026-10-13T12:00:00Z", item.remind?.utc)
    }

    @Test
    fun unknownFieldsDoNotBreakDecoding() {
        val withExtra = responseJson.replaceFirst("\"warnings\": [", "\"future_top_level\": {\"a\": 1}, \"warnings\": [")
        val response = DayCueJson.decodeFromString(ExtractionResponse.serializer(), withExtra)
        assertEquals(3, response.items.size)
    }

    @Test
    fun errorResponseMapsKnownCodeToFriendlyMessage() {
        val json = """
            { "error": { "code": "model_output_invalid", "message": "raw", "retryable": true, "trace_id": "t-1" } }
        """.trimIndent()
        val response = DayCueJson.decodeFromString(ErrorResponse.serializer(), json)
        assertEquals("model_output_invalid", response.error.code)
        assertTrue(response.error.retryable)
        assertTrue(response.error.userFacingMessage.contains("模型返回"))
    }

    @Test
    fun unknownErrorCodeStillProducesAReadableMessage() {
        val json = """
            { "error": { "code": "brand_new_code", "message": "raw", "retryable": false, "trace_id": "t-2" } }
        """.trimIndent()
        val response = DayCueJson.decodeFromString(ErrorResponse.serializer(), json)
        assertEquals("服务返回错误（brand_new_code），记录已保留。", response.error.userFacingMessage)
    }

    @Test
    fun requestEncodingOmitsNullsAndKeepsSchemaVersion() {
        val request = ExtractionRequest(
            captureId = "capture_1",
            source = ExtractionRequestSource(
                type = ExtractionRequestSource.SourceType.TEXT,
                text = "周五之前交实验报告",
                language = null,
            ),
            recordedAt = "2026-10-12T12:00:00Z",
            timezone = "Asia/Shanghai",
        )
        val encoded = DayCueJson.encodeToString(ExtractionRequest.serializer(), request)
        assertTrue(encoded.contains("\"schema_version\":\"1.0\""))
        assertTrue(encoded.contains("\"type\":\"text\""))
        // 与 Swift JSONEncoder 对齐：为 null 的可选字段直接不出现。
        assertFalse(encoded.contains("language"))
        assertFalse(encoded.contains("client_context"))
    }

    @Test
    fun ambiguityCodesClassifyKnownValues() {
        assertFalse(AmbiguityCodes.requiresClarification(AmbiguityCodes.DEADLINE_ONLY))
        assertTrue(AmbiguityCodes.requiresClarification(AmbiguityCodes.WEEKDAY_DATE_CONFLICT))
        assertTrue(AmbiguityCodes.requiresClarification(AmbiguityCodes.MODEL_UNCERTAIN))
        assertTrue(AmbiguityCodes.requiresClarification("something_new"))
    }
}
