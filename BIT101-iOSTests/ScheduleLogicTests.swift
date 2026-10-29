import SchedulePorts
@testable import CourseFeature
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScheduleDomain
import ScheduleContracts
import Foundation
import EventKit
import Testing
@testable import BIT101_iOS

private func shanghaiDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    guard let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
        preconditionFailure("Asia/Shanghai time zone unavailable")
    }
    calendar.timeZone = timeZone
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
        preconditionFailure("Invalid test date")
    }
    return date
}

@Suite("System calendar schedule export")
struct ScheduleSystemCalendarEventBuilderTests {
    @Test("Calendar export applies the shared week bounds before date arithmetic")
    func calendarExportKeepsValidWeekBoundaries() throws {
        let original = try #require(ScheduleCourseEditor.adding(
            CourseDraft(title: "周次边界", weekday: 1, startSection: 1, endSection: 1, weeksText: "1"),
            to: [], term: "2026-2027-1", id: "boundary"
        ).first)
        let course = original.replacingWeeks([Int.min, -54, -53, -1, 0, 1, 53, 54, Int.max])
        let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
            courses: [course], firstDay: shanghaiDate(2026, 9, 7), timeTable: TimeSlot.default
        )
        #expect(drafts.map(\.markerID) == ["boundary-w-53", "boundary-w-1", "boundary-w1", "boundary-w53"])
        #expect(drafts.map { ScheduleDateCodec.formatDate($0.startDate) } == [
            "2025-09-01", "2026-08-31", "2026-09-07", "2027-09-06"
        ])
    }

    @Test("Course weeks expand into exact class dates and timetable bounds")
    func expandsCourseOccurrences() throws {
        let course = CourseRecord(
            id: "course-a",
            term: "2026-2027-1",
            name: "软件工程导论",
            teacher: "测试教师",
            classroom: "综教A101",
            description: "课程说明",
            weeks: [-1, 1, 3],
            weekday: 3,
            startSection: 3,
            endSection: 4,
            campus: "良乡校区",
            number: "CS101",
            credit: 2,
            hour: 32,
            type: "",
            category: "",
            department: ""
        )

        let drafts = ScheduleSystemCalendarEventBuilder.makeDrafts(
            courses: [course],
            firstDay: shanghaiDate(2026, 9, 7),
            timeTable: TimeSlot.default
        )

        let selectedContent = ScheduleSystemCalendarContent.courses(
            [course], firstDay: shanghaiDate(2026, 9, 7), timeTable: TimeSlot.default, week: 1
        )
        #expect(try ScheduleSystemCalendarEventBuilder.makeDrafts(for: selectedContent).map(\.markerID) == ["course-a-w1"])
        let previousWeekContent = ScheduleSystemCalendarContent.courses(
            [course], firstDay: shanghaiDate(2026, 9, 7), timeTable: TimeSlot.default, week: -1
        )
        #expect(try ScheduleSystemCalendarEventBuilder.makeDrafts(for: previousWeekContent).map(\.markerID) == ["course-a-w-1"])
        let wholeCourseContent = ScheduleSystemCalendarContent.courses(
            [course], firstDay: shanghaiDate(2026, 9, 7), timeTable: TimeSlot.default
        )
        #expect(try ScheduleSystemCalendarEventBuilder.makeDrafts(for: wholeCourseContent) == drafts)
        #expect(drafts.count == 3)
        #expect(ScheduleDateCodec.formatDate(drafts[0].startDate) == "2026-09-02")
        #expect(ScheduleDateCodec.formatDate(drafts[1].startDate) == "2026-09-09")
        #expect(ScheduleDateCodec.formatDate(drafts[2].startDate) == "2026-09-23")
        let startComponents = ScheduleSharedDateCodec.calendar.dateComponents([.hour, .minute], from: drafts[1].startDate)
        let endComponents = ScheduleSharedDateCodec.calendar.dateComponents([.hour, .minute], from: drafts[1].endDate)
        #expect(startComponents.hour == 9 && startComponents.minute == 55)
        #expect(endComponents.hour == 11 && endComponents.minute == 30)
        #expect(drafts[1].location == "良乡校区 · 综教A101")
        #expect(drafts[1].structuredLocation?.title == "北京理工大学 · 良乡校区 · 综教A")
        #expect(drafts[1].structuredLocation?.latitude == 39.733193)
        #expect(drafts[1].structuredLocation?.longitude == 116.170654)
        let event = EKEvent(eventStore: EKEventStore())
        event.structuredLocation = drafts[1].calendarLocation
        #expect(event.location == "良乡校区 · 综教A101")
        #expect(event.structuredLocation?.geoLocation?.coordinate.latitude == 39.733193)
        #expect(event.structuredLocation?.geoLocation?.coordinate.longitude == 116.170654)
        #expect(drafts[1].notes.contains("教师：测试教师"))
    }

    @Test("Structured calendar locations distinguish the Zhongguancun campus")
    func structuredLocationUsesCampusAndBuilding() {
        let course = CourseRecord(
            id: "course-zhongguancun",
            term: "2026-2027-1",
            name: "测试课",
            teacher: "",
            classroom: "中关村校区主楼133",
            description: "",
            weeks: [1],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "中关村校区",
            number: "",
            credit: 0,
            hour: 0,
            type: "",
            category: "",
            department: ""
        )

        let draft = ScheduleSystemCalendarEventBuilder.makeDrafts(
            courses: [course],
            firstDay: shanghaiDate(2026, 9, 7),
            timeTable: TimeSlot.default
        ).first

        #expect(draft?.location == "中关村校区主楼133")
        #expect(draft?.structuredLocation?.title == "北京理工大学 · 中关村校区 · 主楼")
        #expect(draft?.structuredLocation?.latitude == 39.9597)
        #expect(draft?.structuredLocation?.longitude == 116.321642)
        let event = EKEvent(eventStore: EKEventStore())
        event.structuredLocation = draft?.calendarLocation
        #expect(event.location == "中关村校区主楼133")
        #expect(event.structuredLocation?.geoLocation?.coordinate.latitude == 39.9597)
        #expect(event.structuredLocation?.geoLocation?.coordinate.longitude == 116.321642)
    }

    @Test func calendarLocationKeepsUnmappedTextWithoutAssigningCoordinates() {
        let draft = ScheduleSystemCalendarEventDraft(markerID: "custom", title: "组会", location: "体育馆",
            structuredLocation: nil, notes: "", startDate: Date(), endDate: Date().addingTimeInterval(3_600))
        let event = EKEvent(eventStore: EKEventStore())
        event.structuredLocation = draft.calendarLocation
        #expect(event.location == "体育馆")
        #expect(event.structuredLocation?.geoLocation == nil)
    }

    @Test("Exam and custom schedule records share calendar event drafts")
    func buildsExamAndCustomDrafts() throws {
        let exam = ExamRecord(
            id: "exam-1",
            term: "2026-2027-1",
            name: "软件工程导论",
            courseID: "CS101",
            teacher: "测试教师",
            classroom: "综教A101",
            dateString: "2026-09-08",
            beginTime: "10:00",
            endTime: "11:30",
            examMode: "闭卷",
            seatID: "A12"
        )
        let custom = CustomScheduleRecord(
            id: "custom-1",
            title: "实验室组会",
            subtitle: "综教A201",
            description: "准备周报",
            dateString: "2026-09-09",
            beginTime: "14:00",
            endTime: "16:00"
        )

        let examDraft = ScheduleSystemCalendarEventBuilder.makeDraft(for: exam)
        let customDraft = ScheduleSystemCalendarEventBuilder.makeDraft(for: custom)
        #expect(try ScheduleSystemCalendarEventBuilder.makeDrafts(for: .exam(exam)) == [examDraft].compactMap { $0 })
        #expect(try ScheduleSystemCalendarEventBuilder.makeDrafts(for: .customSchedule(custom)) == [customDraft].compactMap { $0 })


        #expect(examDraft?.markerID == "exam-exam-1")
        #expect(examDraft?.title == "[考试] 软件工程导论")
        #expect(examDraft?.location == "综教A101")
        #expect(examDraft?.notes.contains("座位号：A12") == true)
        #expect(customDraft?.markerID == "custom-custom-1-2026-09-09")
        #expect(customDraft?.title == "实验室组会")
        #expect(customDraft?.location == "综教A201")
        #expect(customDraft?.notes == "准备周报")
    }

    @Test func recurringCustomSchedulesExportEveryDateWithStableCalendarMarkers() throws {
        let schedule = CustomScheduleRecord(id: "weekly", title: "组会", subtitle: "地点", description: "描述",
            dateString: "2026-09-09", beginTime: "12:10", endTime: "12:40",
            additionalDateStrings: ["2026-09-16", "2026-09-23", "2026-09-16"])
        let drafts = try ScheduleSystemCalendarEventBuilder.makeDrafts(for: .customSchedule(schedule))
        #expect(drafts.map(\.markerID) == ["custom-weekly-2026-09-09", "custom-weekly-2026-09-16", "custom-weekly-2026-09-23"])
        #expect(drafts.map { ScheduleDateCodec.formatDate($0.startDate) } == schedule.occurrenceDateStrings)
        #expect(drafts.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 1_800 })
        var edited = schedule
        edited.dateString = "2026-09-16"
        edited.additionalDateStrings = ["2026-09-23"]
        let current = try ScheduleSystemCalendarEventBuilder.makeDrafts(for: .customSchedule(edited))
        #expect(current.map(\.markerID) == Array(drafts.dropFirst()).map(\.markerID))
        let selection = ScheduleSystemCalendarEventMarker.Selection(Set(current.map(\.markerID)))
        #expect(drafts.allSatisfy { selection.contains($0.markerID) })
        #expect(selection.contains("custom-weekly"))
        #expect(!selection.contains("custom-other-2026-09-16") && !selection.contains("course-w4"))
    }

    @Test("Courses with missing timetable sections are skipped")
    func skipsInvalidTimetableBounds() {
        let course = CourseRecord(
            id: "course-b",
            term: "2026-2027-1",
            name: "测试课",
            teacher: "",
            classroom: "",
            description: "",
            weeks: [1],
            weekday: 1,
            startSection: 99,
            endSection: 100,
            campus: "",
            number: "",
            credit: 0,
            hour: 0,
            type: "",
            category: "",
            department: ""
        )

        #expect(ScheduleSystemCalendarEventBuilder.makeDrafts(
            courses: [course],
            firstDay: shanghaiDate(2026, 9, 7),
            timeTable: TimeSlot.default
        ).isEmpty)
    }

    @Test("Numeric course numbers are not detected as phone numbers")
    func preventsCourseNumberPhoneDetection() throws {
        let rawNumber = "10001234567"
        let protectedNumber = ScheduleSystemCalendarEventBuilder.dataDetectorSafeCourseNumber(rawNumber)
        #expect(protectedNumber.replacingOccurrences(of: "\u{2060}", with: "") == rawNumber)

        let notes = "课程编号：\(protectedNumber)"
        let detector = try NSDataDetector(
            types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        )
        #expect(detector.matches(
            in: notes,
            range: NSRange(notes.startIndex..., in: notes)
        ).isEmpty)
    }
}

