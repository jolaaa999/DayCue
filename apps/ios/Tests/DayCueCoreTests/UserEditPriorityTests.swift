import Foundation
import XCTest
@testable import DayCueCore

/// 用户修订优先：capture_item.user_edited 置 1 之后，晚到的解析/识别结果不得覆盖文本。
final class UserEditPriorityTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: DayCueStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daycue-edit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        store = try DayCueStore(baseDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testExtractedTextIsAppliedWhenUserHasNotEdited() throws {
        try store.insertCapture(CaptureRecord(
            id: "cap_audio",
            kind: .audio,
            mediaPath: "/tmp/media/a.m4a",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        ))

        let applied = try store.applyExtractedText(id: "cap_audio", transcript: "今天讲了 PV 操作")
        XCTAssertTrue(applied)
        XCTAssertEqual(try store.capture(id: "cap_audio")?.transcript, "今天讲了 PV 操作")
    }

    func testLateExtractedTextCannotOverwriteUserEdit() throws {
        try store.insertCapture(CaptureRecord(
            id: "cap_audio",
            kind: .audio,
            transcript: "今天讲了 PV 操作",
            mediaPath: "/tmp/media/a.m4a",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        ))

        // 用户把识别错的文本改掉。
        try store.updateCaptureUserText(id: "cap_audio", rawText: "今天讲了 PV 操作，还有死锁")

        let afterEdit = try XCTUnwrap(try store.capture(id: "cap_audio"))
        XCTAssertTrue(afterEdit.userEdited)
        XCTAssertEqual(afterEdit.rawText, "今天讲了 PV 操作，还有死锁")
        XCTAssertEqual(afterEdit.effectiveText, "今天讲了 PV 操作，还有死锁")

        // 晚到的识别结果必须被拒绝。
        let applied = try store.applyExtractedText(id: "cap_audio", transcript: "今天讲了 PV 操作（机器识别）")
        XCTAssertFalse(applied, "用户已修订，晚到的识别结果不得写入")

        let final = try XCTUnwrap(try store.capture(id: "cap_audio"))
        XCTAssertEqual(final.rawText, "今天讲了 PV 操作，还有死锁")
        XCTAssertEqual(final.transcript, "今天讲了 PV 操作", "transcript 也不应该被覆盖")
        XCTAssertTrue(final.userEdited)
    }

    func testUserEditedFlagNeverResetsToFalse() throws {
        try store.insertCapture(CaptureRecord(
            id: "cap_text",
            kind: .text,
            rawText: "原始文本",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        ))

        try store.updateCaptureUserText(id: "cap_text", rawText: "修改后的文本")
        XCTAssertTrue(try store.capture(id: "cap_text")?.userEdited == true)

        // 即使后续再写一次识别文本（被拒绝），标志位也必须保持为真。
        _ = try store.applyExtractedText(id: "cap_text", transcript: "AI 结果")
        XCTAssertTrue(try store.capture(id: "cap_text")?.userEdited == true)
    }

    func testExtractionRequestPrefersUserEditedRawText() throws {
        let capture = CaptureRecord(
            id: "cap_build",
            kind: .image,
            rawText: "用户手改后的正文",
            ocrText: "OCR 原始结果",
            userEdited: true,
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        )

        let request = try ExtractionRequestBuilder.build(capture: capture)
        XCTAssertEqual(request.source.type, .ocr)
        // 用户编辑优先：raw_text 盖过 ocr_text。
        XCTAssertEqual(request.source.text, "用户手改后的正文")
        XCTAssertEqual(request.timezone, "Asia/Shanghai")
        XCTAssertEqual(request.recordedAt, "2026-10-11T13:00:00Z")
        XCTAssertEqual(request.schemaVersion, "1.0")
    }

    func testExtractionRequestRejectsEmptyText() throws {
        let capture = CaptureRecord(
            id: "cap_empty",
            kind: .text,
            rawText: "   ",
            recordedAt: "2026-10-11T13:00:00Z",
            recordedTimezone: "Asia/Shanghai"
        )
        XCTAssertThrowsError(try ExtractionRequestBuilder.build(capture: capture)) { error in
            XCTAssertEqual(error as? ExtractionRequestBuildError, .emptyText)
        }
    }
}
