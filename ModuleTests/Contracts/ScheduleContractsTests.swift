import BIT101TestSupport
import StorageCore
import Foundation
import ScheduleContracts
import ScheduleSharedStore
import ScheduleDomain
import Testing

struct ScheduleContractsTests {
    @Test(.timeLimit(.minutes(1))) func maximumSharePayloadRoundTripsThroughConcurrentCodec() async throws {
        let weeks = Array(1...20)
        let courses = (0..<ScheduleShareCodeCodec.maximumCourseCount).map { index in
            sharedCourse(weeks: weeks, name: "容量课程\(index)")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let code = try await ScheduleShareCodeCodec.encodeForSharing(courses: courses)
        let encoded = clock.now
        let payload = try await ScheduleShareCodeCodec.decodeForImport(code, using: ScheduleCache())
        print("[性能] 分享码 \(courses.count) 门课程 · 编码 \(start.duration(to: encoded)) · 解码 \(encoded.duration(to: clock.now))")
        #expect(payload.courses.count == courses.count)
        #expect(payload.courses.map(\.name) == courses.map(\.name))
        #expect(payload.courses.map(\.weeks) == courses.map(\.weeks))
        let canceled = Task { try await ScheduleShareCodeCodec.decodeForImport(code, using: ScheduleCache()) }
        canceled.cancel()
        do {
            _ = try await canceled.value
            Issue.record("取消后的分享码仍完成导入")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func archivingSchoolSnapshotsRetainsManualCoursesAcrossReloadAndRefresh() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        let school = try ScheduleCourseEditor.adding(CourseDraft(title: "学校课程", weeksText: "1-4"),
            to: [], term: "term", id: "school")
        let snapshot = TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07", courses: school, exams: [], updatedAt: Date())
        cache.courseData.store(snapshot)
        let local = try ScheduleCourseEditor.adding(CourseDraft(title: "补录课程", weeksText: "1-4"),
            to: school, term: "term", id: "manual")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: school, currentCourses: local)
        let rules = cache.manualCourseRulesByTerm
        cache.courseData.archive(term: "term")
        cache = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(cache.manualCourseRulesByTerm == rules)
        cache.courseData.store(snapshot)
        #expect(cache.courses.contains { $0.name == "补录课程" })
    }

    @Test func guestSnapshotIdentityStaysStableAcrossStorageBoundaries() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL, notificationCenter: NotificationCenter())
        let snapshot = ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 100), isLoggedIn: false,
            studentID: AppStorageSession(accountIdentifier: "").accountStorageIdentifier, firstDayString: "", timeTable: [], courses: [])
        #expect(AccountStorageIdentity.stableToken(for: snapshot.studentID) == snapshot.studentID)
        try store.write(snapshot)
        #expect(store.load() == snapshot)
        #expect(try store.writeIfNewer(snapshot) == false)
    }

    @Test(arguments: ["title", "teacher", "classroom", "combined-classroom"])
    func manualCourseFieldsShareExternalSnapshotByteLimits(field: String) throws {
        let value = String(repeating: "课", count: ScheduleCourseConstraints.maximumFieldBytes / 3) + "x"
        #expect(value.utf8.count == ScheduleExternalSnapshotCodec.maximumFieldBytes)
        var draft = CourseDraft(title: "课程", weeksText: "1")
        switch field {
        case "title": draft.title = value
        case "teacher": draft.teacher = value
        case "classroom": draft.classroom = value
        default: draft.buildingName = String(value.dropLast()); draft.roomNumber = ""
        }
        _ = try ScheduleCourseEditor.resolve(draft)
        switch field {
        case "title": draft.title += "y"
        case "teacher": draft.teacher += "y"
        case "classroom": draft.classroom += "y"
        default: draft.roomNumber = "xy"
        }
        #expect(throws: Error.self) { try ScheduleCourseEditor.resolve(draft) }
    }

    @Test func extremeCourseFieldsAndShareExpansionAreRejectedBeforeAllocation() throws {
        for input in ["1-1000000000", String(Int.max), String(Int.min), "-1000000000-1"] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks(input) }
        }
        #expect(try ScheduleCourseEditor.parseWeeks("-2,-1,1-3") == [-2, -1, 1, 2, 3])
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(CourseDraft(title: "范围", startSection: 1, endSection: Int.max, weeksText: "1"))
        }
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: Int.max, weekday: 1, time: "08:00") == nil)
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: Int.min, weekday: 1, time: "08:00") == nil)
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: 1, weekday: Int.max, time: "08:00") == nil)
        let oversized = "BIT101SCH3:" + String(repeating: "A", count: ScheduleShareCodeCodec.maximumEncodedBytes)
        #expect(throws: ScheduleShareCodeError.invalidFormat) { try ScheduleShareCodeCodec.decode(oversized, using: ScheduleCache()) }
        let expanded = Data(repeating: 32, count: ScheduleShareCodeCodec.maximumDecodedBytes + 1)
        let compressed = try (expanded as NSData).compressed(using: .lzfse) as Data
        #expect(throws: ScheduleShareCodeError.decompressionFailed) {
            try ScheduleShareCodeCodec.decode("BIT101SCH3:" + compressed.base64EncodedString(), using: ScheduleCache())
        }
    }

    @Test func sharePayloadValidatesCourseFieldsTimeSlotsAndCapacity() throws {
        let slots = TimeSlot.default
        for (weeks, weekday, first, last) in [([Int.max], 1, 1, 1), ([1], 8, 1, 1), ([1], 1, 0, 1), ([1], 1, 1, Int.max), ([1], 1, 1, slots.count + 1)] {
            let course = sharedCourse(weeks: weeks, weekday: weekday, first: first, last: last)
            let payload = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: slots, courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try payload.validate() }
        }
        let course = sharedCourse(weeks: [-2, -1, 1])
        try ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: slots, courses: [course]).validate()
        #expect(throws: ScheduleShareCodeError.invalidFormat) {
            try ScheduleShareCodeCodec.encodeLatest(courses: Array(repeating: course, count: ScheduleShareCodeCodec.maximumCourseCount + 1))
        }
        let midnight = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: [TimeSlot(id: 1, start: "23:00", end: "24:00")], courses: [course])
        try midnight.validate()
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        for time in ["08::00", ":08:00:", "08:00:", ":08:00", "08:", ":00"] {
            #expect(ScheduleSharedDateCodec.combine(date: day, time: time) == nil)
            #expect(TimeSlot.parseMinutes(time) == 0)
            let malformed = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: [TimeSlot(id: 1, start: time, end: "09:00")], courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try malformed.validate() }
        }
    }

    @Test func externalOccurrencesRetainCoursesBeforeTheFirstWeek() throws {
        let snapshot = ScheduleExternalSnapshot(generatedAt: .distantPast, isLoggedIn: true, studentID: "negative-weeks",
            firstDayString: "2030-09-16", timeTable: [.init(id: 1, start: "08:00", end: "08:45")],
            courses: [.init(id: "negative", name: "首周前课程", classroom: "", teacher: "", weeks: [-2, -1, 1], weekday: 1, startSection: 1, endSection: 1)])
        let now = try #require(ScheduleSharedDateCodec.parseDate("2030-09-01"))
        let occurrences = ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now)
        #expect(occurrences.count == 3)
        #expect(occurrences.map { ScheduleSharedDateCodec.formatDate($0.startDate) } == ["2030-09-02", "2030-09-09", "2030-09-16"])
    }

    private func sharedCourse(weeks: [Int], weekday: Int = 1, first: Int = 1, last: Int = 1, name: String = "课程", credit: Double = 0) -> CourseRecord {
        CourseRecord(id: "share-validation", term: "", name: name, teacher: "", classroom: "", description: "", weeks: weeks,
            weekday: weekday, startSection: first, endSection: last, campus: "", number: "", credit: credit, hour: 0, type: "", category: "", department: "")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteCreditsAreRejectedByCourseAndCacheAdmission(_ credit: Double) throws {
        let course = sharedCourse(weeks: [1], credit: credit)
        #expect(!course.hasValidPlacement && course.creditText == "-")
        var cache = ScheduleCache()
        cache.courseData.schedulesByTerm["term"] = TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: [course], exams: [], updatedAt: Date())
        #expect(!cache.isValidForPersistence)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(course)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        #expect(throws: DecodingError.self) { try decoder.decode(CourseRecord.self, from: data) }
    }

    @Test @MainActor func scheduleDateDisplaysUseTheSharedSchoolTimeZone() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-10-01"))
        #expect(ScheduleDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleSharedDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleDateCodec.calendar == ScheduleSharedDateCodec.calendar)
        #expect(ScheduleDateCodec.formatCompactDate(day) == "10.1")
        #expect(ScheduleDateCodec.formatDate(day.addingTimeInterval(-1)) == "2026-09-30")
    }

    @Test func courseSnapshotTracksCourseFieldsAcrossSceneChanges() {
        var cache = ScheduleCache()
        let courses = cache.courseSnapshot
        cache.ddlBeforeDay = 3
        cache.selectedBuildingID = "module-building"
        cache.iCloudSyncEnabled = true
        #expect(cache.courseSnapshot == courses)
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-07"
        #expect(cache.courseSnapshot != courses)
        #expect(cache.courseSnapshot.firstDay == ScheduleSharedDateCodec.parseDate("2026-09-07"))
    }

    @Test func domainStorageResultsDescribeMissingReadableAndUnreadableSnapshots() {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "领域快照"
        #expect(ScheduleCacheLoadResult.missing.allowsWrite)
        #expect(ScheduleCacheLoadResult.missing.cacheIfReadable?.courses.isEmpty == true)
        #expect(ScheduleCacheLoadResult.loaded(cache).cacheIfReadable?.primaryScheduleTitle == "领域快照")
        #expect(ScheduleCacheLoadResult.unreadable.isUnreadable)
        #expect(ScheduleCacheLoadResult.unreadable.cacheIfReadable == nil)
        #expect(ScheduleCacheLoadResult.unreadable.allowsWrite == false)
    }

    @Test @MainActor func domainCourseEditingSurvivesCacheAndShareRoundTrips() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "2026-2027-1"
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-28"
        let courses = try ScheduleCourseEditor.adding(
            CourseDraft(
                title: "模块验证课程", classroom: "文萃楼I203",
                weekday: 1, startSection: 1, endSection: 2, weeksText: "1-4,6"
            ),
            to: [], term: cache.currentTerm, id: "domain-course"
        )
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: [], currentCourses: courses)
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.courses == cache.courses)
        #expect(restored.currentTerm == cache.currentTerm)
        let shared = try ScheduleShareCodeCodec.decode(
            ScheduleShareCodeCodec.encodeLatest(cache: restored), using: restored
        )
        let course = try #require(shared.courses.first)
        #expect(course.name == "模块验证课程")
        #expect(course.weeks == [1, 2, 3, 4, 6])
        #expect(course.classroom == "文萃楼I203")
        #expect(course.startSection == 1)
        #expect(course.endSection == 2)
        #expect(shared.currentTerm == cache.currentTerm)
        #expect(shared.firstDayString == cache.firstDayString)
    }

    @Test func fixedEarlierPayloadAndFutureFieldsUseTheSharedWatchCodec() throws {
        let payload = Data(#"{"isLoggedIn":true,"studentID":"fixture-account","firstDayString":"2026-09-28","timeTable":[{"id":1,"start":"08:00","end":"08:45","futureTimeField":1}],"courses":[{"id":"fixture-course","name":"固定课程","weeks":[1],"weekday":1,"startSection":1,"futureCourseField":true}],"futureSnapshotField":"value"}"#.utf8)
        let context = WatchScheduleTransferProtocol.snapshotContext(payload)
        let decoded = try ScheduleExternalSnapshotCodec.decode(#require(WatchScheduleTransferProtocol.snapshotData(from: context)))
        #expect(decoded.generatedAt == .distantPast)
        #expect(decoded.courses.first?.teacher == "")
        #expect(decoded.courses.first?.classroom == "")
        #expect(decoded.courses.first?.endSection == 1)
        #expect(decoded.timeTable.first?.start == "08:00")
        #expect(try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(decoded)) == decoded)
    }

    @Test func incompleteSchedulingIdentityHasAnExplicitDecodeFailure() {
        let payload = Data(#"{"courses":[{"id":"fixture-course","name":"课程","weeks":[1],"startSection":1}]}"#.utf8)
        #expect(throws: DecodingError.self) { try ScheduleExternalSnapshotCodec.decode(payload) }
    }

    @Test func snapshotRoundTripPreservesContract() throws {
        let snapshot = makeSnapshot()
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)
        let decoded = try ScheduleExternalSnapshotCodec.decode(data)
        #expect(decoded == snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["studentID"] as? String == snapshot.studentID)
        #expect(object["firstDayString"] as? String == "2026-09-28")
    }

    @Test func accountTokensRemainStable() {
        let token = AccountStorageIdentity.stableToken(for: "module-test-account")
        #expect(token.hasPrefix("account-"))
        #expect(AccountStorageIdentity.stableToken(for: token) == token)
        #expect(AccountStorageIdentity.stableToken(for: " module-test-account ") == token)
    }

    @Test func watchPayloadUsesSharedCodec() throws {
        let data = try ScheduleExternalSnapshotCodec.encode(makeSnapshot())
        let context = WatchScheduleTransferProtocol.snapshotContext(data)
        #expect(WatchScheduleTransferProtocol.snapshotData(from: context) == data)
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext()))
    }

    @Test func occurrenceAndRefreshBoundaries() throws {
        let snapshot = makeSnapshot()
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        #expect(resolved.contentState == .ready)
        let occurrence = try #require(resolved.nextOccurrence)
        #expect(occurrence.startDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:00"))
        #expect(occurrence.endDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:45"))
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: resolved.upcomingOccurrences,
            now: now,
            includeDisplayUntilDates: true,
            includeNextMidnight: true
        ) == occurrence.startDate)
        for leadTime: TimeInterval in [1, 10, 29, 30] {
            for displayDates in [true, false] {
                #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: occurrence.startDate.addingTimeInterval(-leadTime),
                    includeDisplayUntilDates: displayDates, includeNextMidnight: true) == occurrence.startDate)
            }
        }
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: occurrence.displayUntilDate.addingTimeInterval(-10),
            includeDisplayUntilDates: true, includeNextMidnight: false) == occurrence.displayUntilDate)
        let midnight = try #require(ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: firstDay)).addingTimeInterval(1)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [], now: midnight.addingTimeInterval(-10),
            includeDisplayUntilDates: false, includeNextMidnight: true) == midnight)
    }

    @Test func emptyAndMissingSnapshotsHaveExplicitStates() {
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: nil).contentState == .missing)
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            isLoggedIn: true,
            studentID: "account",
            firstDayString: "2026-09-28",
            timeTable: [],
            courses: []
        )
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot).contentState == .rest)
    }

    @Test(arguments: ["weekday", "section", "time", "weeks", "duplicate"])
    func invalidCourseStructureRemainsDistinctFromAnEndedTerm(problem: String) throws {
        let valid = makeSnapshot()
        let course = valid.courses[0]
        let slot = valid.timeTable[0]
        let snapshot = ScheduleExternalSnapshot(generatedAt: valid.generatedAt, revision: 10, isLoggedIn: true,
            studentID: valid.studentID, firstDayString: valid.firstDayString,
            timeTable: problem == "duplicate" ? [slot, slot] : [ScheduleExternalTimeSlotSnapshot(id: slot.id,
                start: problem == "time" ? "25:00" : slot.start, end: slot.end)],
            courses: [ScheduleExternalCourseSnapshot(id: course.id, name: course.name, classroom: course.classroom,
                teacher: course.teacher, weeks: problem == "weeks" ? [Int.max] : course.weeks,
                weekday: problem == "weekday" ? 0 : course.weekday, startSection: 1,
                endSection: problem == "section" ? 2 : 1)])
        let afterTerm = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: valid, now: afterTerm).contentState == .rest)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: afterTerm).contentState == .invalid)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.encode(snapshot) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let invalidData = try encoder.encode(snapshot)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.decode(invalidData) }
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        try store.write(valid)
        let stored = try #require(store.load())
        #expect(throws: CocoaError.self) { try store.writeIfNewer(snapshot) }
        #expect(store.load() == stored)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func futureTimelineIncludesClassTransitionsAndMidnight(phone: Bool) async throws {
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
        let timeline = ScheduleOccurrenceResolver.resolvedTimeline(from: snapshot, now: now, includeDisplayUntilDates: phone, limit: 1)
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/timeline-store"))
        #expect(store.save(snapshot))
        let storedTimeline = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, now: now, includeDisplayUntilDates: phone, limit: 1)
        #expect(storedTimeline.map(\.date) == timeline.map(\.date))
        #expect(storedTimeline.map(\.resolved.upcomingOccurrences) == timeline.map(\.resolved.upcomingOccurrences))
        let background = await ScheduleOccurrenceResolver.loadResolvedSnapshotAsync(store: store, now: now, limit: 1)
        #expect(background.upcomingOccurrences == ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now, limit: 1).upcomingOccurrences)
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

    @Test(arguments: ["07:00", "09:10"])
    func overlappingTimelineRetainsTheLastCourseAfterTheOtherCourseEnds(time: String) throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-09-28"))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: time))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "fixture", firstDayString: "2026-09-28",
            timeTable: [.init(id: 1, start: "08:00", end: "08:45"), .init(id: 2, start: "09:00", end: "09:30"), .init(id: 3, start: "09:40", end: "10:00")],
            courses: [.init(id: "long", name: "长课", classroom: "", teacher: "", weeks: [1], weekday: 1, startSection: 1, endSection: 3),
                .init(id: "short", name: "短课", classroom: "", teacher: "", weeks: [1], weekday: 1, startSection: 2, endSection: 2)])
        let timeline = ScheduleOccurrenceResolver.resolvedTimeline(from: snapshot, now: now, includeDisplayUntilDates: true, limit: 1)
        let shortEnd = try #require(ScheduleSharedDateCodec.combine(date: day, time: "09:30"))
        let longEnd = try #require(ScheduleSharedDateCodec.combine(date: day, time: "10:00"))
        let resumed = try #require(timeline.first { $0.date == shortEnd })
        #expect(resumed.resolved.nextOccurrence?.id == "long-1")
        #expect(resumed.resolved.nextOccurrence?.displayUntilDate == longEnd)
        #expect(timeline.first { $0.date == longEnd }?.resolved.contentState == .rest)
        for entry in timeline {
            let reference = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: entry.date, limit: 1)
            #expect(entry.resolved.upcomingOccurrences == reference.upcomingOccurrences)
        }
        #expect(ScheduleOccurrenceResolver.resolvedTimeline(from: snapshot, now: now,
            includeDisplayUntilDates: true, limit: 0).allSatisfy { $0.resolved.upcomingOccurrences.isEmpty })
    }

    private func makeSnapshot() -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_790_553_600),
            isLoggedIn: true,
            studentID: AccountStorageIdentity.stableToken(for: "module-test-account"),
            firstDayString: "2026-09-28",
            timeTable: [ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "08:45")],
            courses: [ScheduleExternalCourseSnapshot(
                id: "course", name: "模块验证课程", classroom: "文萃楼I203", teacher: "教师",
                weeks: [1], weekday: 1, startSection: 1, endSection: 1
            )]
        )
    }
}

