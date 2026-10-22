import Foundation
import ScheduleContracts
import ScheduleDomain
import SchedulePorts
@testable import ScheduleFeature
import Testing

struct ScheduleExternalProjectionTests {
    private func personal(_ dates: [String] = ["2030-10-01", "2030-10-08"], begin: String = "09:00", end: String = "10:00") -> ScheduleExternalCustomScheduleSnapshot {
        .init(id: "personal", title: "讨论", subtitle: "图书馆", dateStrings: dates, beginTime: begin, endTime: end)
    }

    private func snapshot(_ items: [ScheduleExternalCustomScheduleSnapshot]) -> ScheduleExternalSnapshot {
        .init(isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [], customSchedules: items)
    }

    @Test func personalSchedulesSurviveEncodingAccountReplacementAndRevision() throws {
        let item = personal(), source = snapshot([personal()])
        let advanced = try #require(source.replacingStudentID(with: "other-owner").advancingRevision(after: 10))
        let decoded = try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(advanced))
        #expect(decoded.customSchedules == [item] && decoded.studentID == "other-owner" && decoded.revision == 11)
        var legacy = try #require(JSONSerialization.jsonObject(with: ScheduleExternalSnapshotCodec.encode(source)) as? [String: Any])
        legacy.removeValue(forKey: "customSchedules")
        #expect(try ScheduleExternalSnapshotCodec.decode(JSONSerialization.data(withJSONObject: legacy)).customSchedules.isEmpty)
    }

    @Test func personalOnlySnapshotsExpandRepeatingDatesAndAdvanceAfterEachOccurrence() throws {
        let source = snapshot([personal()])
        let before = try #require(ScheduleSharedDateCodec.parseDate("2030-10-01"))
        let all = ScheduleOccurrenceResolver.resolvedSnapshot(from: source, now: before)
        #expect(all.contentState == .ready && all.upcomingOccurrences.count == 2)
        #expect(all.nextOccurrence?.title == "讨论" && all.nextOccurrence?.classroom == "图书馆")
        let end = try #require(all.nextOccurrence?.endDate)
        let next = ScheduleOccurrenceResolver.resolvedSnapshot(from: source, now: end)
        #expect(next.nextOccurrence?.id == "custom-personal-2030-10-08")
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: source, now: before.addingTimeInterval(8 * 86_400)).contentState == .rest)
        let timeline = ScheduleOccurrenceResolver.resolvedTimeline(from: source, now: before, includeDisplayUntilDates: true, limit: 1)
        #expect(timeline.contains { $0.date == end && $0.resolved.nextOccurrence?.id == "custom-personal-2030-10-08" })
    }

    @Test(arguments: ["duplicate-date", "invalid-date", "invalid-time", "oversized-title", "duplicate-id"])
    func invalidPersonalSchedulesStayAtTheSharedValidationBoundary(damage: String) {
        let item = damage == "oversized-title"
            ? ScheduleExternalCustomScheduleSnapshot(id: "personal", title: String(repeating: "a", count: ScheduleCourseConstraints.maximumFieldBytes + 1),
                subtitle: "", dateStrings: ["2030-10-01"], beginTime: "09:00", endTime: "10:00")
            : personal(damage == "duplicate-date" ? ["2030-10-01", "2030-10-01"] : [damage == "invalid-date" ? "2030-02-30" : "2030-10-01"],
                begin: damage == "invalid-time" ? "24:00" : "09:00")
        let source = snapshot(damage == "duplicate-id" ? [item, item] : [item])
        #expect(throws: (any Error).self) { try ScheduleExternalSnapshotCodec.encode(source) }
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: source).contentState == .invalid)
    }

    @Test func denseDeadlineTimelinesRemainBoundedAndContinueAtTheVisibleWindowBoundary() throws {
        let now = try #require(ScheduleSharedDateCodec.parseDate("2030-10-01"))
        let deadlines = (0..<ScheduleExternalSnapshotCodec.maximumCourseCount).reversed().map { index in
            ScheduleExternalDeadlineSnapshot(id: "ddl-\(index)", title: "报告", subtitle: "", sourceTitle: "自定义",
                dueAt: now.addingTimeInterval(Double(index + 1) * 10))
        }
        let source = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [], deadlines: deadlines, ddlAfterDay: 0)
        let entries = ScheduleDeadlineResolver.timelineEntries(from: source, now: now)
        #expect(entries.count <= 2 * ScheduleDeadlineResolver.defaultLimit + 3)
        #expect(entries.first?.resolved.deadlines.map(\.id) == ["ddl-0", "ddl-1", "ddl-2", "ddl-3"])
        let last = try #require(entries.last)
        #expect(last.date == now.addingTimeInterval(11))
        #expect(last.resolved.deadlines.map(\.id) == ["ddl-1", "ddl-2", "ddl-3", "ddl-4"])
        let continuation = ScheduleDeadlineResolver.timelineEntries(from: source, now: last.date)
        #expect(continuation.last?.date == now.addingTimeInterval(21))
    }

    @Test func calendarMarkersResolveTheExactCourseWeekExamAndRepeatedPersonalDate() throws {
        let course = try #require(ScheduleCourseEditor.adding(CourseDraft(title: "课程", weeksText: "-2,-1,1-3"), to: [], term: "term", id: "course").first)
        for week in [-2, 2] {
            guard case let .course(found, actualWeek) = ScheduleSystemCalendarTarget.resolve(markerID: ScheduleSystemCalendarMarkerID.course(course.id, week: week),
                courses: [course], exams: [], customSchedules: []) else { Issue.record("日历链接应定位课程。"); return }
            #expect(found.id == course.id && actualWeek == week)
        }
        let exam = ExamRecord(id: "exam", term: "term", name: "考试", courseID: "course", teacher: "", classroom: "",
            dateString: "2030-10-01", beginTime: "09:00", endTime: "11:00", examMode: "", seatID: "")
        guard case let .exam(found) = ScheduleSystemCalendarTarget.resolve(markerID: ScheduleSystemCalendarMarkerID.exam(exam.id), courses: [], exams: [exam], customSchedules: [])
        else { Issue.record("日历链接应定位考试。"); return }
        #expect(found == exam)
        let item = CustomScheduleRecord(id: "personal", title: "讨论", subtitle: "", description: "", dateString: "2030-10-01",
            beginTime: "09:00", endTime: "10:00", additionalDateStrings: ["2030-10-08"])
        guard case let .custom(found, date) = ScheduleSystemCalendarTarget.resolve(markerID: item.occurrenceID(for: "2030-10-08"),
            courses: [], exams: [], customSchedules: [item]) else { Issue.record("日历链接应定位重复日程。"); return }
        #expect(found == item && date == "2030-10-08")
        #expect(ScheduleSystemCalendarTarget.resolve(markerID: "unknown", courses: [course], exams: [exam], customSchedules: [item]) == nil)
    }
}