@Suite("Schedule calendar layer ordering")
struct ScheduleCalendarLayerOrderingTests {
    @Test func quantizedAxisRetainsOffHoursAndShortEventsInItsOutsideGroup() {
        let entries = [("course", CGFloat(0), CGFloat(2), ScheduleCalendarKind.course),
            ("lunch", 4, 4, .exam), ("evening", 12, 12, .custom), ("short", 2, 2.01, .custom)].map {
            ScheduleCalendarEntry(id: $0.0, sourceID: $0.0, sourceIDs: [$0.0], dayOfWeek: 1,
                startSection: $0.1, endSection: $0.2, startMinutes: 720, endMinutes: 730,
                title: $0.0, subtitle: "", detailLines: ["原始时间"], kind: $0.3)
        }
        let groups = quantizedCalendarGroups(entries: entries)
        #expect(groups.grid.map(\.id) == ["course"])
        #expect(groups.outside.map(\.id) == ["lunch", "evening", "short"])
        #expect(Set((groups.grid + groups.outside).map(\.id)) == Set(entries.map(\.id)))
        #expect(groups.outside.allSatisfy { $0.startMinutes == 720 && $0.endMinutes == 730 })
    }

    @Test func weeklyConflictsPreserveEveryKindAndItsOriginalCoordinates() {
        func entry(_ id: String, _ kind: ScheduleCalendarKind, _ start: CGFloat, _ end: CGFloat, day: Int = 1) -> ScheduleCalendarEntry {
            ScheduleCalendarEntry(id: id, sourceID: id, sourceIDs: [id], dayOfWeek: day,
                startSection: start, endSection: end, startMinutes: 480, endMinutes: 600,
                title: id, subtitle: "地点", detailLines: ["详情"], kind: kind)
        }
        let entries = [entry("course", .course, 0, 3), entry("exam", .exam, 1, 2),
            entry("custom", .custom, 1.5, 2.5), entry("partial", .course, 2, 4),
            entry("next", .course, 4, 5), entry("other-day", .exam, 1, 2, day: 2)]
        let placements = calendarPlacements(entries: entries.reversed())
        #expect(Set(placements.map(\.id)) == Set(entries.map(\.id)))
        for placement in placements {
            let original = entries.first { $0.id == placement.id }
            #expect(placement.entry.startSection == original?.startSection)
            #expect(placement.entry.endSection == original?.endSection)
            #expect(placement.entry.resolvedSourceIDs == original?.resolvedSourceIDs)
            #expect(placement.entry.detailLines == original?.detailLines)
        }
        #expect(placements.prefix(4).allSatisfy { $0.columnCount == 3 })
        #expect(placements.first { $0.id == "next" }?.columnCount == 1)
        #expect(placements.first { $0.id == "other-day" }?.columnCount == 1)
        for lhs in placements {
            for rhs in placements where lhs.id != rhs.id && lhs.entry.dayOfWeek == rhs.entry.dayOfWeek
                && lhs.entry.startSection < rhs.entry.endSection && rhs.entry.startSection < lhs.entry.endSection {
                #expect(lhs.column != rhs.column)
            }
        }
        #expect(calendarPlacements(entries: entries).map(\.id) == placements.map(\.id))
        #expect(calendarPlacements(entries: entries, separateOverlaps: false).allSatisfy { $0.columnCount == 1 })
    }

