import Foundation
import Testing
@testable import BIT101_iOS

private func shanghaiDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Academic term policy")
struct AcademicTermPolicyTests {
    @Test("March and September roll to the next adjacent pair")
    func adjacentTermPairs() {
        #expect(AcademicTermPolicy.adjacentTerms(on: shanghaiDate(2026, 2, 28)) == [
            "2025-2026-1", "2025-2026-2",
        ])
        #expect(AcademicTermPolicy.adjacentTerms(on: shanghaiDate(2026, 3, 1)) == [
            "2025-2026-2", "2026-2027-1",
        ])
        #expect(AcademicTermPolicy.adjacentTerms(on: shanghaiDate(2026, 9, 1)) == [
            "2026-2027-1", "2026-2027-2",
        ])
    }

    @Test("Automatic score refresh runs only after week 16 and before next term")
    func scoreRefreshWindow() {
        let cache = makeSpringToFallCache()

        #expect(!ScoreAutomaticRefreshPolicy.isWithinRefreshWindow(
            cache: cache,
            now: shanghaiDate(2026, 6, 21)
        ))
        #expect(ScoreAutomaticRefreshPolicy.isWithinRefreshWindow(
            cache: cache,
            now: shanghaiDate(2026, 6, 22)
        ))
        #expect(!ScoreAutomaticRefreshPolicy.isWithinRefreshWindow(
            cache: cache,
            now: shanghaiDate(2026, 8, 31)
        ))
    }

    @Test("Vacation suppresses teaching resources and ends on the next first week")
    func academicActivityPhase() {
        let cache = makeSpringToFallCache()
        #expect(AcademicTermPolicy.activityPhase(
            cache: cache,
            on: shanghaiDate(2026, 6, 21)
        ) == .teaching)
        #expect(AcademicTermPolicy.activityPhase(
            cache: cache,
            on: shanghaiDate(2026, 6, 22)
        ) == .vacation)
        #expect(AcademicTermPolicy.activityPhase(
            cache: cache,
            on: shanghaiDate(2026, 8, 30)
        ) == .vacation)
        #expect(AcademicTermPolicy.activityPhase(
            cache: cache,
            on: shanghaiDate(2026, 8, 31)
        ) == .teaching)
        #expect(AcademicTermPolicy.preferredCachedTerm(
            cache: cache,
            on: shanghaiDate(2026, 8, 31)
        ) == "2026-2027-1")
    }

    @Test("Smart switching never reverts an explicitly selected upcoming term")
    func upcomingTermSelectionIsStable() {
        var cache = makeSpringToFallCache()
        let beforeFirstWeek = shanghaiDate(2026, 8, 26)

        cache.currentTerm = "2025-2026-2"
        #expect(AcademicTermPolicy.preferredCachedTerm(
            cache: cache,
            on: beforeFirstWeek
        ) == "2025-2026-2")

        cache.currentTerm = "2026-2027-1"
        #expect(AcademicTermPolicy.preferredCachedTerm(
            cache: cache,
            on: beforeFirstWeek
        ) == "2026-2027-1")
    }

    private func makeSpringToFallCache() -> ScheduleCache {
        var cache = ScheduleCache()
        cache.termSchedulesByTerm["2025-2026-2"] = TermScheduleSnapshot(
            term: "2025-2026-2",
            firstDayString: "2026-03-02",
            courses: [],
            exams: [],
            updatedAt: shanghaiDate(2026, 3, 2)
        )
        cache.termSchedulesByTerm["2026-2027-1"] = TermScheduleSnapshot(
            term: "2026-2027-1",
            firstDayString: "2026-08-31",
            courses: [],
            exams: [],
            updatedAt: shanghaiDate(2026, 8, 1)
        )
        return cache
    }
}

@Suite("Small-term week normalization")
struct SmallTermWeekNormalizerTests {
    @Test("First-semester small terms shift dates and labels together")
    func normalizesFirstSemester() {
        let courses = [
            makeCourse(id: "a", description: "1-5周 星期一", weeks: Array(4 ... 8)),
            makeCourse(id: "b", description: "7-12周 星期一", weeks: Array(10 ... 15)),
        ]
        let result = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-1",
            firstDayString: "2026-08-31",
            courses: courses
        )

        #expect(result.offset == 3)
        #expect(result.firstDayString == "2026-09-21")
        #expect(result.courses[0].weeks == Array(1 ... 5))
        #expect(result.courses[1].weeks == Array(7 ... 12))
    }

    @Test("Second semester never applies small-term correction")
    func leavesSecondSemesterUnchanged() {
        let course = makeCourse(id: "a", description: "1-5周 星期一", weeks: Array(4 ... 8))
        let result = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-2",
            firstDayString: "2027-03-01",
            courses: [course]
        )

        #expect(result.offset == 0)
        #expect(result.firstDayString == "2027-03-01")
        #expect(result.courses == [course])
    }

    @Test("Conflicting evidence fails closed")
    func rejectsMixedOffsets() {
        let courses = [
            makeCourse(id: "a", description: "1-5周 星期一", weeks: Array(4 ... 8)),
            makeCourse(id: "b", description: "1-5周 星期二", weeks: Array(1 ... 5)),
        ]
        let result = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-1",
            firstDayString: "2026-08-31",
            courses: courses
        )

        #expect(result.offset == 0)
        #expect(result.firstDayString == "2026-08-31")
        #expect(result.courses == courses)
    }

    private func makeCourse(id: String, description: String, weeks: [Int]) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: "测试课程\(id)",
            teacher: "",
            classroom: "",
            description: description,
            weeks: weeks,
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "",
            number: id,
            credit: 1,
            hour: 16,
            type: "",
            category: "",
            department: ""
        )
    }
}

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

@MainActor
@Suite("Schedule sharing codec")
struct ScheduleShareCodeCodecTests {
    @Test("Latest exports use V3 and preserve course credits")
    func v3RoundTrip() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "2025-2026-2"
        cache.firstDayString = "2026-03-02"
        cache.courses = [CourseRecord(
            id: "course-1",
            term: cache.currentTerm,
            name: "编译原理",
            teacher: "教师",
            classroom: "综教A101",
            description: "",
            weeks: [1, 2, 3],
            weekday: 3,
            startSection: 3,
            endSection: 5,
            campus: "良乡",
            number: "100001",
            credit: 4,
            hour: 48,
            type: "专业课",
            category: "必修",
            department: "计算机学院"
        )]

        let code = try ScheduleShareCodeCodec.encodeLatest(cache: cache)
        let decoded = try ScheduleShareCodeCodec.decode(code, using: cache)

        #expect(code.hasPrefix("BIT101SCH3:"))
        #expect(decoded.courses.count == 1)
        #expect(decoded.courses[0].name == "编译原理")
        #expect(decoded.courses[0].credit == 4)
    }

    @Test("A newer share format requests an app update")
    func unsupportedNewerFormat() {
        #expect(throws: ScheduleShareCodeError.unsupportedNewerFormat(4)) {
            _ = try ScheduleShareCodeCodec.decode("BIT101SCH4:anything", using: ScheduleCache())
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
