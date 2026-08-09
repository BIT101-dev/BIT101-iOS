import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Schedule iCalendar parsing")
struct ScheduleICSParserTests {
    @Test("Events are unfolded, decoded and sorted")
    func parsesEvents() throws {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:later\r
        SUMMARY:实验\\,报告\r
        DTSTART;TZID=Asia/Shanghai:20260810T120000\r
        CATEGORIES:编译原理\r
        DESCRIPTION:第一行\\n第二行很\r
         长\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:earlier\r
        SUMMARY:作业\r
        DTSTART:20260810T010000Z\r
        END:VEVENT\r
        END:VCALENDAR
        """

        let events = try ScheduleICSParser.parse(ics)
        #expect(events.map(\.id) == ["earlier", "later"])
        #expect(events[1].title == "实验,报告")
        #expect(events[1].text == "编译原理\n\n第一行\n第二行很长")
        #expect(events.allSatisfy { $0.group == "lexue" && !$0.done })
    }

    @Test("Date-only values use the school timezone")
    func parsesDateOnlyValue() throws {
        let date = try #require(ScheduleICSParser.parseDate("20260810"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)

        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 10)
        #expect(components.hour == 0)
    }

    @Test("Calendars without valid events are rejected")
    func rejectsInvalidCalendar() {
        #expect(throws: ScheduleServiceError.self) {
            try ScheduleICSParser.parse("BEGIN:VCALENDAR\nEND:VCALENDAR")
        }
    }
}