    @Test("Earlier course center is rendered above later course center")
    func earlierCenterIsOnTop() {
        let entry = ScheduleCalendarEntry(
            id: "overlap",
            sourceID: "first",
            sourceIDs: ["first", "second"],
            dayOfWeek: 1,
            startSection: 0,
            endSection: 5,
            title: "重叠课程",
            subtitle: "",
            detailLines: [],
            kind: .course,
            backgroundLayers: [
                ScheduleCalendarLayer(id: "first", startSection: 0, endSection: 3),
                ScheduleCalendarLayer(id: "second", startSection: 2, endSection: 5)
            ]
        )

        #expect(entry.orderedBackgroundLayers.map(\.id) == ["second", "first"])
        #expect(
            (entry.orderedBackgroundLayers.last?.displayZIndex ?? 0)
                > (entry.orderedBackgroundLayers.first?.displayZIndex ?? 0)
        )
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

    @Test("Pre-start week outliers do not disable the common offset")
    func ignoresPreStartOutliers() {
        let courses = [
            makeCourse(id: "a", description: "1-5周 星期一", weeks: Array(4 ... 8)),
            makeCourse(id: "b", description: "7-12周 星期二", weeks: Array(10 ... 15)),
            makeCourse(id: "c", description: "-2周 星期三,-1周 星期四", weeks: [1, 2])
        ]
        let result = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-1",
            firstDayString: "2026-08-31",
            courses: courses
        )

