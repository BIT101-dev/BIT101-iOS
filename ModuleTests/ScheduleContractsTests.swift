import ClientCore
import Foundation
import ScheduleContracts
import Testing

struct ScheduleContractsTests {
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
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext))
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
