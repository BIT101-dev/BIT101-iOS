import ScheduleSync
import ClientCore
import StorageCore
import SchedulePersistence
@testable import GalleryFeature
@testable import PaperFeature
@testable import ScheduleFeature
import ScheduleDomain
import CommunityCore
import CommunityTransport
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Schedule cache migration and reconciliation")
struct ScheduleCacheMigrationTests {
    private struct LegacyCache: Encodable {
        let primaryScheduleTitle: String
        let currentTerm: String
        let courses: [CourseRecord]
        let updatedAt: Date
    }

    @Test("Legacy single-term caches migrate without losing courses or timestamps")
    func legacyCacheMigration() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let course = makeCourse(id: "course-1", term: "2025-2026-1")
        let legacy = LegacyCache(
            primaryScheduleTitle: "  一份名字很长的课表  ",
            currentTerm: course.term,
            courses: [course],
            updatedAt: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(legacy))

        #expect(decoded.courses == [course])
        #expect(decoded.manualFirstDayStringsByTerm.isEmpty)
        #expect(decoded.cachedCoursesByTerm[course.term] == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.updatedAt == timestamp)
        #expect(decoded.coursesUpdatedAt == timestamp)
        #expect(decoded.primaryScheduleTitle.count == scheduleNameCharacterLimit)
        #expect(decoded.iCloudSyncEnabled)
        #expect(decoded.cloudSyncBaselineAt == .distantPast)
        #expect(!decoded.hasUnpushedCloudChanges)
    }

    @Test("Unreadable cache data is kept out of the save path")
    func corruptCacheBlocksReplacement() throws {
        let unreadable = ScheduleCacheStore.decodeCache(Data("invalid cache".utf8))

        #expect(unreadable.isUnreadable)
        #expect(!unreadable.allowsWrite)
        #expect(ScheduleCacheLoadResult.missing.allowsWrite)

        let cache = ScheduleCache()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let readable = ScheduleCacheStore.decodeCache(try encoder.encode(cache))

        #expect(!readable.isUnreadable)
        #expect(readable.allowsWrite)
    }

    @Test("Legacy cache migration preserves row-specific negative weeks")
    func rowSpecificNegativeWeeksSurviveCacheDecoding() throws {
        let course = CourseRecord(
            id: "negative-row",
            term: "2026-2027-1",
            name: "文献检索",
            teacher: "",
            classroom: "文萃楼M227",
            description: "-2周 星期二 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227",
            weeks: [-1],
            weekday: 4,
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object: [String: Any] = [
            "storedCourseScheduleParserVersion": 1,
            "currentTerm": course.term,
            "firstDayString": "2026-08-31",
            "courses": try JSONSerialization.jsonObject(with: encoder.encode([course]))
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.courses.first?.weeks == [-1])
        #expect(decoded.cachedCoursesByTerm[course.term]?.first?.weeks == [-1])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses.first?.weeks == [-1])
    }

    @Test("DDL sync timestamp survives cache encoding")
    func ddlUpdatedAtRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        var cache = ScheduleCache()
        cache.ddlUpdatedAt = timestamp
        cache.cloudSyncBaselineAt = timestamp
        cache.cloudSyncBaselineRecordTag = "record-v3"
        cache.hasUnpushedCloudChanges = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(cache))
        #expect(decoded.ddlUpdatedAt == timestamp)
        #expect(decoded.cloudSyncBaselineAt == timestamp)
        #expect(decoded.cloudSyncBaselineRecordTag == "record-v3")
        #expect(decoded.hasUnpushedCloudChanges)
    }

    @Test("Reconciliation uses user edits and known cloud baselines")
    func reconciliationPolicy() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        for localTime in [old, new] {
            #expect(ScheduleCacheReconciliationPolicy.decision(
                localHasUnpushedChanges: false, localUpdatedAt: localTime,
                remoteUpdatedAt: old, allowsRemoteApply: true
            ) == .applyRemote)
            #expect(ScheduleCacheReconciliationPolicy.decision(
                localHasUnpushedChanges: false, localUpdatedAt: localTime,
                remoteUpdatedAt: old, allowsRemoteApply: false
            ) == .noChange)
        }

        #expect(ScheduleCacheReconciliationPolicy.decision(
            localHasUnpushedChanges: true,
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .applyRemote)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localHasUnpushedChanges: true,
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: true
        ) == .uploadLocal)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localHasUnpushedChanges: true,
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: false
        ) == .uploadLocal)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localHasUnpushedChanges: true,
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: false
        ) == .noChange)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localHasUnpushedChanges: true,
            localUpdatedAt: new,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .noChange)
        #expect(!ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: false,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v2"
        ))
        #expect(!ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v1"
        ))
        #expect(ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v2"
        ))
        #expect(ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: ""
        ))
        #expect(ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "",
            remoteRecordTag: "record-v2"
        ))
    }

    @Test("Cloud state comparison tracks user content across school refreshes")
    func cloudStateComparison() throws {
        let original = ScheduleCache()
        var refreshed = original
        refreshed.currentTerm = "2026-2027-1"
        refreshed.courseData.store(TermScheduleSnapshot(term: refreshed.currentTerm, firstDayString: "",
            courses: [], exams: [], updatedAt: Date()))
        refreshed.updatedAt = Date()
        refreshed.cloudSyncBaselineAt = Date()
        refreshed.cloudSyncBaselineRecordTag = "confirmed-record"
        refreshed.hasUnpushedCloudChanges = true
        #expect(try ScheduleCloudSyncState.matches(original, refreshed))

        refreshed.showSunday.toggle()
        #expect(try ScheduleCloudSyncState.matches(original, refreshed) == false)
    }

    @Test("Local cache timestamps advance when the device clock moves backward")
    func cacheTimestampRemainsMonotonic() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let movedBackward = Date(timeIntervalSince1970: 1_600_000_000)
        let advanced = ScheduleCacheTimestamp.next(after: previous, now: movedBackward)

        #expect(advanced > previous)
        #expect(advanced.timeIntervalSince(previous) >= 0.001)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous.addingTimeInterval(10))
            == previous.addingTimeInterval(10))

        let preciseRecordDate = Date(timeIntervalSince1970: 1_700_000_000.123)
        let roundedPayloadDate = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate,
            payloadDate: roundedPayloadDate
        ) == preciseRecordDate)
        let serverDate = preciseRecordDate.addingTimeInterval(3)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate,
            payloadDate: roundedPayloadDate,
            serverDate: serverDate
        ) == serverDate)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate.addingTimeInterval(2),
            payloadDate: roundedPayloadDate
        ) == nil)
    }

    private func makeCourse(id: String, term: String) -> CourseRecord {
        CourseRecord(
            id: id,
            term: term,
            name: "高等数学",
            teacher: "张老师",
            classroom: "理教201",
            description: "",
            weeks: [1, 2],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "良乡",
            number: "MATH-1",
            credit: 4,
            hour: 64,
            type: "必修",
            category: "公共课",
            department: "数学学院"
        )
    }
}