        #expect(result.offset == 3)
        #expect(result.firstDayString == "2026-09-21")
        #expect(result.courses[0].weeks == Array(1 ... 5))
        #expect(result.courses[2].weeks == [-2, -1])
    }

    @Test("Offsets other than three weeks leave every course unchanged")
    func rejectsNonThreeWeekOffset() {
        let courses = [
            makeCourse(id: "a", description: "1-5周 星期一", weeks: Array(3 ... 7)),
            makeCourse(id: "b", description: "7-12周 星期二", weeks: Array(9 ... 14))
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

@Suite("Course row schedule parsing")
struct CourseScheduleRowParserTests {
    @Test(arguments: [
        ("1-16周(单)", [1, 3, 5, 7, 9, 11, 13, 15]),
        ("1-16周（双）", [2, 4, 6, 8, 10, 12, 14, 16]),
        ("1-16(单周)", [1, 3, 5, 7, 9, 11, 13, 15]),
        ("1-16（双）周", [2, 4, 6, 8, 10, 12, 14, 16]),
        ("1-16周 双周", [2, 4, 6, 8, 10, 12, 14, 16]),
        ("1-8周(单),10-16周(双)", [1, 3, 5, 7, 10, 12, 14, 16])
    ])
    func schoolRowsAndDescriptionsPreserveOddAndEvenWeeks(fixture: (String, [Int])) throws {
        let (text, expected) = fixture
        let row: [String: Any] = ["XNXQDM": "term", "KCM": "单双周课程", "KCH": "parity",
            "JASMC": "文萃楼M227", "SKXQ": 4, "KSJC": 6, "JSJC": 9,
            "SKZC": String(repeating: "1", count: 16), "ZCMC": text, "YPSJDD": text + " 星期四 6-9节 文萃楼M227"]
        let data = try JSONSerialization.data(withJSONObject: ["datas": ["cxxszhxqkb": ["rows": [row]]]])
        let course = try #require(JSONDecoder().decode(CourseResponse.self, from: data).courseRecords.first)
        #expect(course.weeks == expected)
        let stale = course.replacingWeeks(Array(1...16))
        #expect(CourseScheduleRowParser.narrowedCourses([stale]).first?.weeks == expected)
        #expect(SmallTermWeekNormalizer.weeksDescribed(in: text) == Set(expected))
    }

    @Test(arguments: [false, true])
    func sparseSchoolFlagsAndCachedParityRulesRemainIntact(even: Bool) throws {
        let expected = Array(1...16).filter { $0.isMultiple(of: 2) == even }
        let row: [String: Any] = ["XNXQDM": "term", "KCM": "单双周课程", "KCH": "parity",
            "JASMC": "文萃楼M227", "SKXQ": 4, "KSJC": 6, "JSJC": 9,
            "SKZC": (1...16).map { expected.contains($0) ? "1" : "0" }.joined(), "ZCMC": "1-16周",
            "YPSJDD": "1-16周(\(even ? "双" : "单")) 星期四 6-9节 文萃楼M227"]
        let data = try JSONSerialization.data(withJSONObject: ["datas": ["cxxszhxqkb": ["rows": [row]]]])
        let course = try #require(JSONDecoder().decode(CourseResponse.self, from: data).courseRecords.first)
        #expect(course.weeks == expected)
        let stale = course.replacingWeeks(Array(1...16))
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: [stale], exams: [], updatedAt: .distantPast))
        let replacement = try ScheduleCourseEditor.updatingArrangements([(stale.id, CourseDraft(title: "手动调课", weekday: 2, startSection: 6, endSection: 9, weeksText: even ? "2,4" : "1,3"))], in: [stale])
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: [stale], currentCourses: replacement)
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.courseData.schoolCourses(for: "term").first?.weeks == expected)
        #expect(restored.courses == replacement)
        #expect(restored.manualCourseRulesByTerm["term"]?.first?.sourceCourses.first?.weeks == expected)
        #expect(try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(restored)).courseData == restored.courseData)
    }

    @Test("School row weeks and identities come from ZCMC")
    func decodesRowSpecificWeeksFromCourseResponse() throws {
        let data = Data("""
        {
            "datas": {
                "cxxszhxqkb": {
                    "rows": [
                        {
                            "XNXQDM": "2026-2027-1",
                            "KCM": "文献检索",
                            "KCH": "100960001",
                            "JASMC": "文萃楼M227",
                            "SKXQ": 4,
                            "KSJC": 6,
                            "JSJC": 9,
                            "SKZC": "001000000000000000000",
                            "ZCMC": "-1周",
                            "YPSJDD": "-2周 星期四 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227"
                        },
                        {
                            "XNXQDM": "2026-2027-1",
                            "KCM": "文献检索",
                            "KCH": "100960001",
                            "JASMC": "文萃楼M227",
                            "SKXQ": 4,
                            "KSJC": 6,
                            "JSJC": 9,
                            "SKZC": "010000000000000000000",
                            "ZCMC": "-2周",
                            "YPSJDD": "-2周 星期四 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227"
                        }
                    ]
                }
            }
        }
        """.utf8)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        let courses = response.courseRecords

        #expect(courses.map(\.weeks) == [[-1], [-2]])
        #expect(Set(courses.map(\.id)).count == 2)

        let evidenceCourses = courses + [
            makeCourse(
                id: "evidence-a",
                description: "1-2周 星期一",
                weeks: [1, 2],
                weekday: 1
            ),
            makeCourse(
                id: "evidence-b",
                description: "1-2周 星期二",
                weeks: [1, 2],
                weekday: 2
            )
        ]
        let normalized = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-1",
            firstDayString: "2026-08-31",
            courses: evidenceCourses,
            rawWeeksByCourse: [[-1], [-2], [4, 5], [4, 5]]
        )

        #expect(normalized.offset == 3)
        #expect(normalized.firstDayString == "2026-09-21")
        #expect(normalized.courses.prefix(2).map(\.weeks) == [[-1], [-2]])
    }

    @Test("Aggregated descriptions keep only the row's matching weeks")
    func narrowsWeeksToMatchingRow() {
        let description = "-2周 星期四 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227,-1周 星期二 6-9节 文萃楼M227,-1周 星期五 6-9节 文萃楼M227"
        let courses = [
            makeCourse(id: "tue", description: description, weeks: [-2, -1], weekday: 2),
            makeCourse(id: "thu", description: description, weeks: [-2, -1], weekday: 4),
            makeCourse(id: "fri", description: description, weeks: [-2, -1], weekday: 5),
        ]

        let narrowed = CourseScheduleRowParser.narrowedCourses(courses)

        #expect(narrowed[0].weeks == [-1])
        #expect(narrowed[1].weeks == [-2, -1])
        #expect(narrowed[2].weeks == [-1])
    }

    @Test("Negative week description wins over shifted raw flag")
    func restoresNegativeWeekFromDescription() {
        let course = makeCourse(
            id: "negative",
            description: "-2周 星期三 6-9节 文萃楼M227",
            weeks: [-1],
            weekday: 3
        )

        let narrowed = CourseScheduleRowParser.narrowedCourses([course])

        #expect(narrowed[0].weeks == [-2])
    }

    private func makeCourse(
        id: String,
        description: String,
        weeks: [Int],
        weekday: Int
    ) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: "文献检索",
            teacher: "",
            classroom: "文萃楼M227",
            description: description,
            weeks: weeks,
            weekday: weekday,
            startSection: 6,
            endSection: 9,
            campus: "",
            number: "100960001",
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
        #expect(ScheduleWeekCodec.formatWeeks([6, 2, 1, 5, 2, 3]) == "1-3,5-6")
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

    @Test("Editing one occurrence preserves the remaining weeks")
    func editsOneOccurrence() throws {
        let original = makeCourse(id: "original", weeks: [1, 2], weekday: 1)
        let draft = CourseDraft(
            title: "调整后的课程",
            weekday: 3,
            startSection: 5,
            endSection: 6,
            weeksText: "ignored"
        )

        let courses = try ScheduleCourseEditor.updatingOccurrence(
            id: original.id,
            week: 1,
            with: draft,
            in: [original],
            adjustedID: "adjusted"
        )

        #expect(courses.count == 2)
        #expect(courses.first(where: { $0.id == "original" })?.weeks == [2])
        let adjusted = courses.first(where: { $0.id == "adjusted" })
        #expect(adjusted?.weeks == [1])
        #expect(adjusted?.weekday == 3)
        #expect(adjusted?.name == "调整后的课程")
    }

    @Test("Transferring a day clears target occurrences without deleting other weeks")
    func transfersOneDay() throws {
        let source = makeCourse(id: "source", weeks: [1, 2], weekday: 1)
        let target = makeCourse(id: "target", weeks: [1, 3], weekday: 2)

        let courses = try ScheduleCourseEditor.transferring(
            courses: [source, target],
            fromWeek: 1,
            fromWeekday: 1,
            toWeek: 1,
            toWeekday: 2,
            makeID: { "moved" }
        )

        #expect(courses.first(where: { $0.id == "source" })?.weeks == [2])
        #expect(courses.first(where: { $0.id == "target" })?.weeks == [3])
        let moved = courses.first(where: { $0.id == "moved" })
        #expect(moved?.weeks == [1])
        #expect(moved?.weekday == 2)
    }

    private func makeCourse(id: String, weeks: [Int], weekday: Int) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: id,
            teacher: "教师",
            classroom: "教室",
            description: "说明",
            weeks: weeks,
            weekday: weekday,
            startSection: 1,
            endSection: 2,
            campus: "良乡",
            number: "100001",
            credit: 1,
            hour: 16,
            type: "必修",
            category: "专业课",
            department: "学院"
        )
    }
}