@MainActor
struct ScheduleSharedStoreTests {
    @Test(arguments: ["bytes", "courses", "weeks", "field", "aggregate", "revision"])
    func invalidSharedSnapshotsPreserveTheirSourceAndAllowReplacementAndClear(kind: String) throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: URL(fileURLWithPath: "/shared-budget"))
        let url = try #require(store.fileURL)
        let course = ScheduleExternalCourseSnapshot(id: "fixture", name: kind == "field" ? String(repeating: "课", count: 1_366)
            : kind == "aggregate" ? String(repeating: "n", count: ScheduleExternalSnapshotCodec.maximumFieldBytes) : "fixture",
            classroom: "", teacher: "", weeks: kind == "weeks" ? Array(repeating: 1, count: ScheduleCourseConstraints.maximumWeek * 2 + 1) : [1],
            weekday: 1, startSection: 1, endSection: 1)
        let invalid = ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 0),
            revision: kind == "revision" ? UInt64.max : 1, isLoggedIn: true, studentID: "budget-owner",
            firstDayString: "", timeTable: [], courses: kind == "courses" ? Array(repeating: course, count: ScheduleExternalSnapshotCodec.maximumCourseCount + 1)
                : kind == "aggregate" ? Array(repeating: course, count: ScheduleExternalSnapshotCodec.maximumEncodedBytes / ScheduleExternalSnapshotCodec.maximumFieldBytes + 1) : [course])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let raw = kind == "bytes" ? Data(count: ScheduleExternalSnapshotCodec.maximumEncodedBytes + 1) : try encoder.encode(invalid)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.decode(raw) }
        if kind != "bytes" { #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.encode(invalid) } }
        try files.writeData(raw, to: url, options: [])
        let reads = files.readCount(at: url)
        #expect(store.load() == nil && files.storedData[url] == raw)
        if kind == "bytes" { #expect(files.readCount(at: url) == reads) }
        #expect(throws: ScheduleExternalSnapshotStoreError.invalidSnapshot) { try store.read() }
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let recovered = ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 0), revision: 2,
            isLoggedIn: true, studentID: "budget-owner", firstDayString: "", timeTable: [], courses: [])
        #expect(try store.writeIfNewer(recovered))
        #expect(store.load()?.revision == 2)
        #expect(store.clear() && store.load() == nil)
        if kind == "revision" {
            #expect(WatchScheduleTransferProtocol.knownRevision(from: WatchScheduleTransferProtocol.requestContext(knownRevision: .max)) == nil)
        }
    }

    @Test(arguments: ["same-account", "new-account"])
    func restoredPhoneSnapshotsAdvancePastTheWatchHead(account: String) throws {
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/watch-recovery"))
        func snapshot(_ revision: UInt64, _ identifier: String, _ seconds: Double) -> ScheduleExternalSnapshot {
            .init(generatedAt: Date(timeIntervalSince1970: seconds), revision: revision,
                isLoggedIn: true, studentID: identifier, firstDayString: "", timeTable: [], courses: [])
        }
        try store.write(snapshot(1_000, "same-account", 1_000))
        let phone = snapshot(10, account, 10)
        let request = WatchScheduleTransferProtocol.requestContext(knownRevision: try #require(store.load()).revision)
        let knownRevision = try #require(WatchScheduleTransferProtocol.knownRevision(from: request))
        let recovered = try #require(phone.advancingRevision(after: knownRevision))
        #expect(try store.writeIfNewer(recovered))
        #expect(store.load()?.studentID == AccountStorageIdentity.stableToken(for: account) && store.load()?.revision == 1_001)
        #expect(recovered.advancingRevision(after: 10) == recovered)
        #expect(phone.advancingRevision(after: UInt64.max) == nil)
        #expect(WatchScheduleTransferProtocol.knownRevision(from: [WatchScheduleTransferProtocol.requestLatestSnapshotKey: true]) == nil)
    }

    @Test(arguments: [UInt64(0), UInt64(1_000)])
    func clearedSnapshotVersionsSurviveStoreReconstruction(revision: UInt64) throws {
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/watch-cleared-version")
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: root)
        let snapshot = ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
            isLoggedIn: true, studentID: "watch-account", firstDayString: "", timeTable: [], courses: [])
        try store.write(snapshot)
        #expect(store.clearRetainingVersion() && store.load() == nil)
        let restored = ScheduleExternalSnapshotStore(files: files, containerURL: root)
        #expect(restored.load() == nil && restored.latestRevision == revision)
        #expect(restored.clearRetainingVersion())
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try restored.writeIfNewer(snapshot) }
        #expect(restored.load() == nil)
        let fresh = try #require(snapshot.advancingRevision(after: restored.latestRevision))
        #expect(try restored.writeIfNewer(fresh))
        #expect(restored.load()?.revision == revision + 1)
        files.setFailures(writing: true)
        #expect(restored.clearRetainingVersion() == false)
        #expect(restored.load()?.revision == revision + 1)
        files.setFailures()
        let file = try #require(restored.fileURL)
        try files.writeData(Data("damaged snapshot".utf8), to: file, options: [])
        #expect(restored.clearRetainingVersion() && restored.load() == nil)
        #expect(files.storedData[file] == nil)
    }

    @Test func outOfOrderSnapshotsPreserveTheNewAccountAndLogout() throws {
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/module-shared-order"))
        func value(_ revision: UInt64, _ account: String, loggedIn: Bool = true) -> ScheduleExternalSnapshot {
            ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
                isLoggedIn: loggedIn, studentID: AccountStorageIdentity.stableToken(for: account),
                firstDayString: "2026-09-28", timeTable: [], courses: [])
        }
        let current = value(2, "new-account")
        #expect(try store.writeIfNewer(current))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(value(1, "old-account")) }
        #expect(store.load() == current)
        #expect(try store.writeIfNewer(current) == false)
        let logout = value(3, "new-account", loggedIn: false)
        #expect(try store.writeIfNewer(logout))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(current) }
        #expect(store.load() == logout)
        #expect(try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(logout)) == logout)
    }

    private func snapshot(studentID: String = "shared-store-account") -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: true, studentID: studentID,
            firstDayString: "2026-09-28", timeTable: [], courses: []
        )
    }

    private func observeChange(on center: NotificationCenter, operation: () throws -> Void) async throws {
        var observer: (any NSObjectProtocol)?
        defer { if let observer { center.removeObserver(observer) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            observer = center.addObserver(forName: .scheduleExternalSnapshotDidChange, object: nil, queue: nil) { _ in
                continuation.resume()
            }
            do { try operation() } catch { continuation.resume(throwing: error) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func injectedContainerFilesAndNotificationsOwnTheSnapshot() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store"), notificationCenter: center
        )
        let other = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store-other"), notificationCenter: NotificationCenter()
        )
        let value = snapshot(studentID: AccountStorageIdentity.stableToken(for: "shared-store-account"))
        try await observeChange(on: center) { try store.write(value) }
        let url = try #require(store.fileURL)
        #expect(url.path == "/module-shared-store/Widgets/schedule-widget-snapshot.json")
        #expect(files.writingOptions(at: url) == AppFileSystem.protectedDataWritingOptions)
        #expect(store.load() == value)
        #expect(other.load() == nil)
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .rest)
        try await observeChange(on: center) { #expect(store.clear()) }
        #expect(store.load() == nil)
        #expect(store.clear())
    }

    @Test(.timeLimit(.minutes(1))) func legacyIdentityMigrationUsesTheInjectedStore() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-migration"), notificationCenter: center
        )
        let url = try #require(store.fileURL)
        let original = try ScheduleExternalSnapshotCodec.encode(snapshot())
        try files.writeData(original, to: url, options: [.atomic])
        let migrated = store.load()
        #expect(migrated?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == original)
        let sanitized = try #require(migrated)
        try await observeChange(on: center) { try store.write(sanitized) }
        #expect(try ScheduleExternalSnapshotCodec.decode(files.readData(at: url)) == migrated)
    }

    @Test func unreadableDataAndFailedMutationsPreserveStoredBytes() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-failures"), notificationCenter: NotificationCenter()
        )
        let url = try #require(store.fileURL)
        let corrupt = Data("corrupt snapshot".utf8)
        try files.writeData(corrupt, to: url, options: [.atomic])
        #expect(store.load() == nil)
        #expect(try files.readData(at: url) == corrupt)
        files.setFailures(writing: true, removal: true)
        #expect(store.save(snapshot()) == false)
        #expect(store.clear() == false)
        #expect(try files.readData(at: url) == corrupt)
        files.setFailures()
        let legacy = try ScheduleExternalSnapshotCodec.encode(snapshot())
        try files.writeData(legacy, to: url, options: [.atomic])
        files.setFailures(writing: true)
        #expect(store.load()?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == legacy)
    }

    @Test func readingFailurePreservesNewerSnapshotsWhileWritesRemainAvailable() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: URL(fileURLWithPath: "/module-shared-failures"))
        func value(_ revision: UInt64) -> ScheduleExternalSnapshot {
            ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: Double(revision)), revision: revision,
                isLoggedIn: true, studentID: "shared-store-account", firstDayString: "", timeTable: [], courses: [])
        }
        try store.write(value(2))
        let url = try #require(store.fileURL), original = files.storedData[url]
        files.setFailures(reading: true, existence: true)
        #expect(store.load() == nil)
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.read() }
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .unavailable)
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.writeIfNewer(value(1)) }
        #expect(files.storedData[url] == original)
        files.setFailures(removal: true, existence: true)
        #expect(!store.clear())
        #expect(files.storedData[url] == original)
        files.setFailures()
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(value(1)) }
        #expect(try store.writeIfNewer(value(3)))
        #expect(store.load()?.revision == 3)
    }

    @Test func unavailableContainersHaveExplicitResults() {
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: nil, notificationCenter: NotificationCenter())
        #expect(store.fileURL == nil)
        #expect(store.load() == nil)
        #expect(throws: ScheduleExternalSnapshotStoreError.sharedContainerUnavailable) { try store.read() }
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .unavailable)
        #expect(store.save(snapshot()) == false)
        #expect(store.clear() == false)
        #expect(throws: ScheduleExternalSnapshotStoreError.sharedContainerUnavailable) { try store.write(snapshot()) }
    }

    @Test func missingAndMalformedSnapshotsHaveDistinctDisplayStates() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: URL(fileURLWithPath: "/shared-display"))
        #expect(try store.read() == nil)
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .missing)
        let url = try #require(store.fileURL)
        try files.writeData(Data("invalid-json".utf8), to: url, options: [])
        #expect(throws: ScheduleExternalSnapshotStoreError.invalidSnapshot) { try store.read() }
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let now = Date(timeIntervalSince1970: 0)
        let timeline = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, now: now, includeDisplayUntilDates: true)
        #expect(timeline.map(\.date) == [now] && timeline.first?.resolved.contentState == .invalid)
        #expect(try store.writeIfNewer(snapshot()))
        #expect(try store.read() != nil)
    }
}

struct ScheduleTimestampPublicContractTests {
    @Test func monotonicVersionsAndCloudRestorationUseDomainRules() {
        let previous = Date(timeIntervalSince1970: 100)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous) > previous)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous.addingTimeInterval(-10)) > previous)
        #expect(ScheduleCacheTimestamp.afterCloudSave(previous.addingTimeInterval(-10), currentDate: previous) == previous)
        #expect(ScheduleCacheTimestamp.restored(recordDate: previous, payloadDate: previous.addingTimeInterval(1), serverDate: previous.addingTimeInterval(20)) == previous.addingTimeInterval(20))
        #expect(ScheduleCacheTimestamp.restored(recordDate: previous, payloadDate: previous.addingTimeInterval(2)) == nil)
    }
}
