import Foundation
import XCTest
@testable import DayCueCore

/// 迟到结果不能被当作当前输入的可执行结果。
///
/// 这里测的是判定逻辑本身；真实的"网络慢、用户又点了一次"只能靠真机或集成测试，
/// 但判定规则如果能被证明，界面层就只是照做。
final class ExtractionFreshnessTests: XCTestCase {

    private func capture(
        id: String = "cap_1",
        text: String = "明晚八点提醒我复习",
        recordedAt: String = "2026-10-11T11:30:00Z",
        userEdited: Bool = false
    ) -> CaptureRecord {
        CaptureRecord(
            id: id,
            kind: .text,
            rawText: text,
            userEdited: userEdited,
            recordedAt: recordedAt,
            recordedTimezone: "Asia/Shanghai"
        )
    }

    func testSameInputAndLatestGenerationIsActionable() {
        let record = capture()
        let version = CaptureInputVersion.make(from: record)

        let freshness = ExtractionFreshnessPolicy.evaluate(
            request: version,
            current: CaptureInputVersion.make(from: record),
            generation: 3,
            latestGeneration: 3
        )
        XCTAssertEqual(freshness, .current)
        XCTAssertTrue(freshness.isActionable)
        XCTAssertNil(freshness.rejectionMessage)
    }

    func testOlderGenerationIsSupersededEvenIfInputIsUnchanged() {
        let record = capture()
        let version = CaptureInputVersion.make(from: record)

        let freshness = ExtractionFreshnessPolicy.evaluate(
            request: version,
            current: CaptureInputVersion.make(from: record),
            generation: 1,
            latestGeneration: 2
        )
        XCTAssertEqual(freshness, .superseded, "更新的解析请求已经把这次取代了")
        XCTAssertFalse(freshness.isActionable)
        XCTAssertNotNil(freshness.rejectionMessage)
    }

    func testInputChangedMidFlightIsRejected() {
        let version = CaptureInputVersion.make(from: capture(text: "明晚八点提醒我复习"))

        // 请求期间正文被改成了别的日期。
        let freshness = ExtractionFreshnessPolicy.evaluate(
            request: version,
            current: CaptureInputVersion.make(from: capture(text: "后天下午三点交作业")),
            generation: 1,
            latestGeneration: 1
        )
        XCTAssertEqual(freshness, .inputChanged)
        XCTAssertFalse(freshness.isActionable)
    }

    func testDeletedCaptureMakesResultUnusable() {
        let version = CaptureInputVersion.make(from: capture())
        let freshness = ExtractionFreshnessPolicy.evaluate(
            request: version,
            current: nil,
            generation: 1,
            latestGeneration: 1
        )
        XCTAssertEqual(freshness, .inputChanged, "记录没了，结果自然不能落成任务")
    }

    /// 用户编辑标记本身也要进指纹：同文本但编辑来源不同，语义不同。
    func testUserEditedFlagChangesFingerprint() {
        let raw = CaptureInputVersion.make(from: capture(text: "同一段文字", userEdited: false))
        let edited = CaptureInputVersion.make(from: capture(text: "同一段文字", userEdited: true))
        XCTAssertNotEqual(raw.fingerprint, edited.fingerprint)
        XCTAssertFalse(raw.isUserEdited)
        XCTAssertTrue(edited.isUserEdited)
    }

    /// 录入时间是相对日期的解析基准，改了它结果就会变，因此必须进指纹。
    func testRecordedAtChangesFingerprint() {
        let a = CaptureInputVersion.make(from: capture(recordedAt: "2026-10-11T11:30:00Z"))
        let b = CaptureInputVersion.make(from: capture(recordedAt: "2026-10-12T11:30:00Z"))
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func testFingerprintIsStableForUnchangedCapture() {
        let a = CaptureInputVersion.make(from: capture())
        let b = CaptureInputVersion.make(from: capture())
        XCTAssertEqual(a, b, "同一个输入版本必须每次都得到同一个指纹")
    }
}
