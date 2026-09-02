#if EXTENDED_AUTOMATION
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Extended schedule invariants")
struct ExtendedSchedulePolicyTests {
    @Test("Display modes expose stable identifiers and titles")
    func displayModesAreStable() {
        #expect(ScheduleDisplayMode.allCases.map(\.rawValue) == ["weekly", "allWeeks"])
        #expect(ScheduleDisplayMode.weekly.title == "按周显示")
        #expect(ScheduleDisplayMode.allWeeks.title == "全学期叠加")
    }

    @Test("Display mode survives cache encoding")
    func displayModeRoundTrip() throws {
        var cache = ScheduleCache()
        cache.scheduleDisplayMode = .allWeeks

        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: data)

        #expect(decoded.scheduleDisplayMode == .allWeeks)
    }

    @Test("Old caches default to weekly display")
    func oldCacheDefaultsToWeekly() throws {
        let data = Data(#"{"currentTerm":"2026-2027-1","courses":[]}"#.utf8)
        let cache = try JSONDecoder().decode(ScheduleCache.self, from: data)

        #expect(cache.scheduleDisplayMode == .weekly)
    }

    @Test("Course replacement policy rejects empty, reduced and identical responses")
    func courseReplacementPolicyRejectsUnsafeResponses() {
        let old = course(id: "old", number: "MATH-1")
        let same = course(id: "same", number: "MATH-1")

        #expect(!CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: []))
        #expect(!CourseSyncReplacementPolicy.shouldReplace(existing: [old, same], with: [old]))
        #expect(!CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [old]))
    }

    @Test("Course replacement policy accepts a response containing a new course")
    func courseReplacementPolicyAcceptsAddedCourse() {
        let old = course(id: "old", number: "MATH-1")
        let added = course(id: "added", number: "ENG-1")

        #expect(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [old, added]))
        #expect(CourseSyncReplacementPolicy.shouldReplace(existing: [old], with: [added]))
    }

    @Test("Week codec skips zero and keeps negative offsets contiguous")
    func weekCodecBoundaries() {
        let offsets = [-15, -8, -1, 0, 1, 7, 14]
        let weeks = offsets.map(ScheduleWeekCodec.weekNumber(forDayOffset:))

        #expect(weeks == [-3, -2, -1, 1, 1, 2, 3])
        #expect(ScheduleWeekCodec.previousWeek(before: 1) == -1)
        #expect(ScheduleWeekCodec.nextWeek(after: -1) == 1)
    }

    @Test("Automatic week policy only clamps calculated positions")
    func automaticWeekPolicy() {
        #expect(ScheduleAutomaticWeekPolicy.clamped(-100) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(-12) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(20) == 20)
        #expect(ScheduleAutomaticWeekPolicy.clamped(100) == 20)
    }

    @Test("Course week parser accepts Chinese commas and removes duplicates")
    func courseWeekParser() throws {
        #expect(try ScheduleCourseEditor.parseWeeks("1-3，3，5") == [1, 2, 3, 5])
        #expect(ScheduleCourseEditor.formatWeeks([5, 3, 2, 1, 3]) == "1-3,5")
    }

    @Test("Course editor rejects malformed week ranges")
    func courseWeekParserRejectsMalformedRanges() {
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("0-3") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("3-1") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("1,a") }
    }

    @Test("Occurrence editing splits a repeated course")
    func occurrenceEditingSplitsRepeatedCourse() throws {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        var draft = CourseDraft(title: "调整后的课", weeksText: "")
        draft.weekday = 5

        let result = try ScheduleCourseEditor.updatingOccurrence(
            id: original.id,
            week: 2,
            with: draft,
            in: [original],
            adjustedID: "adjusted"
        )

        #expect(result.count == 2)
        #expect(result[0].weeks == [1, 3])
        #expect(result[1].id == "adjusted")
        #expect(result[1].weeks == [2])
        #expect(result[1].weekday == 5)
    }

    @Test("Deleting the last occurrence removes the course")
    func deletingLastOccurrenceRemovesCourse() {
        let original = course(id: "course", number: "MATH-1", weeks: [2])

        #expect(ScheduleCourseEditor.deletingOccurrence(id: original.id, week: 2, from: [original]).isEmpty)
    }

    @Test("Transferring a day clears source and target occurrences")
    func transferringCourses() {
        let source = course(id: "source", number: "MATH-1", weeks: [2], weekday: 1)
        let target = course(id: "target", number: "ENG-1", weeks: [3], weekday: 5)

        let result = ScheduleCourseEditor.transferring(
            courses: [source, target],
            fromWeek: 2,
            fromWeekday: 1,
            toWeek: 3,
            toWeekday: 5,
            makeID: { "moved" }
        )

        #expect(result.count == 1)
        #expect(result[0].id == "moved")
        #expect(result[0].weeks == [3])
        #expect(result[0].weekday == 5)
    }

    @Test("DDL merge keeps manual items and sorts all events")
    func ddlMerge() {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let manual = DDLEventRecord(id: "manual", group: "main", title: "手动", text: "", dueAt: newDate, done: true)
        let synced = DDLEventRecord(id: "synced", group: "lexue", title: "乐学", text: "", dueAt: oldDate, done: false)
        let oldSynced = DDLEventRecord(id: "old-synced", group: "lexue", title: "旧", text: "", dueAt: Date(timeIntervalSince1970: 50), done: true)

        let result = ScheduleDDLEditor.mergingSyncedEvents([synced], into: [manual, oldSynced])

        #expect(result.map(\.id) == ["synced", "manual"])
        #expect(result.first?.done == false)
    }

    @Test("DDL editor rejects blank titles")
    func ddlTitleValidation() {
        let draft = DDLDraft(title: "  ")
        #expect(throws: Error.self) { try ScheduleDDLEditor.adding(draft, to: []) }
    }

    private func course(
        id: String,
        number: String,
        weeks: [Int] = [1],
        weekday: Int = 1
    ) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: number,
            teacher: "教师",
            classroom: "教室",
            description: "",
            weeks: weeks,
            weekday: weekday,
            startSection: 1,
            endSection: 2,
            campus: "",
            number: number,
            credit: 2,
            hour: 32,
            type: "",
            category: "",
            department: ""
        )
    }
}
#endif
