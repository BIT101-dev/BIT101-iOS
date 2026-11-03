import BIT101TestSupport
import Foundation
import ScheduleContracts
import ScheduleDomain
import ScheduleSharedStore
import StorageCore
import Testing

struct ScheduleContractsTests {
    @Test func deadlineSnapshotsRoundTripAcrossAccount() throws {
        let deadline = ScheduleExternalDeadlineSnapshot(
            id: "manual", title: "报告", subtitle: "课程", sourceTitle: "自定义",
            dueAt: Date(timeIntervalSince1970: 100))
        let snapshot = ScheduleExternalSnapshot(
            revision: 2, isLoggedIn: true, studentID: "owner",
            firstDayString: "", timeTable: [], courses: [], deadlines: [deadline], ddlAfterDay: 5)
        let advanced = try #require(
            snapshot.replacingStudentID(with: "opaque-owner").advancingRevision(after: 10))
        let decoded = try ScheduleExternalSnapshotCodec.decode(
            ScheduleExternalSnapshotCodec.encode(advanced))
        #expect(decoded.deadlines == [deadline] && decoded.ddlAfterDay == 5)
        #expect(decoded.revision == 11 && decoded.studentID == "opaque-owner")
        var legacy = try #require(
            JSONSerialization.jsonObject(with: ScheduleExternalSnapshotCodec.encode(snapshot))
                as? [String: Any])
        legacy.removeValue(forKey: "deadlines")
        legacy.removeValue(forKey: "ddlAfterDay")
        let restored = try ScheduleExternalSnapshotCodec.decode(
            JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.deadlines.isEmpty && restored.ddlAfterDay == 3)
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL)
        try store.write(snapshot)
        #expect(store.load()?.deadlines == [deadline])
        let cleared = ScheduleExternalSnapshot(
            revision: 3, isLoggedIn: false, studentID: "owner", firstDayString: "", timeTable: [],
            courses: [])
        #expect(try store.writeIfNewer(cleared))
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(from: store.load()).contentState == .loggedOut
        )
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) {
            try store.writeIfNewer(snapshot)
        }
    }

    @Test func deadlineResolutionUsesRetention() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func deadline(_ id: String, _ offset: TimeInterval) -> ScheduleExternalDeadlineSnapshot {
            .init(
                id: id, title: id, subtitle: "", sourceTitle: "自定义",
                dueAt: now.addingTimeInterval(offset))
        }
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: "owner", firstDayString: "",
            timeTable: [], courses: [],
            deadlines: [
                deadline("later", 3600), deadline("b", -86400), deadline("a", -86400),
                deadline("expired", -86401),
            ], ddlAfterDay: 1)
        let resolved = ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now)
        #expect(
            resolved.contentState == .ready && resolved.deadlines.map(\.id) == ["a", "b", "later"])
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now, limit: 1).deadlines
                .map(\.id) == ["a"])
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now, limit: 0)
                .contentState == .rest)
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(
                from: snapshot, now: now.addingTimeInterval(2 * 86400)
            ).contentState == .rest)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: nil).contentState == .missing)
        let signedOut = ScheduleExternalSnapshot(
            isLoggedIn: false, studentID: "", firstDayString: "", timeTable: [], courses: [],
            deadlines: snapshot.deadlines)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: signedOut).deadlines.isEmpty)
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(from: signedOut).contentState == .loggedOut)
    }

    @Test func deadlineTimelineSwitchesExpiry() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-10-01"))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "12:00"))
        let deadline = ScheduleExternalDeadlineSnapshot(
            id: "due", title: "报告", subtitle: "", sourceTitle: "课程中心",
            dueAt: now.addingTimeInterval(300))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [],
            deadlines: [deadline], ddlAfterDay: 0)
        let dates = ScheduleDeadlineResolver.timelineEntries(from: snapshot, now: now).map(\.date)
        #expect(
            dates == [
                now, deadline.dueAt, deadline.dueAt.addingTimeInterval(1),
                day.addingTimeInterval(86400), now.addingTimeInterval(86400),
            ])
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: deadline.dueAt)
                .contentState == .ready)
        #expect(
            ScheduleDeadlineResolver.resolvedSnapshot(
                from: snapshot, now: deadline.dueAt.addingTimeInterval(1)
            ).contentState == .rest)
        #expect(
            ScheduleDeadlineResolver.timelineEntries(from: nil, now: now).map(\.date) == [
                now, day.addingTimeInterval(86400), now.addingTimeInterval(86400),
            ])
    }

    @Test(arguments: [
        "blank-title", "blank-id", "duplicate-id", "oversized-subtitle", "invalid-retention",
        "invalid-date",
    ])
    func invalidDeadlinePayloadsFailAtBoundary(field: String) {
        let deadline = ScheduleExternalDeadlineSnapshot(
            id: field == "blank-id" ? " " : "id", title: field == "blank-title" ? " " : "报告",
            subtitle: field == "oversized-subtitle"
                ? String(repeating: "x", count: ScheduleExternalSnapshotCodec.maximumFieldBytes + 1)
                : "",
            sourceTitle: "乐学",
            dueAt: Date(timeIntervalSince1970: field == "invalid-date" ? .infinity : 100))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [],
            deadlines: field == "duplicate-id" ? [deadline, deadline] : [deadline],
            ddlAfterDay: field == "invalid-retention" ? 31 : 3)
        #expect(throws: Error.self) { try ScheduleExternalSnapshotCodec.encode(snapshot) }
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot).contentState == .invalid)
    }

    @Test(.timeLimit(.minutes(1))) func maximumSharePayloadCodec() async throws {
        let weeks = Array(1...20)
        let courses = (0..<ScheduleShareCodeCodec.maximumCourseCount).map { index in
            sharedCourse(weeks: weeks, name: "容量课程\(index)")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let code = try await ScheduleShareCodeCodec.encodeForSharing(courses: courses)
        let encoded = clock.now
        let payload = try await ScheduleShareCodeCodec.decodeForImport(code, using: ScheduleCache())
        print(
            """
            [性能] 分享码 \(courses.count) 门课程 · 编码 \(start.duration(to: encoded)) · 解码 \
            \(encoded.duration(to: clock.now))
            """
        )
        #expect(payload.courses.count == courses.count)
        #expect(payload.courses.map(\.name) == courses.map(\.name))
        #expect(payload.courses.map(\.weeks) == courses.map(\.weeks))
        let canceled = Task {
            try await ScheduleShareCodeCodec.decodeForImport(code, using: ScheduleCache())
        }
        canceled.cancel()
        do {
            _ = try await canceled.value
            Issue.record("取消后的分享码仍完成导入")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func archivingSchoolSnapshotsRetainsReload() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        let school = try ScheduleCourseEditor.adding(
            CourseDraft(title: "学校课程", weeksText: "1-4"),
            to: [], term: "term", id: "school")
        let snapshot = TermScheduleSnapshot(
            term: "term", firstDayString: "2026-09-07", courses: school, exams: [],
            updatedAt: Date())
        cache.courseData.store(snapshot)
        let local = try ScheduleCourseEditor.adding(
            CourseDraft(title: "补录课程", weeksText: "1-4"),
            to: school, term: "term", id: "manual")
        ScheduleCourseEditor.updateCourseEditCache(
            in: &cache, previousCourses: school, currentCourses: local)
        let rules = cache.manualCourseRulesByTerm
        cache.courseData.archive(term: "term")
        cache = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(cache.manualCourseRulesByTerm == rules)
        cache.courseData.store(snapshot)
        #expect(cache.courses.contains { $0.name == "补录课程" })
    }

    @Test func guestSnapshotIdentityBoundaries() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL,
            notificationCenter: NotificationCenter())
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100), isLoggedIn: false,
            studentID: AppStorageSession(accountIdentifier: "").accountStorageIdentifier,
            firstDayString: "", timeTable: [], courses: [])
        #expect(AccountStorageIdentity.stableToken(for: snapshot.studentID) == snapshot.studentID)
        try store.write(snapshot)
        #expect(store.load() == snapshot)
        #expect(try store.writeIfNewer(snapshot) == false)
    }

    @Test(arguments: ["title", "teacher", "classroom", "combined-classroom"])
    func manualCourseFieldsLimits(field: String) throws {
        let value =
            String(repeating: "课", count: ScheduleCourseConstraints.maximumFieldBytes / 3) + "x"
        #expect(value.utf8.count == ScheduleExternalSnapshotCodec.maximumFieldBytes)
        var draft = CourseDraft(title: "课程", weeksText: "1")
        switch field {
        case "title": draft.title = value
        case "teacher": draft.teacher = value
        case "classroom": draft.classroom = value
        default:
            draft.buildingName = String(value.dropLast())
            draft.roomNumber = ""
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

    @Test func extremeCourseFieldsAreRejectedRejected() throws {
        for input in ["1-1000000000", String(Int.max), String(Int.min), "-1000000000-1"] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks(input) }
        }
        #expect(try ScheduleCourseEditor.parseWeeks("-2,-1,1-3") == [-2, -1, 1, 2, 3])
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(
                CourseDraft(title: "范围", startSection: 1, endSection: Int.max, weeksText: "1"))
        }
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        #expect(
            ScheduleSharedDateCodec.combine(firstDay: day, week: Int.max, weekday: 1, time: "08:00")
                == nil)
        #expect(
            ScheduleSharedDateCodec.combine(firstDay: day, week: Int.min, weekday: 1, time: "08:00")
                == nil)
        #expect(
            ScheduleSharedDateCodec.combine(firstDay: day, week: 1, weekday: Int.max, time: "08:00")
                == nil)
        let oversized =
            "BIT101SCH3:"
            + String(repeating: "A", count: ScheduleShareCodeCodec.maximumEncodedBytes)
        #expect(throws: ScheduleShareCodeError.invalidFormat) {
            try ScheduleShareCodeCodec.decode(oversized, using: ScheduleCache())
        }
        let expanded = Data(repeating: 32, count: ScheduleShareCodeCodec.maximumDecodedBytes + 1)
        let compressed = try (expanded as NSData).compressed(using: .lzfse) as Data
        #expect(throws: ScheduleShareCodeError.decompressionFailed) {
            try ScheduleShareCodeCodec.decode(
                "BIT101SCH3:" + compressed.base64EncodedString(), using: ScheduleCache())
        }
    }

    @Test func sharePayloadValidatesCourseFieldsTimeSlots() throws {
        let slots = TimeSlot.default
        for (weeks, weekday, first, last) in [
            ([Int.max], 1, 1, 1), ([1], 8, 1, 1), ([1], 1, 0, 1), ([1], 1, 1, Int.max),
            ([1], 1, 1, slots.count + 1),
        ] {
            let course = sharedCourse(weeks: weeks, weekday: weekday, first: first, last: last)
            let payload = ScheduleExportPayload(
                currentTerm: "", firstDayString: "", timeTable: slots, courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try payload.validate() }
        }
        let course = sharedCourse(weeks: [-2, -1, 1])
        try ScheduleExportPayload(
            currentTerm: "", firstDayString: "", timeTable: slots, courses: [course]
        ).validate()
        #expect(throws: ScheduleShareCodeError.invalidFormat) {
            try ScheduleShareCodeCodec.encodeLatest(
                courses: Array(
                    repeating: course, count: ScheduleShareCodeCodec.maximumCourseCount + 1))
        }
        let midnight = ScheduleExportPayload(
            currentTerm: "", firstDayString: "",
            timeTable: [TimeSlot(id: 1, start: "23:00", end: "24:00")], courses: [course])
        try midnight.validate()
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        for time in ["08::00", ":08:00:", "08:00:", ":08:00", "08:", ":00"] {
            #expect(ScheduleSharedDateCodec.combine(date: day, time: time) == nil)
            #expect(TimeSlot.parseMinutes(time) == 0)
            let malformed = ScheduleExportPayload(
                currentTerm: "", firstDayString: "",
                timeTable: [TimeSlot(id: 1, start: time, end: "09:00")], courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try malformed.validate() }
        }
    }

    @Test func externalOccurrencesRetainCourses() throws {
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: .distantPast, isLoggedIn: true, studentID: "negative-weeks",
            firstDayString: "2030-09-16", timeTable: [.init(id: 1, start: "08:00", end: "08:45")],
            courses: [
                .init(
                    id: "negative", name: "首周前课程", classroom: "", teacher: "", weeks: [-2, -1, 1],
                    weekday: 1, startSection: 1, endSection: 1)
            ])
        let now = try #require(ScheduleSharedDateCodec.parseDate("2030-09-01"))
        let occurrences = ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now)
        #expect(occurrences.count == 3)
        #expect(
            occurrences.map { ScheduleSharedDateCodec.formatDate($0.startDate) } == [
                "2030-09-02", "2030-09-09", "2030-09-16",
            ])
    }

    private func sharedCourse(
        weeks: [Int], weekday: Int = 1, first: Int = 1, last: Int = 1, name: String = "课程",
        credit: Double = 0
    ) -> CourseRecord {
        CourseRecord(
            id: "share-validation", term: "", name: name, teacher: "", classroom: "",
            description: "", weeks: weeks,
            weekday: weekday, startSection: first, endSection: last, campus: "", number: "",
            credit: credit, hour: 0, type: "", category: "", department: "")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteCreditsAreRejectedCourse(_ credit: Double) throws {
        let course = sharedCourse(weeks: [1], credit: credit)
        #expect(!course.hasValidPlacement && course.creditText == "-")
        var cache = ScheduleCache()
        cache.courseData.schedulesByTerm["term"] = TermScheduleSnapshot(
            term: "term", firstDayString: "2026-09-07",
            courses: [course], exams: [], updatedAt: Date())
        #expect(!cache.isValidForPersistence)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(course)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        #expect(throws: DecodingError.self) { try decoder.decode(CourseRecord.self, from: data) }
    }

    @Test @MainActor func scheduleDateDisplaysUseSchoolTimeZone() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-10-01"))
        #expect(ScheduleDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleSharedDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleDateCodec.calendar == ScheduleSharedDateCodec.calendar)
        #expect(ScheduleDateCodec.formatCompactDate(day) == "10.1")
        #expect(ScheduleDateCodec.formatDate(day.addingTimeInterval(-1)) == "2026-09-30")
    }

    @Test func courseSnapshotTracksChanges() {
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

    @Test func domainStorageResultsReadable() {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "领域快照"
        #expect(ScheduleCacheLoadResult.missing.allowsWrite)
        #expect(ScheduleCacheLoadResult.missing.cacheIfReadable?.courses.isEmpty == true)
        #expect(
            ScheduleCacheLoadResult.loaded(cache).cacheIfReadable?.primaryScheduleTitle == "领域快照")
        #expect(ScheduleCacheLoadResult.unreadable.isUnreadable)
        #expect(ScheduleCacheLoadResult.unreadable.cacheIfReadable == nil)
        #expect(ScheduleCacheLoadResult.unreadable.allowsWrite == false)
    }

    @Test @MainActor func domainCourseEditingSurvivesCache() throws {
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
        ScheduleCourseEditor.updateCourseEditCache(
            in: &cache, previousCourses: [], currentCourses: courses)
        let restored = try JSONDecoder().decode(
            ScheduleCache.self, from: JSONEncoder().encode(cache))
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

    @Test func fixedPayloadAndFutureFieldsUseWatchCodec() throws {
        let payload = Data(
            #"""
            {"isLoggedIn":true,"studentID":"fixture-account","firstDayString":"2026-09-28","ti\#
            meTable":[{"id":1,"start":"08:00","end":"08:45","futureTimeField":1}],"courses":[{\#
            "id":"fixture-course","name":"固定课程","weeks":[1],"weekday":1,"startSection":1,"futu\#
            reCourseField":true}],"futureSnapshotField":"value"}
            """#
            .utf8)
        let context = WatchScheduleTransferProtocol.snapshotContext(payload)
        let decoded = try ScheduleExternalSnapshotCodec.decode(
            #require(WatchScheduleTransferProtocol.snapshotData(from: context)))
        #expect(decoded.generatedAt == .distantPast)
        #expect(decoded.courses.first?.teacher == "")
        #expect(decoded.courses.first?.classroom == "")
        #expect(decoded.courses.first?.endSection == 1)
        #expect(decoded.timeTable.first?.start == "08:00")
        #expect(
            try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(decoded))
                == decoded)
    }

    @Test func incompleteSchedulingIdentityHasFailure() {
        let payload = Data(
            #"{"courses":[{"id":"fixture-course","name":"课程","weeks":[1],"startSection":1}]}"#.utf8)
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
        #expect(
            WatchScheduleTransferProtocol.requestsLatestSnapshot(
                WatchScheduleTransferProtocol.requestContext()))
    }

    @Test func occurrenceAndRefreshBoundaries() throws {
        let snapshot = makeSnapshot()
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        #expect(resolved.contentState == .ready)
        let occurrence = try #require(resolved.nextOccurrence)
        #expect(
            occurrence.startDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:00"))
        #expect(
            occurrence.endDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:45"))
        #expect(
            ScheduleTimelineRefreshPlanner.nextRefreshDate(
                for: resolved.upcomingOccurrences,
                now: now,
                includeDisplayUntilDates: true,
                includeNextMidnight: true
            ) == occurrence.startDate)
        for leadTime: TimeInterval in [1, 10, 29, 30] {
            for displayDates in [true, false] {
                #expect(
                    ScheduleTimelineRefreshPlanner.nextRefreshDate(
                        for: [occurrence], now: occurrence.startDate.addingTimeInterval(-leadTime),
                        includeDisplayUntilDates: displayDates, includeNextMidnight: true)
                        == occurrence.startDate)
            }
        }
        #expect(
            ScheduleTimelineRefreshPlanner.nextRefreshDate(
                for: [occurrence], now: occurrence.displayUntilDate.addingTimeInterval(-10),
                includeDisplayUntilDates: true, includeNextMidnight: false)
                == occurrence.displayUntilDate)
        let midnight = try #require(
            ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: firstDay)
        ).addingTimeInterval(1)
        #expect(
            ScheduleTimelineRefreshPlanner.nextRefreshDate(
                for: [], now: midnight.addingTimeInterval(-10),
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
    func invalidCourseStructureRemainsDistinctTerm(problem: String) throws {
        let valid = makeSnapshot()
        let course = valid.courses[0]
        let slot = valid.timeTable[0]
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: valid.generatedAt, revision: 10, isLoggedIn: true,
            studentID: valid.studentID, firstDayString: valid.firstDayString,
            timeTable: problem == "duplicate"
                ? [slot, slot]
                : [
                    ScheduleExternalTimeSlotSnapshot(
                        id: slot.id,
                        start: problem == "time" ? "25:00" : slot.start, end: slot.end)
                ],
            courses: [
                ScheduleExternalCourseSnapshot(
                    id: course.id, name: course.name, classroom: course.classroom,
                    teacher: course.teacher, weeks: problem == "weeks" ? [Int.max] : course.weeks,
                    weekday: problem == "weekday" ? 0 : course.weekday, startSection: 1,
                    endSection: problem == "section" ? 2 : 1)
            ])
        let afterTerm = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            ScheduleOccurrenceResolver.resolvedSnapshot(from: valid, now: afterTerm).contentState
                == .rest)
        #expect(
            ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: afterTerm).contentState
                == .invalid)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.encode(snapshot) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let invalidData = try encoder.encode(snapshot)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.decode(invalidData) }
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL)
        try store.write(valid)
        let stored = try #require(store.load())
        #expect(throws: CocoaError.self) { try store.writeIfNewer(snapshot) }
        #expect(store.load() == stored)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func futureTimelineIncludesClassTransitions(phone: Bool) async throws {
        let base = makeSnapshot()
        let course = try #require(base.courses.first)
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: base.generatedAt, isLoggedIn: base.isLoggedIn,
            studentID: base.studentID, firstDayString: base.firstDayString,
            timeTable: base.timeTable,
            courses: [
                ScheduleExternalCourseSnapshot(
                    id: course.id, name: course.name, classroom: course.classroom,
                    teacher: course.teacher, weeks: [1, 2], weekday: course.weekday,
                    startSection: course.startSection, endSection: course.endSection)
            ])
        let day = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        let occurrence = try #require(resolved.nextOccurrence)
        let cutoff = occurrence.startDate.addingTimeInterval(
            ScheduleOccurrenceResolver.defaultCurrentCourseDisplayDuration)
        let midnight = try #require(
            ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: day))
        let dates = ScheduleTimelineRefreshPlanner.timelineDates(
            for: resolved.upcomingOccurrences + resolved.upcomingOccurrences,
            now: now, includeDisplayUntilDates: phone)
        #expect(dates == dates.sorted() && Set(dates).count == dates.count)
        #expect(dates.first == now && dates.last == now.addingTimeInterval(24 * 60 * 60))
        #expect(dates.contains(occurrence.startDate) && dates.contains(midnight))
        #expect(dates.contains(cutoff) == phone)
        #expect(dates.contains(occurrence.endDate) == phone)
        let timeline = ScheduleOccurrenceResolver.resolvedTimeline(
            from: snapshot, now: now, includeDisplayUntilDates: phone, limit: 1)
        let store = ScheduleExternalSnapshotStore(
            files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/timeline-store"))
        #expect(store.save(snapshot))
        let storedTimeline = ScheduleOccurrenceResolver.loadResolvedTimeline(
            store: store, now: now, includeDisplayUntilDates: phone, limit: 1)
        #expect(storedTimeline.map(\.date) == timeline.map(\.date))
        #expect(
            storedTimeline.map(\.resolved.upcomingOccurrences)
                == timeline.map(\.resolved.upcomingOccurrences))
        let background = await ScheduleOccurrenceResolver.loadResolvedSnapshotAsync(
            store: store, now: now, limit: 1)
        #expect(
            background.upcomingOccurrences
                == ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now, limit: 1)
                .upcomingOccurrences)
        #expect(timeline.map(\.date) == dates)
        for entry in timeline {
            let reference = ScheduleOccurrenceResolver.resolvedSnapshot(
                from: snapshot, now: entry.date, limit: 1)
            #expect(entry.resolved.contentState == reference.contentState)
            #expect(entry.resolved.upcomingOccurrences == reference.upcomingOccurrences)
        }
        let last = try #require(resolved.upcomingOccurrences.last)
        #expect(last.displayUntilDate == last.endDate)
        #expect(!dates.contains(last.startDate))
        #expect(
            ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: occurrence.startDate)
                .nextOccurrence?.id == occurrence.id)
        #expect(
            ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: cutoff).nextOccurrence?
                .id != occurrence.id)
        let empty = ScheduleTimelineRefreshPlanner.timelineDates(
            for: [], now: now, includeDisplayUntilDates: phone)
        #expect(empty == [now, midnight, now.addingTimeInterval(24 * 60 * 60)])
    }

    @Test(arguments: ["07:00", "09:10"])
    func overlappingTimelineRetainsLastCourse(time: String) throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-09-28"))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: time))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: "fixture", firstDayString: "2026-09-28",
            timeTable: [
                .init(id: 1, start: "08:00", end: "08:45"),
                .init(id: 2, start: "09:00", end: "09:30"),
                .init(id: 3, start: "09:40", end: "10:00"),
            ],
            courses: [
                .init(
                    id: "long", name: "长课", classroom: "", teacher: "", weeks: [1], weekday: 1,
                    startSection: 1, endSection: 3),
                .init(
                    id: "short", name: "短课", classroom: "", teacher: "", weeks: [1], weekday: 1,
                    startSection: 2, endSection: 2),
            ])
        let timeline = ScheduleOccurrenceResolver.resolvedTimeline(
            from: snapshot, now: now, includeDisplayUntilDates: true, limit: 1)
        let shortEnd = try #require(ScheduleSharedDateCodec.combine(date: day, time: "09:30"))
        let longEnd = try #require(ScheduleSharedDateCodec.combine(date: day, time: "10:00"))
        let resumed = try #require(timeline.first { $0.date == shortEnd })
        #expect(resumed.resolved.nextOccurrence?.id == "long-1")
        #expect(resumed.resolved.nextOccurrence?.displayUntilDate == longEnd)
        #expect(timeline.first { $0.date == longEnd }?.resolved.contentState == .rest)
        for entry in timeline {
            let reference = ScheduleOccurrenceResolver.resolvedSnapshot(
                from: snapshot, now: entry.date, limit: 1)
            #expect(entry.resolved.upcomingOccurrences == reference.upcomingOccurrences)
        }
        #expect(
            ScheduleOccurrenceResolver.resolvedTimeline(
                from: snapshot, now: now,
                includeDisplayUntilDates: true, limit: 0
            ).allSatisfy { $0.resolved.upcomingOccurrences.isEmpty })
    }

    @Test func largeSnapshotKeepsLimitedOccurrenceOrder() throws {
        let base = makeSnapshot()
        let courses = (0..<ScheduleExternalSnapshotCodec.maximumCourseCount).map { index in
            ScheduleExternalCourseSnapshot(
                id: String(index), name: "课程", classroom: "", teacher: "",
                weeks: Array(1...10), weekday: 1, startSection: 1, endSection: 1)
        }
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: base.generatedAt, isLoggedIn: true,
            studentID: base.studentID, firstDayString: base.firstDayString,
            timeTable: base.timeTable, courses: courses)
        let encoded = try ScheduleExternalSnapshotCodec.encode(snapshot)
        #expect(encoded.count <= ScheduleExternalSnapshotCodec.maximumEncodedBytes)
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let first = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let last = try #require(
            ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 9 * 7, to: first))
        let clock = ContinuousClock()
        for now in [first, last] {
            let start = clock.now
            let complete = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
            let limited = ScheduleOccurrenceResolver.resolvedSnapshot(
                from: snapshot, now: now, limit: 50)
            #expect(limited.upcomingOccurrences.count == 50)
            #expect(limited.upcomingOccurrences == Array(complete.upcomingOccurrences.prefix(50)))
            print(
                """
                [性能] 共享课表 \(courses.count) 门课程 · \(encoded.count) 字节 · \
                \(start.duration(to: clock.now))
                """
            )
        }
    }

    private func makeSnapshot() -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_790_553_600),
            isLoggedIn: true,
            studentID: AccountStorageIdentity.stableToken(for: "module-test-account"),
            firstDayString: "2026-09-28",
            timeTable: [ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "08:45")],
            courses: [
                ScheduleExternalCourseSnapshot(
                    id: "course", name: "模块验证课程", classroom: "文萃楼I203", teacher: "教师",
                    weeks: [1], weekday: 1, startSection: 1, endSection: 1
                )
            ]
        )
    }
}
