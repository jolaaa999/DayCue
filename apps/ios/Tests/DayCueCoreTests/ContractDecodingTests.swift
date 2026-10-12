import Foundation
import XCTest
@testable import DayCueCore

/// 契约解码测试。
///
/// 这里的 JSON 是 contracts/fixtures/extract-os-pv.response.json 的等价内联副本。
/// 故意不读仓库里的 fixture 文件：测试不能依赖相对路径跑到 apps/ios 之外，
/// 否则换个工作目录（Xcode 与 swift test 的 cwd 不同）就会失败。
final class ContractDecodingTests: XCTestCase {

    private let fixtureJSON = #"""
    {
      "schema_version": "1.0",
      "capture_id": "cap_fixture_os_pv",
      "mode": "fixture",
      "items": [
        {
          "item_id": "itm_note_pv",
          "kind": "note",
          "title": "操作系统讲到 PV 操作",
          "detail": "今天操作系统讲了 PV 操作，我还是没理解。",
          "source_evidence": "今天操作系统讲了 PV 操作，我还是没理解",
          "date_expression": null,
          "due": { "kind": "none" },
          "remind": null,
          "course_hint": "操作系统",
          "place_hint": null,
          "ambiguities": [],
          "confidence": 0.92
        },
        {
          "item_id": "itm_task_review_pv",
          "kind": "task",
          "title": "复习操作系统 PV 操作",
          "detail": null,
          "source_evidence": "明晚八点提醒我复习",
          "date_expression": "明晚八点",
          "due": {
            "kind": "datetime",
            "local": "2026-10-12T20:00:00",
            "utc": "2026-10-12T12:00:00Z",
            "timezone": "Asia/Shanghai"
          },
          "remind": {
            "kind": "absolute",
            "local": "2026-10-12T20:00:00",
            "utc": "2026-10-12T12:00:00Z",
            "timezone": "Asia/Shanghai"
          },
          "course_hint": "操作系统",
          "place_hint": null,
          "ambiguities": [],
          "confidence": 0.88
        },
        {
          "item_id": "itm_task_report",
          "kind": "task",
          "title": "交实验报告",
          "detail": null,
          "source_evidence": "周五之前交实验报告",
          "date_expression": "周五之前",
          "due": {
            "kind": "date",
            "local": "2026-10-16",
            "utc": null,
            "timezone": "Asia/Shanghai"
          },
          "remind": null,
          "course_hint": null,
          "place_hint": null,
          "ambiguities": [
            {
              "code": "deadline_only",
              "field": "remind",
              "message": "「周五之前」只表示截止日，未设置提醒时刻。"
            }
          ],
          "confidence": 0.8
        }
      ],
      "warnings": [],
      "usage": {
        "provider": "fixture",
        "model": "fixture-rules-v1",
        "latency_ms": 0,
        "prompt_tokens": 0,
        "completion_tokens": 0
      }
    }
    """#

    func testDecodesFixtureAsOneNoteAndTwoTasks() throws {
        let response = try DayCueJSON.decode(ExtractionResponse.self, from: fixtureJSON)

        XCTAssertEqual(response.schemaVersion, "1.0")
        XCTAssertEqual(response.captureId, "cap_fixture_os_pv")
        // fixture 必须能被识别出来，UI 才有依据标注「模拟结果」。
        XCTAssertEqual(response.mode, .fixture)
        XCTAssertEqual(response.items.count, 3)
        XCTAssertEqual(response.items.filter { $0.kind == .note }.count, 1)
        XCTAssertEqual(response.items.filter { $0.kind == .task }.count, 2)
        XCTAssertTrue(response.warnings.isEmpty)
        XCTAssertEqual(response.usage?.model, "fixture-rules-v1")
    }

    func testDeadlineOnlyTaskKeepsNilReminderAndCarriesAmbiguity() throws {
        let response = try DayCueJSON.decode(ExtractionResponse.self, from: fixtureJSON)
        let reportItem = try XCTUnwrap(response.items.first { $0.itemId == "itm_task_report" })

        // 「周五之前」只能是截止日：remind 必须保持 null，客户端不得补一个时刻。
        XCTAssertNil(reportItem.remind)
        XCTAssertEqual(reportItem.due.kind, .date)
        XCTAssertEqual(reportItem.due.local, "2026-10-16")
        // 日期型截止日的 utc 必须是 null，不能伪造成当日午夜。
        XCTAssertNil(reportItem.due.utc)
        XCTAssertEqual(reportItem.ambiguities.count, 1)
        XCTAssertEqual(reportItem.ambiguities.first?.code, .deadlineOnly)
        XCTAssertTrue(reportItem.isDeadlineOnly)
        // deadline_only 属于提示性歧义，不强制要求用户先澄清才能保存。
        XCTAssertFalse(reportItem.requiresClarification)
    }

    func testDateTimeTaskCarriesAbsoluteTimeAndReminder() throws {
        let response = try DayCueJSON.decode(ExtractionResponse.self, from: fixtureJSON)
        let reviewItem = try XCTUnwrap(response.items.first { $0.itemId == "itm_task_review_pv" })

        XCTAssertEqual(reviewItem.due.kind, .datetime)
        XCTAssertEqual(reviewItem.due.local, "2026-10-12T20:00:00")
        XCTAssertEqual(reviewItem.due.utc, "2026-10-12T12:00:00Z")
        XCTAssertEqual(reviewItem.due.timezone, "Asia/Shanghai")
        XCTAssertEqual(reviewItem.remind?.local, "2026-10-12T20:00:00")
        XCTAssertFalse(reviewItem.isDeadlineOnly)
    }

    func testUnknownAmbiguityCodeRequiresClarification() throws {
        let json = #"""
        {
          "schema_version": "1.0",
          "capture_id": "cap_unknown",
          "mode": "live",
          "items": [
            {
              "item_id": "itm_1",
              "kind": "task",
              "title": "交作业",
              "source_evidence": "下下周交作业",
              "date_expression": "下下周",
              "due": { "kind": "none" },
              "remind": null,
              "ambiguities": [
                { "code": "some_future_code_v9", "field": "due", "message": "无法确定具体日期" }
              ]
            }
          ],
          "warnings": []
        }
        """#

        let response = try DayCueJSON.decode(ExtractionResponse.self, from: json)
        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.ambiguities.first?.code.rawValue, "some_future_code_v9")
        // 契约要求：未知 code 一律按「需要澄清」处理，不能忽略。
        XCTAssertTrue(item.requiresClarification)
    }

    func testErrorResponseDecodesModelOutputInvalid() throws {
        let json = #"""
        {
          "error": {
            "code": "model_output_invalid",
            "message": "模型返回的内容无法解析为结构化候选。",
            "retryable": true,
            "trace_id": "trace_abc123"
          }
        }
        """#

        let decoded = try DayCueJSON.decode(ErrorResponse.self, from: json)
        XCTAssertEqual(decoded.error.code, .modelOutputInvalid)
        XCTAssertTrue(decoded.error.retryable)
        XCTAssertTrue(decoded.error.code.isModelOutputInvalid)
        XCTAssertEqual(decoded.error.traceId, "trace_abc123")
    }

    func testReviewDraftKeepsDeadlineOnlyItemWithoutFabricatingReminder() throws {
        let response = try DayCueJSON.decode(ExtractionResponse.self, from: fixtureJSON)
        let drafts = ReviewDraft.from(response: response)

        XCTAssertEqual(drafts.count, 3)
        XCTAssertTrue(drafts.allSatisfy { $0.isFixture })

        let report = try XCTUnwrap(drafts.first { $0.id == "itm_task_report" })
        XCTAssertNil(report.remindLocal)
        XCTAssertNil(report.remindUTC)
        XCTAssertFalse(report.hasReminder)
        XCTAssertTrue(report.deadlineOnly)
        XCTAssertEqual(report.dueText, "2026-10-16")
        XCTAssertNil(report.remindText)
    }
}
