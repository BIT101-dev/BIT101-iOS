import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Schedule course editing")
struct ScheduleCourseEditorTests {
    @Test("Week ranges accept Chinese punctuation, deduplicate and sort")
    func parsesWeekRanges() throws {
        #expect(try ScheduleCourseEditor.parseWeeks("3，1-2, 2,5-6") == [1, 2, 3, 5, 6])
        #expect(ScheduleCourseEditor.formatWeeks([6, 2, 1, 5, 2, 3]) == "1-3,5-6")
    }

    @Test("Invalid week ranges are rejected")
    func rejectsInvalidWeeks() {
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("0,2") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("4-2") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("1-2-3") }
    }

    @Test("Draft resolution trims fields and supports a fixed occurrence week")
    func resolvesDraft() throws {
        let draft = CourseDraft(
            title: "  编译原理  ",
            teacher: " 教师 ",
            classroom: " 综教A101 ",
            weekday: 3,
            startSection: 3,
            endSection: 5,
            weeksText: "1-16"
        )

        let resolved = try ScheduleCourseEditor.resolve(draft, fixedWeeks: [8])
        #expect(resolved.title == "编译原理")
        #expect(resolved.teacher == "教师")
        #expect(resolved.classroom == "综教A101")
        #expect(resolved.weeks == [8])
        #expect(resolved.weekday == 3)
        #expect(resolved.startSection == 3)
        #expect(resolved.endSection == 5)
    }

    @Test("Draft resolution validates required and bounded fields")
    func validatesDraft() {
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(CourseDraft(title: " ", weeksText: "1"))
        }
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(CourseDraft(title: "课程", weekday: 8, weeksText: "1"))
        }
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(CourseDraft(
                title: "课程",
                startSection: 3,
                endSection: 2,
                weeksText: "1"
            ))
        }
    }
}

@Suite("Classroom availability calculation")
struct ClassroomAvailabilityCalculatorTests {
    private let timeTable = [
        TimeSlot(id: 1, start: "08:00", end: "08:45"),
        TimeSlot(id: 2, start: "08:50", end: "09:35"),
        TimeSlot(id: 3, start: "09:55", end: "10:40"),
    ]

    @Test("A free room reports the next busy start")
    func reportsFreeUntilNextClass() {
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [2])
        let item = ClassroomAvailabilityCalculator.availability(
            for: record,
            timeTable: timeTable,
            nowMinutes: 8 * 60 + 30
        )

        #expect(item.isFreeNow)
        #expect(item.statusText == "还会空闲 20 分钟")
        #expect(item.detailText == "直到 08:50")
        #expect(item.freeSections == [1, 3])
        #expect(item.prettyFreeTimes == "1, 3")
    }

    @Test("A busy room reports the next free slot")
    func reportsNextFreeSlot() {
        let record = ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1, 2])
        let item = ClassroomAvailabilityCalculator.availability(
            for: record,
            timeTable: timeTable,
            nowMinutes: 9 * 60
        )

        #expect(!item.isFreeNow)
        #expect(item.statusText == "55 分钟 后空闲")
        #expect(item.detailText == "09:55")
    }

    @Test("Filters retain rooms free in any selected section")
    func filtersSelectedSections() {
        let records = [
            ClassroomRecord(id: "a", name: "101", busyTimeCodes: [1]),
            ClassroomRecord(id: "b", name: "102", busyTimeCodes: [2]),
        ]
        let result = ClassroomAvailabilityCalculator.availabilities(
            records: records,
            timeTable: timeTable,
            selectedSections: [2, 2, 99],
            nowMinutes: 7 * 60
        )

        #expect(result.map(\.id) == ["a"])
        #expect(ClassroomAvailabilityCalculator.normalizedSections([99, 2, 2, 1], in: timeTable) == [1, 2])
    }

    @Test("Section and building helpers handle schedule conventions")
    func presentationHelpers() {
        #expect(ClassroomAvailabilityCalculator.sectionsText([5, 3, 4, 8]) == "3~5, 8")
        #expect(ClassroomAvailabilityCalculator.sectionBlock(at: 10 * 60, in: TimeSlot.default) == [3, 4, 5])
        #expect(ClassroomAvailabilityCalculator.normalizedBuildingName(" 理教楼 A-101 ") == "理教A101")
        #expect(ClassroomAvailabilityCalculator.buildingCandidates(from: "综教A101") == ["综教A101", "综教A"])
    }
}