@Suite("Schedule DDL editing")
struct ScheduleDDLEditorTests {
    @Test("Manual events survive Lexue synchronization and remain sorted")
    func mergesSyncedEvents() {
        let later = Date(timeIntervalSince1970: 200)
        let earlier = Date(timeIntervalSince1970: 100)
        let manual = DDLEventRecord(
            id: "manual",
            group: "main",
            title: "手动",
            text: "",
            dueAt: later,
            done: false
        )
        let staleLexue = DDLEventRecord(
            id: "stale",
            group: "lexue",
            title: "旧乐学",
            text: "",
            dueAt: later,
            done: false
        )
        let synced = DDLEventRecord(
            id: "synced",
            group: "lexue",
            title: "新乐学",
            text: "",
            dueAt: earlier,
            done: true
        )

        let result = ScheduleDDLEditor.mergingSyncedEvents(
            [synced],
            into: [manual, staleLexue]
        )

        #expect(result.map(\.id) == ["synced", "manual"])
    }

    @Test("Manual drafts are trimmed and empty titles are rejected")
    func validatesManualDrafts() throws {
        let dueAt = Date(timeIntervalSince1970: 100)
        let result = try ScheduleDDLEditor.adding(
            DDLDraft(title: "  作业  ", dueAt: dueAt, text: "说明"),
            to: [],
            id: "new"
        )
        #expect(result.first?.title == "作业")
        #expect(result.first?.id == "new")
        #expect(throws: Error.self) {
            try ScheduleDDLEditor.adding(DDLDraft(title: "   "), to: [])
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
        let courses = [CourseRecord(
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

        cache.courseData.store(TermScheduleSnapshot(term: cache.currentTerm, firstDayString: "2026-03-02",
            courses: courses, exams: [], updatedAt: .distantPast))
        let code = try ScheduleShareCodeCodec.encodeLatest(cache: cache)
        let decoded = try ScheduleShareCodeCodec.decode(code, using: cache)
        let coursesCode = try ScheduleShareCodeCodec.encodeLatest(courses: cache.courses)
        let coursesDecoded = try ScheduleShareCodeCodec.decode(coursesCode, using: cache)

        #expect(code.hasPrefix("BIT101SCH3:"))
        #expect(coursesCode.hasPrefix("BIT101SCH3:"))
        #expect(decoded.courses.count == 1)
        #expect(coursesDecoded.courses.count == 1)
        #expect(decoded.courses[0].name == "编译原理")
        #expect(decoded.courses[0].credit == 4)
        #expect(decoded.exportedAt == nil)
    }

    @Test("V4 decodes export time to minute precision while exports remain V3")
    func v4ShareTimeRoundTrip() throws {
        let cache = ScheduleCache()
        let sourceTime = Date(timeIntervalSince1970: 1_777_777_777)
        let payload = ScheduleExportCompactPayloadV4(cache: cache, exportedAt: sourceTime)
        let expectedTime = Date(timeIntervalSince1970: 1_777_777_740)
        #expect(payload.exportedAt == expectedTime)

        let jsonData = try JSONEncoder().encode(payload)
        guard let compressedData = try (jsonData as NSData).compressed(using: .lzfse) as Data? else {
            throw ScheduleShareCodeError.compressionFailed
        }
        let code = "BIT101SCH4:\(compressedData.base64EncodedString())"
        let decoded = try ScheduleShareCodeCodec.decode(code, using: cache)
        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let record = SharedScheduleRecord(
            title: "测试课表",
            importedAt: importedAt,
            payload: decoded
        )

        #expect(decoded.exportedAt == expectedTime)
        #expect(record.sharedAt == expectedTime)
        #expect(record.importedAt == importedAt)
        #expect(ScheduleShareCodeCodec.latestExportVersion == 3)
    }

    @Test("Older imported schedules keep a missing share time optional")
    func decodesLegacySharedSchedule() throws {
        let json = """
        {"id":"legacy","title":"旧课表","importedAt":0,"currentTerm":"2025-2026-2","firstDayString":"2026-03-02","timeTable":[],"courses":[]}
        """
        let record = try JSONDecoder().decode(SharedScheduleRecord.self, from: Data(json.utf8))
        #expect(record.sharedAt == nil)
    }

    @Test("A newer share format requests an app update")
    func unsupportedNewerFormat() {
        #expect(throws: ScheduleShareCodeError.unsupportedNewerFormat(5)) {
            _ = try ScheduleShareCodeCodec.decode("BIT101SCH5:anything", using: ScheduleCache())
        }
    }
}