@Suite("Free-classroom request lifecycle")
@MainActor
struct ScheduleClassroomCoordinatorTests {
    private actor CancellationProbe {
        private var didObserveCancellation = false
        private var startedDeadline = false
        func beginDeadline() { startedDeadline = true }
        func deadlineStarted() -> Bool { startedDeadline }

        func recordCancellation() {
            didObserveCancellation = true
        }

        func observedCancellation() -> Bool {
            didObserveCancellation
        }
    }

    @Test("Only the newest request can finish shared loading state")
    func staleRequestsCannotFinish() {
        let coordinator = ScheduleClassroomCoordinator()
        let first = coordinator.beginRequest(hasVisibleResults: false)
        let second = coordinator.beginRequest(hasVisibleResults: false)

        #expect(first.shouldShowInitialSpinner)
        #expect(second.shouldShowInitialSpinner)
        #expect(!coordinator.finish(first.id))
        #expect(coordinator.isRequestInFlight)
        #expect(coordinator.finish(second.id))
        #expect(!coordinator.isRequestInFlight)
    }

    @Test("Authentication time is outside the classroom request deadline", .timeLimit(.minutes(1)))
    func authenticationUsesIndependentDeadline() async throws {
        let probe = CancellationProbe()
        let coordinator = ScheduleClassroomCoordinator(waitForDeadline: { _ in
            await probe.beginDeadline()
            try await Task.sleep(for: .seconds(30))
        })
        let value = try await coordinator.withAuthenticationThenTimeout {
            #expect(await probe.deadlineStarted() == false)
            await Task.yield()
            #expect(await probe.deadlineStarted() == false)
        } operation: { 42 }

        #expect(value == 42)
    }

    @Test("Classroom operation timeout remains enforced after authentication", .timeLimit(.minutes(1)))
    func operationTimeoutIsEnforced() async {
        let coordinator = ScheduleClassroomCoordinator(timeoutNanoseconds: 5_000_000)
        let cancellationProbe = CancellationProbe()

        do {
            _ = try await coordinator.withAuthenticationThenTimeout {
            } operation: {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    await cancellationProbe.recordCancellation()
                    throw CancellationError()
                }
                return 42
            }
            Issue.record("空教室请求超时契约失败")
        } catch is ClassroomRequestTimeoutError {
            #expect(await cancellationProbe.observedCancellation())
        } catch {
            Issue.record("空教室请求错误：\(error)")
        }
    }
}

@Suite("Schedule authentication continuation")
@MainActor
struct ScheduleCourseSyncCoordinatorTests {
    private func context() -> (ScheduleCourseSyncCoordinator, SemesterStartDateService, BITLoginAuthenticationChallenge) {
        let service = SemesterStartDateService()
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "continuation") },
            load: { _ in .missing }, save: { _, _, _ in })
        let challenge = BITLoginAuthenticationChallenge(challengeID: "continuation", accessToken: "token",
            status: "waiting_sms", maskedPhone: "138****0000", expiresIn: 300)
        return (ScheduleCourseSyncCoordinator(service: service, repository: repository, virtualNetworkLikely: { false }), service, challenge)
    }

    @Test("Classroom SMS authentication keeps the selected challenge")
    func classroomAuthenticationContinuation() {
        let (coordinator, _, challenge) = context()
        coordinator.waitForClassroomAuthentication(challenge)
        #expect(coordinator.continuation == .classroomRefresh)
        #expect(coordinator.smsChallenge?.challengeID == challenge.challengeID)
        #expect(coordinator.courseSyncTerm == nil)
        coordinator.dismissSMSChallenge()
        #expect(coordinator.smsChallenge == nil)
    }

    @Test("Service responses select the suspended operation and block overlapping requests", .timeLimit(.minutes(1)))
    func recordsContinuationPurpose() async {
        let (coordinator, service, challenge) = context()
        service.authenticationChallenge = challenge
        await coordinator.syncCourses(term: "2025-2026-2", selectTerm: { _ in }, applyPayload: { _ in })
        #expect(coordinator.continuation == .courseSync(term: "2025-2026-2"))
        await coordinator.loadAvailableTerms()
        #expect(coordinator.courseSyncTerm == "2025-2026-2")
        coordinator.dismissSMSChallenge()
        await coordinator.loadAvailableTerms()
        #expect(coordinator.continuation == .availableTerms)
        #expect(coordinator.courseSyncTerm == nil)
        coordinator.reset()
        #expect(coordinator.continuation == nil)
    }
}
