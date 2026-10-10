import Foundation
import ScheduleContracts
import ScheduleActivityContracts
import ScheduleSharedStore
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
@Suite("Watch and Widget shared runtime contracts")
struct ExternalScheduleInfrastructureTests {
    @MainActor @Test func damagedDiskSnapshotsReachTheInvalidDisplayState() throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: URL(fileURLWithPath: "/external-display"))
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .missing)
        let missing = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, includeDisplayUntilDates: true)
        #expect(missing.count == 1 && missing.first?.resolved.contentState == .missing)
        try files.writeData(Data("invalid-json".utf8), to: #require(store.fileURL), options: [])
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let invalid = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, includeDisplayUntilDates: true)
        #expect(invalid.count == 1 && invalid.first?.resolved.contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: ScheduleExternalSnapshotStore(files: files, containerURL: nil)).contentState == .unavailable)
        let unavailable = ScheduleOccurrenceResolver.loadResolvedTimeline(store: ScheduleExternalSnapshotStore(files: files, containerURL: nil), includeDisplayUntilDates: false)
        #expect(unavailable.count == 1 && unavailable.first?.resolved.contentState == .unavailable)
    }
    #if !targetEnvironment(macCatalyst)
    @Test("Live Activity preserves account and course presentation across encoding")
    func liveActivityContractRoundTrip() throws {
        let attributes = CourseReminderActivityAttributes(studentID: "activity-account")
        let state = CourseReminderActivityAttributes.ContentState(
            kindText: "课程", title: "高等数学", classroom: "理教201", teacher: "张老师",
            timeRangeText: "08:00–09:30", countdownTargetDate: Date(timeIntervalSince1970: 1_000))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(CourseReminderActivityAttributes.self,
            from: encoder.encode(attributes)).studentID == "activity-account")
        #expect(try decoder.decode(CourseReminderActivityAttributes.ContentState.self,
            from: encoder.encode(state)) == state)
    }
    #endif

    @Test("Snapshot codec preserves the shared contract")
    func snapshotCodecRoundTrip() throws {
        let snapshot = makeSnapshot()
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)

        #expect(try ScheduleExternalSnapshotCodec.decode(data) == snapshot)
    }

    @Test("Watch transfer protocol recognizes requests and snapshots")
    func watchTransferProtocol() throws {
        let data = try ScheduleExternalSnapshotCodec.encode(makeSnapshot())
        let context = WatchScheduleTransferProtocol.snapshotContext(data)

        #expect(WatchScheduleTransferProtocol.knownRevision(from: WatchScheduleTransferProtocol.requestContext(knownRevision: 42)) == 42)
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext()))
        #expect(WatchScheduleTransferProtocol.snapshotData(from: context) == data)
        #expect(!WatchScheduleTransferProtocol.requestsLatestSnapshot(context))
    }

    @Test("Resolved snapshot states distinguish missing login invalid empty rest and ready")
    func resolvedSnapshotStates() throws {
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate("2026-03-02"))
        let beforeClass = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let afterClass = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "10:00"))

        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: beforeClass).contentState == .missing)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(isLoggedIn: false),
            now: beforeClass
        ).contentState == .loggedOut)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(firstDayString: "invalid-date"),
            now: beforeClass
        ).contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(includeCourses: false, includeTimeTable: false),
            now: beforeClass
        ).contentState == .rest)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(includeTimeTable: false),
            now: beforeClass
        ).contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(),
            now: afterClass
        ).contentState == .rest)

        let ready = ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(),
            now: beforeClass,
            limit: 1
        )
        #expect(ready.contentState == .ready)
        #expect(ready.upcomingOccurrences.count == 1)
        #expect(ready.nextOccurrence?.title == "高等数学")
    }

    @Test("Timeline planner selects course transitions and midnight")
    func timelineRefreshPlanning() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-03-02"))
        let start = try #require(ScheduleSharedDateCodec.combine(date: day, time: "08:00"))
        let displayUntil = start.addingTimeInterval(5 * 60)
        let occurrence = ScheduleExternalOccurrence(
            id: "course-1",
            title: "高等数学",
            classroom: "理教201",
            teacher: "张老师",
            startDate: start,
            endDate: start.addingTimeInterval(90 * 60),
            displayUntilDate: displayUntil
        )

        let beforeClass = start.addingTimeInterval(-60 * 60)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [occurrence],
            now: beforeClass,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        ) == start)

        for leadTime: TimeInterval in [1, 10, 29, 30] {
            #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: start.addingTimeInterval(-leadTime),
                includeDisplayUntilDates: false, includeNextMidnight: true) == start)
        }
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: displayUntil.addingTimeInterval(-10),
            includeDisplayUntilDates: true, includeNextMidnight: false) == displayUntil)
        let duringDisplayWindow = start.addingTimeInterval(60)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [occurrence],
            now: duringDisplayWindow,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        ) == displayUntil)

        let lateEvening = try #require(ScheduleSharedDateCodec.combine(date: day, time: "23:50"))
        let nextMidnight = ScheduleSharedDateCodec.calendar.date(
            byAdding: .day,
            value: 1,
            to: ScheduleSharedDateCodec.calendar.startOfDay(for: lateEvening)
        )?.addingTimeInterval(1)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [],
            now: lateEvening,
            includeDisplayUntilDates: false,
            includeNextMidnight: true
        ) == nextMidnight)
        let midnight = try #require(nextMidnight)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [], now: midnight.addingTimeInterval(-10),
            includeDisplayUntilDates: false, includeNextMidnight: true) == midnight)
    }

    @Test(arguments: [true, false])
    func futureTimelineIncludesClassTransitionsAndMidnight(phone: Bool) throws {
        let base = makeSnapshot()
        let course = try #require(base.courses.first)
        let snapshot = ScheduleExternalSnapshot(generatedAt: base.generatedAt, isLoggedIn: base.isLoggedIn,
            studentID: base.studentID, firstDayString: base.firstDayString, timeTable: base.timeTable,
            courses: [ScheduleExternalCourseSnapshot(id: course.id, name: course.name, classroom: course.classroom,
                teacher: course.teacher, weeks: [1, 2], weekday: course.weekday,
                startSection: course.startSection, endSection: course.endSection)])
        let day = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        let occurrence = try #require(resolved.nextOccurrence)
        let cutoff = occurrence.startDate.addingTimeInterval(ScheduleOccurrenceResolver.defaultCurrentCourseDisplayDuration)
        let midnight = try #require(ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: day))
        let dates = ScheduleTimelineRefreshPlanner.timelineDates(for: resolved.upcomingOccurrences + resolved.upcomingOccurrences,
            now: now, includeDisplayUntilDates: phone)
        #expect(dates == dates.sorted() && Set(dates).count == dates.count)
        #expect(dates.first == now && dates.last == now.addingTimeInterval(24 * 60 * 60))
        #expect(dates.contains(occurrence.startDate) && dates.contains(midnight))
        #expect(dates.contains(cutoff) == phone)
        #expect(dates.contains(occurrence.endDate) == phone)
        let store = ScheduleExternalSnapshotStore(files: PreferenceMemoryFiles(), containerURL: URL(fileURLWithPath: "/timeline-contract"))
        try store.write(snapshot)
        let timeline = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, now: now, includeDisplayUntilDates: phone, limit: 1)
        #expect(timeline.map(\.date) == dates)
        for entry in timeline {
            let reference = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: entry.date, limit: 1)
            #expect(entry.resolved.contentState == reference.contentState)
            #expect(entry.resolved.upcomingOccurrences == reference.upcomingOccurrences)
        }
        let last = try #require(resolved.upcomingOccurrences.last)
        #expect(last.displayUntilDate == last.endDate)
        #expect(!dates.contains(last.startDate))
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: occurrence.startDate).nextOccurrence?.id == occurrence.id)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: cutoff).nextOccurrence?.id != occurrence.id)
        let empty = ScheduleTimelineRefreshPlanner.timelineDates(for: [], now: now, includeDisplayUntilDates: phone)
        #expect(empty == [now, midnight, now.addingTimeInterval(24 * 60 * 60)])
    }

    private func makeSnapshot(
        isLoggedIn: Bool = true,
        includeCourses: Bool = true,
        firstDayString: String = "2026-03-02",
        includeTimeTable: Bool = true
    ) -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_772_422_400),
            isLoggedIn: isLoggedIn,
            studentID: "1120260001",
            firstDayString: firstDayString,
            timeTable: includeTimeTable ? [
                ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "09:30"),
            ] : [],
            courses: includeCourses ? [
                ScheduleExternalCourseSnapshot(
                    id: "course-1",
                    name: "高等数学",
                    classroom: "理科教学楼201",
                    teacher: "张老师",
                    weeks: [1],
                    weekday: 1,
                    startSection: 1,
                    endSection: 1
                ),
            ] : []
        )
    }
}
