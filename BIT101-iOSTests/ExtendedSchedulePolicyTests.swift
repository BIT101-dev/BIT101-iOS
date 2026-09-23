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

    @Test("Week codec skips zero and keeps negative offsets contiguous")
    func weekCodecBoundaries() {
        let offsets = [-15, -8, -1, 0, 1, 7, 14]
        let weeks = offsets.map(ScheduleWeekCodec.weekNumber(forDayOffset:))

        #expect(weeks == [-3, -2, -1, 1, 1, 2, 3])
    }

    @Test("Automatic week policy only clamps calculated positions")
    func automaticWeekPolicy() {
        #expect(ScheduleAutomaticWeekPolicy.clamped(-100) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(-12) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(20) == 20)
        #expect(ScheduleAutomaticWeekPolicy.clamped(100) == 20)
    }

    @Test("Course rows preserve half-credit values")
    func preservesFractionalCredits() throws {
        let data = Data("""
        {
            "datas": {
                "cxxszhxqkb": {
                    "rows": [
                        {"KCM":"数安实践","KCH":"100120078","XF":1.5,"XS":24},
                        {"KCM":"软安实践","KCH":"100120084","XF":"1.5","XS":24}
                    ]
                }
            }
        }
        """.utf8)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)

        #expect(response.courseRecords.map(\.credit) == [1.5, 1.5])
        #expect(response.courseRecords.map(\.creditText) == ["1.5", "1.5"])
    }

    @Test("Unchanged source silently reapplies a manual course rule")
    func unchangedSourceReappliesManualRule() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [original]
        )

        #expect(result.invalidRules.isEmpty)
        #expect(result.validRules.count == 1)
        #expect(result.courses == [replacement])
    }

    @Test("Changes in another course leave this rule active")
    func unrelatedCourseChangeLeavesRuleActive() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let other = course(id: "other", number: "ENG-1", weeks: [1, 2, 3])
        let changedOther = course(id: "other", number: "ENG-1", weeks: [4, 5], weekday: 4)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [original, changedOther]
        )

        #expect(result.invalidRules.isEmpty)
        #expect(Set(result.courses) == Set([replacement, changedOther]))
        #expect(other != changedOther)
    }

    @Test("Any source change removes the corresponding manual rule")
    func changedSourceRemovesManualRule() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let changed = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], classroom: "新教室")
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [changed]
        )

        #expect(result.validRules.isEmpty)
        #expect(result.invalidRules.count == 1)
        #expect(result.courses == [changed])
    }

    @Test("Manual course rules survive cache encoding")
    func manualCourseRuleCacheRoundTrip() throws {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courses = [replacement]
        cache.schoolCoursesByTerm[original.term] = [original]
        cache.manualCourseRulesByTerm[original.term] = [
            ScheduleCourseRule(
                sourceIdentity: scheduleCourseSourceIdentity(original),
                sourceCourses: [original],
                replacementCourses: [replacement]
            )
        ]

        let decoded = try JSONDecoder().decode(
            ScheduleCache.self,
            from: JSONEncoder().encode(cache)
        )

        #expect(decoded.courses == [replacement])
        #expect(decoded.manualCourseRulesByTerm[original.term]?.count == 1)
        #expect(decoded.schoolCoursesByTerm[original.term] == [original])
    }

    @Test("Course editing rejects discontinuous sections")
    func discontinuousSectionsAreRejected() {
        var draft = CourseDraft(title: "课程", weeksText: "1")
        draft.selectedSections = [3, 5]
        draft.startSection = 3
        draft.endSection = 5

        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(draft)
        }
    }

    @Test("Course editing blocks overlaps with an existing course")
    func courseConflictIsBlocking() {
        let candidate = course(
            id: "candidate",
            number: "MATH-1",
            weeks: [2],
            weekday: 1,
            startSection: 3,
            endSection: 4
        )
        let existing = course(
            id: "existing",
            number: "ENG-1",
            weeks: [2],
            weekday: 1,
            startSection: 4,
            endSection: 5
        )

        #expect(
            ScheduleCourseEditor.conflictDescription(
                candidates: [candidate],
                against: [existing]
            ) != nil
        )
    }

    @Test("School authentication timeout uses the transport failure path")
    func schoolAuthenticationTimeoutClassification() {
        let error = ScheduleServiceError.challengeInvalid("统一身份认证请求超时，请稍后重试")

        #expect(error.isSchoolTransportFailure)
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

    @Test("Arrangement editing merges separated weeks")
    func arrangementEditingMergesSeparatedWeeks() throws {
        let firstPart = course(id: "course-a", number: "SOFT-1", weeks: [1, 2, 3, 4, 5])
        let secondPart = course(id: "course-b", number: "SOFT-1", weeks: [7, 8, 9])
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-5,7-9")
        draft.weekday = 2
        draft.startSection = 3
        draft.endSection = 4

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: firstPart.id,
            with: draft,
            in: [firstPart, secondPart]
        )

        #expect(result.count == 1)
        #expect(result[0].id == firstPart.id)
        #expect(result[0].weeks == [1, 2, 3, 4, 5, 7, 8, 9])
        #expect(result[0].weekday == 2)
        #expect(result[0].startSection == 3)
        #expect(result[0].endSection == 4)
    }

    @Test("Whole-course deletion removes every separated arrangement")
    func wholeCourseDeletionRemovesSeparatedWeeks() {
        let firstPart = course(id: "course-a", number: "SOFT-1", weeks: [1, 2, 3, 4, 5])
        let secondPart = course(id: "course-b", number: "SOFT-1", weeks: [7, 8, 9])
        let other = course(id: "other", number: "MATH-1", weeks: [1, 2])

        let result = ScheduleCourseEditor.deleting(id: firstPart.id, from: [firstPart, secondPart, other])

        #expect(result.map(\.id) == ["other"])
    }

    @Test("Arrangement editing keeps other time arrangements")
    func arrangementEditingKeepsOtherTimes() throws {
        let monday = course(id: "monday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 3)
        let thursday = course(id: "thursday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 4)
        let friday = course(id: "friday", number: "SOFT-1", weeks: [4, 5], weekday: 5)
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-3")
        draft.weekday = 6

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: monday.id,
            with: draft,
            in: [monday, thursday, friday]
        )

        #expect(result.count == 3)
        #expect(result.first(where: { $0.id == monday.id })?.weekday == 6)
        #expect(result.first(where: { $0.id == thursday.id })?.weekday == 4)
        #expect(result.first(where: { $0.id == friday.id })?.weekday == 5)
    }

    @Test("Different locations create independent arrangements")
    func arrangementEditingSeparatesLocations() throws {
        let literary = course(id: "literary", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "文萃楼F404")
        let comprehensive = course(id: "comprehensive", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "综教A101")
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-2")
        draft.classroom = "文萃楼F405"

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: literary.id,
            with: draft,
            in: [literary, comprehensive]
        )

        #expect(result.first(where: { $0.id == literary.id })?.classroom == "文萃楼F405")
        #expect(result.first(where: { $0.id == comprehensive.id })?.classroom == "综教A101")
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
        weekday: Int = 1,
        classroom: String = "教室",
        startSection: Int = 1,
        endSection: Int = 2
    ) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: number,
            teacher: "教师",
            classroom: classroom,
            description: "",
            weeks: weeks,
            weekday: weekday,
            startSection: startSection,
            endSection: endSection,
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
