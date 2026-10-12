import Foundation
import XCTest
@testable import DayCueCore

/// ICS 解析与展开测试。
///
/// 时间基准（DTSTART、回退时区、展开区间）全部显式写在用例里，
/// 不用「今天」，所以在任何日期执行结果都一致。
final class ICSParserTests: XCTestCase {

    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utcZone = TimeZone(identifier: "UTC")!

    private func utc(_ text: String) -> Date {
        RFC3339.date(fromUTC: text)!
    }

    /// RFC5545 要求每一行以 CRLF 结束；这里统一拼装，避免手写多行字符串时漏掉。
    private func ics(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - 三种 DTSTART

    func testUTCDateTimeIsAbsoluteInstant() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:utc-1",
            "SUMMARY:操作系统",
            "DTSTART:20260302T000000Z",
            "DTEND:20260302T014000Z",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let parsed = ICSParser.parse(text: text, fallbackTimeZone: shanghai)
        XCTAssertEqual(parsed.skippedLineCount, 0)
        let event = try XCTUnwrap(parsed.events.first)
        XCTAssertEqual(event.dtStart.kind, .utc)
        XCTAssertEqual(event.dtStart.date, utc("2026-03-02T00:00:00Z"))
        XCTAssertEqual(event.summary, "操作系统")
    }

    func testTZIDDateTimeUsesNamedZone() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:tzid-1",
            "SUMMARY:高等数学",
            "DTSTART;TZID=Asia/Shanghai:20260302T080000",
            "DTEND;TZID=Asia/Shanghai:20260302T094000",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let parsed = ICSParser.parse(text: text, fallbackTimeZone: utcZone)
        let event = try XCTUnwrap(parsed.events.first)
        XCTAssertEqual(event.dtStart.kind, .zoned)
        XCTAssertEqual(event.dtStart.timeZoneIdentifier, "Asia/Shanghai")
        // 周一 08:00 +08:00 就是 00:00Z。
        XCTAssertEqual(event.dtStart.date, utc("2026-03-02T00:00:00Z"))
    }

    func testFloatingDateTimeFollowsFallbackTimeZone() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:floating-1",
            "SUMMARY:大学物理",
            "DTSTART:20260302T080000",
            "DTEND:20260302T094000",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        // 同一份文件、同一个墙上时间，回退时区不同就必须解析成不同瞬间——
        // 这正是「浮动时间」的含义，也是课表最容易排错的地方。
        let inShanghai = try XCTUnwrap(ICSParser.parse(text: text, fallbackTimeZone: shanghai).events.first)
        let inUTC = try XCTUnwrap(ICSParser.parse(text: text, fallbackTimeZone: utcZone).events.first)

        XCTAssertEqual(inShanghai.dtStart.kind, .floating)
        XCTAssertEqual(inShanghai.dtStart.date, utc("2026-03-02T00:00:00Z"))

        XCTAssertEqual(inUTC.dtStart.kind, .floating)
        XCTAssertEqual(inUTC.dtStart.date, utc("2026-03-02T08:00:00Z"))
    }

    // MARK: - 重复规则展开

    func testWeeklyIntervalTwoByDayExpandsToFiveOccurrences() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:weekly-1",
            "SUMMARY:操作系统",
            "DTSTART:20260302T000000Z",
            "DTEND:20260302T014000Z",
            "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let event = try XCTUnwrap(ICSParser.parse(text: text, fallbackTimeZone: shanghai).events.first)
        let expanded = ICSParser.occurrences(
            of: event,
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-03-31T23:59:59Z"),
            fallbackTimeZone: shanghai
        )

        // 隔周上课、每周一和周三：第 0 周（3/2、3/4）、第 2 周（3/16、3/18）、第 4 周（3/30）。
        XCTAssertEqual(expanded.dates.map(\.date), [
            utc("2026-03-02T00:00:00Z"),
            utc("2026-03-04T00:00:00Z"),
            utc("2026-03-16T00:00:00Z"),
            utc("2026-03-18T00:00:00Z"),
            utc("2026-03-30T00:00:00Z")
        ])
    }

    func testExDateRemovesExcludedOccurrence() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:weekly-2",
            "SUMMARY:操作系统",
            "DTSTART:20260302T000000Z",
            "DTEND:20260302T014000Z",
            "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
            "EXDATE:20260304T000000Z",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let event = try XCTUnwrap(ICSParser.parse(text: text, fallbackTimeZone: shanghai).events.first)
        let expanded = ICSParser.occurrences(
            of: event,
            rangeStart: utc("2026-03-01T00:00:00Z"),
            rangeEnd: utc("2026-03-31T23:59:59Z"),
            fallbackTimeZone: shanghai
        )

        XCTAssertEqual(expanded.dates.count, 4)
        XCTAssertFalse(expanded.dates.contains { $0.date == utc("2026-03-04T00:00:00Z") })
    }

    // MARK: - 坏行容错

    func testBadLinesAreSkippedButTheRestStillImports() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:good-1",
            "SUMMARY:高等数学",
            "DTSTART:20260302T000000Z",
            "DTEND:20260302T014000Z",
            // 不含冒号的垃圾行：应当只跳过这一行。
            "THIS-LINE-HAS-NO-COLON",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:broken-2",
            "SUMMARY:缺少开始时间的事件",
            // 没有 DTSTART，这个事件整体无法使用，但不能连累上面那一个。
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let parsed = ICSParser.parse(text: text, fallbackTimeZone: shanghai)

        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events.first?.summary, "高等数学")
        // 一行无法解析 + 一个事件缺少 DTSTART。
        XCTAssertGreaterThanOrEqual(parsed.skippedLineCount, 2)
        XCTAssertFalse(parsed.warnings.isEmpty)
    }

    // MARK: - 折行还原

    func testFoldedSummaryIsRestored() throws {
        let text = ics([
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:folded-1",
            "SUMMARY:计算机组成原理与汇",
            " 编语言程序设计",
            "DTSTART:20260302T000000Z",
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let event = try XCTUnwrap(ICSParser.parse(text: text, fallbackTimeZone: shanghai).events.first)
        XCTAssertEqual(event.summary, "计算机组成原理与汇编语言程序设计")
    }
}
