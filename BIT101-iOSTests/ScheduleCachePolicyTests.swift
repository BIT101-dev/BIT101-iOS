import ClientCore
import CommunityTransport
import Foundation
import ScheduleContracts
import ScheduleDomain
import SchedulePorts
import ScheduleSharedStore
import StorageCore
import Testing
import UserNotifications

@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure

@Suite("Extended schedule invariants")
struct ExtendedSchedulePolicyTests {
    @Test func deadlineExportKeepsPendingSources() throws {
        var cache = ScheduleCache()
        cache.ddlEvents = [
            .init(
                id: "manual", group: "custom", title: "手动待办", text: "", dueAt: .distantFuture,
                done: false),
            .init(
                id: "lexue", group: "lexue", title: "乐学作业 已到期", text: " 软件工程导论 \n\n详情",
                dueAt: .distantPast, done: false),
            .init(
                id: "eclass", group: "eclass", title: "课程中心作业", text: "课程", dueAt: .distantPast,
                done: false),
            .init(
                id: "done", group: "lexue", title: "已完成", text: "",
                dueAt: .distantPast, done: true),
        ]
        let deadlines = ScheduleWidgetExporter.makeDeadlines(cache: cache, isLoggedIn: true)
        #expect(deadlines.map(\.id) == ["eclass", "lexue", "manual"])
        #expect(deadlines.map(\.sourceTitle) == ["课程中心", "乐学", "自定义"])
        #expect(deadlines[1].title == "乐学作业")
        #expect(deadlines[1].subtitle == "软件工程导论")
        #expect(ScheduleWidgetExporter.makeDeadlines(cache: cache, isLoggedIn: false).isEmpty)
        cache.ddlEvents[1].done = true
        cache.ddlEvents.removeAll { $0.id == "manual" }
        #expect(
            ScheduleWidgetExporter.makeDeadlines(cache: cache, isLoggedIn: true).map(\.id) == [
                "eclass"
            ])
    }

    @Test @MainActor
    func externalSnapshotsIncludeScheduledCourses() throws {
        let scheduled = try ScheduleCourseEditor.adding(
            CourseDraft(title: "已排课程", weeksText: "1"),
            to: [], term: "term", id: "scheduled")
        let pending = CourseRecord(
            id: "pending", term: "term", name: "待排课程", teacher: "", classroom: "",
            description: "", weeks: [], weekday: 0, startSection: 0, endSection: 0, campus: "",
            number: "pending",
            credit: 1, hour: 1, type: "", category: "", department: "")
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(
            TermScheduleSnapshot(
                term: "term", firstDayString: "2026-09-07",
                courses: scheduled + [pending], exams: [], updatedAt: .distantPast))
        let snapshot = try #require(
            ScheduleWidgetExporter.makeSnapshot(
                cache: cache,
                session: AppFileDirectories.currentSession))
        #expect(cache.courses.map(\.id) == ["scheduled", "pending"])
        #expect(snapshot.courses.map(\.id) == ["scheduled"])
        #expect(
            try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(snapshot))
                .courses == snapshot.courses)
    }

    @Test @MainActor
    func externalDeadlineSummariesFields() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(
            TermScheduleSnapshot(
                term: "term", firstDayString: "2026-09-07",
                courses: try ScheduleCourseEditor.adding(
                    CourseDraft(title: "课程", weeksText: "1"), to: [], term: "term", id: "course"),
                exams: [], updatedAt: .distantPast))
        let oversized = String(repeating: "क्‍ष报告", count: 1_000)
        cache.ddlEvents = [
            .init(
                id: "blank", group: "lexue", title: " \n", text: "", dueAt: .distantFuture,
                done: false),
            .init(
                id: "long", group: "eclass", title: oversized, text: oversized + "\n详情",
                dueAt: .distantFuture, done: false),
            .init(
                id: String(
                    repeating: "x", count: ScheduleExternalSnapshotCodec.maximumFieldBytes + 1),
                group: "eclass",
                title: "课程作业", text: "", dueAt: .distantFuture, done: false),
        ]
        let deadlines = ScheduleWidgetExporter.makeDeadlines(cache: cache, isLoggedIn: true)
        #expect(deadlines.map(\.id) == ["blank", "long"])
        #expect(deadlines[0].title == "待办事项")
        #expect(deadlines[1].title.hasSuffix("…") && deadlines[1].subtitle.hasSuffix("…"))
        #expect(deadlines.allSatisfy { $0.hasValidRecord })
        let base = try #require(
            ScheduleWidgetExporter.makeSnapshot(
                cache: cache, session: AppFileDirectories.currentSession))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: base.studentID, firstDayString: base.firstDayString,
            timeTable: base.timeTable, courses: base.courses, deadlines: deadlines)
        let decoded = try ScheduleExternalSnapshotCodec.decode(
            ScheduleExternalSnapshotCodec.encode(snapshot))
        #expect(decoded.courses.map(\.id) == ["course"] && decoded.deadlines == deadlines)
        #expect(cache.ddlEvents[1].title == oversized)
    }

    @Test func delayedWatchDeliveryKeepsNewContent() throws {
        var buffer = WatchSnapshotDeliveryBuffer()
        let old = ScheduleExternalSnapshot(
            revision: 1, isLoggedIn: true, studentID: "watch-owner",
            firstDayString: "2026-01-01", timeTable: [], courses: [])
        let newer = ScheduleExternalSnapshot(
            revision: 2, isLoggedIn: true, studentID: "watch-owner",
            firstDayString: "2026-02-01", timeTable: [], courses: [])
        let empty = ScheduleExternalSnapshot(
            revision: 3, isLoggedIn: false, studentID: "watch-owner",
            firstDayString: "", timeTable: [], courses: [])
        _ = try buffer.accept(old)
        let current = try buffer.accept(newer)
        #expect(try buffer.accept(old) == current)
        let cleared = try buffer.accept(empty)
        #expect(try buffer.accept(newer) == cleared)
        let received = try ScheduleExternalSnapshotCodec.decode(buffer.accept(old))
        #expect(
            received.revision == empty.revision && received.isLoggedIn == false
                && received.firstDayString.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func snapshotClearPublishesRejectsCompletion() async throws {
        var released: CheckedContinuation<Bool, Never>?
        var published: [ScheduleExternalSnapshot] = []
        var generations: [UInt64] = []
        let pending = Task {
            await ScheduleWidgetExporter.clearSharedSnapshot(
                clearSnapshot: { snapshot, generation in
                    generations.append(generation)
                    let cleared = await withCheckedContinuation {
                        released = $0
                    }
                    return (cleared, snapshot)
                }, publishSnapshot: { published.append($0) })
        }
        try await waitForTestEvent { released != nil }
        let cleared = await ScheduleWidgetExporter.clearSharedSnapshot(
            clearSnapshot: { snapshot, generation in
                generations.append(generation)
                return (true, snapshot)
            }, publishSnapshot: { published.append($0) })
        released?.resume(returning: true)
        #expect(await pending.value)
        #expect(cleared && generations.count == 2 && generations[0] < generations[1])
        #expect(
            published.count == 1 && published[0].courses.isEmpty
                && published[0].firstDayString.isEmpty)
        let failed = await ScheduleWidgetExporter.clearSharedSnapshot(
            clearSnapshot: { _, _ in (false, nil) },
            publishSnapshot: { _ in Issue.record("清理失败需要保留外部发布状态") })
        #expect(failed == false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func externalSnapshotWritePreserveSavedSnapshot() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL)
        let writer = ScheduleExternalSnapshotWriteQueue(store: store)
        let old = ScheduleExternalSnapshot(
            revision: 1, isLoggedIn: true, studentID: "snapshot-owner",
            firstDayString: "2026-01-01", timeTable: [], courses: [])
        let changed = ScheduleExternalSnapshot(
            revision: 2, isLoggedIn: true, studentID: "snapshot-owner",
            firstDayString: "2026-02-01", timeTable: [], courses: [])
        _ = try await writer.write(old, generation: 1)
        files.setFailures(writing: true)
        await #expect(throws: CocoaError.self) { try await writer.write(changed, generation: 2) }
        #expect(store.load()?.firstDayString == old.firstDayString)
        files.setFailures()
        #expect(try await writer.write(old, generation: 1) == nil)
        _ = try await writer.write(changed, generation: 3)
        #expect(store.load()?.firstDayString == changed.firstDayString)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
    func watchReplies(watchFirst: Bool) async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL)
        let writer = ScheduleExternalSnapshotWriteQueue(store: store)
        let old = ScheduleExternalSnapshot(
            revision: 1_000, isLoggedIn: true, studentID: "snapshot-owner",
            firstDayString: "2026-01-01", timeTable: [], courses: [])
        let prepared = ScheduleExternalSnapshot(
            revision: 2, isLoggedIn: true, studentID: "snapshot-owner",
            firstDayString: "2026-02-01", timeTable: [], courses: [])
        try store.write(old)
        _ = try #require(try await writer.write(old, generation: 1))
        if watchFirst {
            let reply = try #require(
                await writer.snapshot(for: "snapshot-owner", isLoggedIn: true, knownRevision: 100))
            let saved = try #require(try await writer.write(prepared, generation: 2))
            #expect(saved.revision > reply.revision)
        } else {
            _ = try #require(try await writer.write(prepared, generation: 2))
            let reply = try #require(
                await writer.snapshot(for: "snapshot-owner", isLoggedIn: true, knownRevision: 100))
            #expect(reply.firstDayString == prepared.firstDayString)
        }
        let current = try #require(store.load())
        #expect(
            current.firstDayString == prepared.firstDayString && current.revision > old.revision)
        #expect(
            await writer.snapshot(for: "other-owner", isLoggedIn: true, knownRevision: 100) == nil)
        #expect(
            await writer.snapshot(for: "snapshot-owner", isLoggedIn: false, knownRevision: 100)
                == nil)
        let empty = ScheduleExternalSnapshot(
            isLoggedIn: false, studentID: "snapshot-owner",
            firstDayString: "", timeTable: [], courses: [])
        let cleared = await writer.clear(empty, generation: 3)
        #expect(cleared.didClear && (cleared.snapshot?.revision ?? 0) > current.revision)
        #expect(store.load() == nil)
        #expect(try await writer.write(old, generation: 2) == nil)
    }

    @Test("External schedule exports discard stale accounts and generations")
    func externalSnapshotExportGeneration() {
        let accountA = AppStorageSession(accountIdentifier: "schedule-account-a")
        let accountB = AppStorageSession(accountIdentifier: "schedule-account-b")

        #expect(
            !ScheduleSnapshotExportPolicy.isCurrent(
                capturedSession: accountA,
                currentSession: accountB,
                generation: 4,
                currentGeneration: 4
            ))
        #expect(
            !ScheduleSnapshotExportPolicy.isCurrent(
                capturedSession: accountB,
                currentSession: accountB,
                generation: 3,
                currentGeneration: 4
            ))
        #expect(
            ScheduleSnapshotExportPolicy.isCurrent(
                capturedSession: accountB,
                currentSession: accountB,
                generation: 4,
                currentGeneration: 4
            ))
        #expect(ScheduleSnapshotExportPolicy.acceptsWrite(generation: 4, latestGeneration: 4))
        #expect(!ScheduleSnapshotExportPolicy.acceptsWrite(generation: 3, latestGeneration: 4))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: accountA.accountStorageIdentifier,
            firstDayString: "", timeTable: [], courses: [])
        #expect(
            !ScheduleSnapshotExportPolicy.requiresAccountReset(
                snapshot: snapshot, session: accountA, isLoggedIn: true))
        #expect(
            ScheduleSnapshotExportPolicy.requiresAccountReset(
                snapshot: snapshot, session: accountB, isLoggedIn: true))
        #expect(
            ScheduleSnapshotExportPolicy.requiresAccountReset(
                snapshot: snapshot, session: accountA, isLoggedIn: false))
        #expect(
            !ScheduleSnapshotExportPolicy.requiresAccountReset(
                snapshot: nil, session: accountA, isLoggedIn: true))
    }

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
        let data = Data(
            """
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

    @Test(arguments: ["NaN", "Infinity", "-Infinity", "1e400"])
    func nonFiniteSchoolPreserveEncodableCourses(_ value: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "datas": ["cxxszhxqkb": ["rows": [["KCM": "测试课程", "XF": value]]]]
        ])
        let courses = try JSONDecoder().decode(CourseResponse.self, from: data).courseRecords
        let course = try #require(courses.first)
        #expect(course.credit == 0 && course.creditText == "-" && course.hasValidPlacement)
        #expect(
            try JSONDecoder().decode([CourseRecord].self, from: JSONEncoder().encode(courses))
                == courses)
    }

    @Test("Unchanged source silently reapplies a manual course rule")
    func unchangedSourceReappliesManualRule() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let rule = ScheduleCourseRule(
            sourceIdentity: courseSourceIdentity(original),
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

    @Test("Holiday deletion keeps school snapshots raw and persists a manual rule")
    func holidayDeletionPreservesRawCourses() throws {
        let repeating = course(id: "repeat", number: "MATH-1", weeks: [1, 2, 3], weekday: 2)
        let singleWeek = course(id: "single", number: "ENG-1", weeks: [2], weekday: 2)
        let originals = [repeating, singleWeek]
        let holidayCourses = ScheduleCourseEditor.removingOccurrences(
            from: originals,
            week: 2,
            weekday: 2
        )
        var cache = manualEditCache(with: originals)

        ScheduleCourseEditor.updateCourseEditCache(
            in: &cache,
            previousCourses: originals,
            currentCourses: holidayCourses
        )

        #expect(cache.courses == holidayCourses)
        #expect(cache.courseData.schoolCourses(for: repeating.term) == originals)
        #expect(cache.cachedCoursesByTerm[repeating.term] == originals)
        #expect(cache.termSchedulesByTerm[repeating.term]?.courses == originals)
        #expect(cache.manualCourseRulesByTerm[repeating.term]?.count == 2)
        let restoredHolidayCourses = ScheduleCourseEditor.reconcile(
            rules: cache.manualCourseRulesByTerm[repeating.term] ?? [],
            with: originals
        )
        #expect(Set(restoredHolidayCourses.courses) == Set(holidayCourses))

        let decoded = try JSONDecoder().decode(
            ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(Set(decoded.courses) == Set(holidayCourses))
        #expect(decoded.courseData.schoolCourses(for: repeating.term) == originals)
        #expect(decoded.cachedCoursesByTerm[repeating.term] == originals)
        #expect(decoded.termSchedulesByTerm[repeating.term]?.courses == originals)
    }

    @Test("Day transfer keeps school snapshots raw and persists a manual rule")
    func transferPreservesRawCourses() throws {
        let source = course(id: "source", number: "MATH-1", weeks: [1, 2, 3], weekday: 2)
        let target = course(id: "target", number: "ENG-1", weeks: [2], weekday: 4)
        let originals = [source, target]
        let movedCourses = try ScheduleCourseEditor.transferring(
            courses: originals,
            fromWeek: 2,
            fromWeekday: 2,
            toWeek: 2,
            toWeekday: 4,
            makeID: { "moved" }
        )
        var cache = manualEditCache(with: originals)

        ScheduleCourseEditor.updateCourseEditCache(
            in: &cache,
            previousCourses: originals,
            currentCourses: movedCourses
        )

        #expect(cache.courses == movedCourses)
        #expect(cache.courseData.schoolCourses(for: source.term) == originals)
        #expect(cache.cachedCoursesByTerm[source.term] == originals)
        #expect(cache.termSchedulesByTerm[source.term]?.courses == originals)
        let restoredMovedCourses = ScheduleCourseEditor.reconcile(
            rules: cache.manualCourseRulesByTerm[source.term] ?? [],
            with: originals
        )
        #expect(Set(restoredMovedCourses.courses) == Set(movedCourses))

        let decoded = try JSONDecoder().decode(
            ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(Set(decoded.courses) == Set(movedCourses))
        #expect(decoded.courseData.schoolCourses(for: source.term) == originals)
        #expect(decoded.cachedCoursesByTerm[source.term] == originals)
        #expect(decoded.termSchedulesByTerm[source.term]?.courses == originals)
    }

    @Test("Changes in another course leave this rule active")
    func unrelatedCourseChangeLeavesRuleActive() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let other = course(id: "other", number: "ENG-1", weeks: [1, 2, 3])
        let changedOther = course(id: "other", number: "ENG-1", weeks: [4, 5], weekday: 4)
        let rule = ScheduleCourseRule(
            sourceIdentity: courseSourceIdentity(original),
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
            sourceIdentity: courseSourceIdentity(original),
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
        cache.courseData.store(
            TermScheduleSnapshot(
                term: original.term, firstDayString: "",
                courses: [original], exams: [], updatedAt: .distantPast))
        cache.manualCourseRulesByTerm[original.term] = [
            ScheduleCourseRule(
                sourceIdentity: courseSourceIdentity(original),
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
        #expect(decoded.courseData.schoolCourses(for: original.term) == [original])
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
        #expect(ScheduleWeekCodec.formatWeeks([5, 3, 2, 1, 3]) == "1-3,5")
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

        let result = try ScheduleCourseEditor.updatingArrangements(
            [(firstPart.id, draft)], in: [firstPart, secondPart]
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

        let result = ScheduleCourseEditor.deleting(
            id: firstPart.id, from: [firstPart, secondPart, other])

        #expect(result.map(\.id) == ["other"])
    }

    @Test("Arrangement editing keeps other time arrangements")
    func arrangementEditingKeepsOtherTimes() throws {
        let monday = course(id: "monday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 3)
        let thursday = course(id: "thursday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 4)
        let friday = course(id: "friday", number: "SOFT-1", weeks: [4, 5], weekday: 5)
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-3")
        draft.weekday = 6

        let result = try ScheduleCourseEditor.updatingArrangements(
            [(monday.id, draft)], in: [monday, thursday, friday]
        )

        #expect(result.count == 3)
        #expect(result.first(where: { $0.id == monday.id })?.weekday == 6)
        #expect(result.first(where: { $0.id == thursday.id })?.weekday == 4)
        #expect(result.first(where: { $0.id == friday.id })?.weekday == 5)
    }

    @Test("Different locations create independent arrangements")
    func arrangementEditingSeparatesLocations() throws {
        let literary = course(
            id: "literary", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "文萃楼F404")
        let comprehensive = course(
            id: "comprehensive", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "综教A101")
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-2")
        draft.classroom = "文萃楼F405"

        let result = try ScheduleCourseEditor.updatingArrangements(
            [(literary.id, draft)], in: [literary, comprehensive]
        )

        #expect(result.first(where: { $0.id == literary.id })?.classroom == "文萃楼F405")
        #expect(result.first(where: { $0.id == comprehensive.id })?.classroom == "综教A101")
    }

    @Test("Deleting the last occurrence removes the course")
    func deletingLastOccurrenceRemovesCourse() {
        let original = course(id: "course", number: "MATH-1", weeks: [2])

        #expect(
            ScheduleCourseEditor.deletingOccurrence(id: original.id, week: 2, from: [original])
                .isEmpty)
    }

    @Test("Transferring a day clears source and target occurrences")
    func transferringCourses() throws {
        let source = course(id: "source", number: "MATH-1", weeks: [2], weekday: 1)
        let target = course(id: "target", number: "ENG-1", weeks: [3], weekday: 5)

        let result = try ScheduleCourseEditor.transferring(
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
        let manual = DDLEventRecord(
            id: "manual", group: "main", title: "手动", text: "", dueAt: newDate, done: true)
        let synced = DDLEventRecord(
            id: "synced", group: "lexue", title: "乐学", text: "", dueAt: oldDate, done: false)
        let oldSynced = DDLEventRecord(
            id: "old-synced", group: "lexue", title: "旧", text: "",
            dueAt: Date(timeIntervalSince1970: 50), done: true)

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

    private func manualEditCache(with courses: [CourseRecord]) -> ScheduleCache {
        let term = courses[0].term
        var cache = ScheduleCache()
        cache.currentTerm = term
        cache.courseData.store(
            TermScheduleSnapshot(
                term: term,
                firstDayString: "2026-09-07",
                courses: courses,
                exams: [],
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
        return cache
    }
}

@MainActor
struct AppScheduleCacheEffectsTests {
    private final class State {
        let session = AppStorageSession(accountIdentifier: "effects-account")
        var generation = 0
        var identity: CommunitySessionIdentity {
            CommunitySessionIdentity(
                accountIdentifier: session.accountIdentifier, generation: generation)
        }
        var pushes = 0
        var reconciliations = 0
        var authorizations = 0
        var refreshes: [String] = []
        var changeGenerationDuringAuthorization = false
        var importedCourses: ScheduleCourseSnapshot?
        var importedDrafts: [ScheduleSystemCalendarEventDraft] = []
        var calendarTerm: String?
        var deletedMarkers = Set<String>()
        var deleteAllCount = 0

        func waitForPush() async throws {
            try await waitForTestEvent { pushes > 0 }
        }
    }

    private func effects(_ state: State) -> AppScheduleCacheEffects {
        AppScheduleCacheEffects(
            currentSession: { state.session }, currentIdentity: { state.identity },
            pushCloud: { state.pushes += 1 },
            reconcileCloud: { state.reconciliations += 1 },
            requestReminderAuthorization: {
                state.authorizations += 1
                if state.changeGenerationDuringAuthorization { state.generation += 1 }
            },
            refreshReminder: { state.refreshes.append($0) },
            importCourses: {
                state.importedCourses = $0
                state.calendarTerm = $1
                return 7
            },
            importDrafts: {
                state.importedDrafts = $0
                state.calendarTerm = $1
                return $0.count
            },
            deleteEntries: {
                state.deletedMarkers = $0
                state.calendarTerm = $1
                return .changed($0.count)
            },
            deleteAllEntries: {
                state.deleteAllCount += 1
                return .changed(3)
            },
            rebuildCalendarHistory: { 0 }
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func injectedCloud() async throws {
        let selected = State()
        let surrounding = State()
        let actions = effects(selected)
        let other = AppStorageSession(accountIdentifier: "other-account")
        await actions.didSave(session: other, source: .local, cloudSyncEnabled: true)
        await actions.didSave(session: selected.session, source: .cloud, cloudSyncEnabled: true)
        await actions.didSave(session: selected.session, source: .local, cloudSyncEnabled: false)
        await actions.enableCloudSync(session: other)
        await actions.enableCourseReminder(session: other)
        #expect(
            selected.pushes == 0 && selected.reconciliations == 0 && selected.authorizations == 0)
        await actions.didSave(session: selected.session, source: .local, cloudSyncEnabled: true)
        try await selected.waitForPush()
        await actions.enableCloudSync(session: selected.session)
        await actions.enableCourseReminder(session: selected.session)
        #expect(
            selected.pushes == 1 && selected.reconciliations == 1 && selected.authorizations == 1)
        #expect(selected.refreshes == ["reminder_toggle_enabled"])
        selected.changeGenerationDuringAuthorization = true
        await actions.enableCourseReminder(session: selected.session)
        #expect(selected.authorizations == 2)
        #expect(selected.refreshes.count == 1)
        #expect(
            surrounding.pushes == 0 && surrounding.reconciliations == 0
                && surrounding.authorizations == 0)
    }

    @Test(.timeLimit(.minutes(1))) func calendarActionsUseInjectedBackend() async throws {
        let state = State()
        let actions = effects(state)
        let snapshot = ScheduleCache().courseSnapshot
        #expect(try await actions.importSystemCalendar(courses: snapshot, term: "term") == 7)
        #expect(state.importedCourses == snapshot && state.calendarTerm == "term")
        let content = ScheduleSystemCalendarContent.customSchedule(
            CustomScheduleRecord(
                id: "effects-entry",
                title: "日程", subtitle: "", description: "", dateString: "2026-09-07",
                beginTime: "09:00", endTime: "10:00"))
        #expect(try await actions.importCalendarEntries(content, term: "term") == 1)
        #expect(state.importedDrafts.first?.title == "日程")
        #expect(try await actions.deleteCalendarEntries(content, term: "term") == .changed(1))
        #expect(state.deletedMarkers == Set(state.importedDrafts.map(\.markerID)))
        #expect(
            try await actions.deleteCalendarEntries(
                markerIDs: ["selected-entry"], term: "selected-term") == .changed(1))
        #expect(state.deletedMarkers == ["selected-entry"] && state.calendarTerm == "selected-term")
        #expect(try await actions.deleteImportedEvents() == .changed(3))
        #expect(state.deleteAllCount == 1)
    }
}
