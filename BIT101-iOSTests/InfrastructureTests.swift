import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Login bootstrap behavior")
struct LoginBootstrapTests {
    private final class LoginServiceStub: LoginServicing {
        enum CheckResult {
            case signedIn(String)
            case signedOut
            case failed
        }

        let savedStudentID: String
        let savedPassword = "saved-password"
        let hasCachedSession: Bool
        let checkResult: CheckResult

        init(
            studentID: String = "1120260001",
            hasCachedSession: Bool = true,
            checkResult: CheckResult
        ) {
            savedStudentID = studentID
            self.hasCachedSession = hasCachedSession
            self.checkResult = checkResult
        }

        func checkLogin() async throws -> String? {
            switch checkResult {
            case let .signedIn(studentID): studentID
            case .signedOut: nil
            case .failed: throw URLError(.notConnectedToInternet)
            }
        }

        func login(studentID: String, password: String) async throws -> String { studentID }
        func logout() {}
    }

    @Test("Cached sessions show the app shell before network validation")
    func cachedSessionIsOptimistic() {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
    }

    @Test("Transient validation failures stay silent and signed in")
    func transientFailureKeepsSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
        #expect(viewModel.alert == nil)
    }

    @Test("Only an explicit signed-out response dismisses the app shell")
    func explicitSignOutDismissesSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .signedOut))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedOut)
    }
}

@Suite("Shared infrastructure")
struct InfrastructureTests {
    private struct TestItem: Identifiable, Equatable {
        let id: Int
    }

    private struct TestPagedState: PagedItemsState {
        var items: [TestItem] = []
        var nextPage = 0
        var isLoadingMore = false
        var canLoadMore = true
    }

    @Test("Cancellation signals are normalized")
    func cancellationSignalsAreNormalized() {
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(!TaskCancellation.matches(URLError(.timedOut)))
    }

    @Test("Codable snapshots are isolated by account")
    func codableSnapshotsAreIsolatedByAccount() throws {
        let suiteName = "AccountScopedCodableStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var account = "student-a"
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            defaults: defaults,
            accountIdentifier: { account }
        )

        store.save(["A"])
        #expect(store.load() == ["A"])

        account = "student-b"
        #expect(store.load() == nil)
        store.save(["B"])
        #expect(store.load() == ["B"])

        account = "student-a"
        #expect(store.load() == ["A"])
    }

    @Test("Blank accounts use the guest namespace")
    func blankAccountsUseGuestNamespace() {
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            accountIdentifier: { "  " }
        )

        #expect(store.storageKey == "test.snapshot.guest")
    }

    @Test("Paged state advances and stops on an empty page")
    func pagedStateAdvancesAndStops() {
        var state = TestPagedState()

        state.applyFirstPage([TestItem(id: 1), TestItem(id: 2)])
        #expect(state.nextPage == 1)
        #expect(state.shouldLoadMore(currentID: 2))

        state.isLoadingMore = true
        #expect(!state.shouldLoadMore(currentID: 2))

        state.appendPage([])
        #expect(state.nextPage == 2)
        #expect(!state.canLoadMore)

        state.resetPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextPage == 0)
        #expect(state.canLoadMore)
    }
}

@Suite("Score presentation logic")
struct ScorePresentationTests {
    private final class ScoreServiceSpy: ScoreListServicing {
        private(set) var requestedDetailValues: [Bool] = []
        private let requiresSMS: Bool

        init(requiresSMS: Bool = false) {
            self.requiresSMS = requiresSMS
        }

        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if requiresSMS {
                throw ScoreServiceError.secondFactorRequired(BITLoginAuthenticationChallenge(
                    challengeID: "challenge-1",
                    accessToken: "token-1",
                    status: "waiting_sms",
                    maskedPhone: "138****0000",
                    expiresIn: 300
                ))
            }
            return authenticatedChallenge
        }

        func fetchScores(
            detail: Bool,
            authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] {
            requestedDetailValues.append(detail)
            return detail ? detailedRows : briefRows
        }

        func submitScoreSMSCode(
            _ code: String,
            for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge {
            authenticatedChallenge
        }

        private var authenticatedChallenge: BITLoginAuthenticationChallenge {
            BITLoginAuthenticationChallenge(
                challengeID: "challenge-1",
                accessToken: "token-1",
                status: "authenticated",
                maskedPhone: nil,
                expiresIn: 1_800
            )
        }

        private var briefRows: [ScoreRow] {
            [ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "4", "2025-2026-1", "必修"]
            )]
        }

        private var detailedRows: [ScoreRow] {
            [ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"]
            )]
        }
    }

    @Test("Score refresh requests fields required by the detail UI")
    @MainActor
    func scoreRefreshRequestsDetailedRows() async {
        let service = ScoreServiceSpy()
        let viewModel = ScoreViewModel(service: service)

        await viewModel.refresh()

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("Score refresh preserves detailed mode after SMS authentication")
    @MainActor
    func scoreSMSRefreshRequestsDetailedRows() async {
        let service = ScoreServiceSpy(requiresSMS: true)
        let viewModel = ScoreViewModel(service: service)

        await viewModel.refresh()
        await viewModel.submitSMSCode("123456")

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("Qualitative scores use their numeric ordering")
    func qualitativeScoresUseNumericOrdering() {
        let excellent = makeRow(index: 0, score: "优秀")
        let pass = makeRow(index: 1, score: "及格")

        #expect(ScoreSortIndex.score.compare(excellent, pass) == .orderedDescending)
        #expect(!ScoreSortIndex.score.isMissingValue(in: excellent))
    }

    @Test("Missing values are identified independently from sort direction")
    func missingValuesAreIdentified() {
        let missing = makeRow(index: 0, score: "")
        #expect(ScoreSortIndex.score.isMissingValue(in: missing))
        #expect(ScoreSortOrder.ascending.toggled == .descending)
    }

    private func makeRow(index: Int, score: String) -> ScoreRow {
        ScoreRow(
            index: index,
            headers: ["课程编号", "课程名称", "成绩", "学分"],
            values: ["MATH-\(index)", "高等数学", score, "4"]
        )
    }
}

@Suite("External schedule infrastructure")
struct ExternalScheduleInfrastructureTests {
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

        #expect(WatchScheduleTransferProtocol.requestData == Data("request_latest_schedule_snapshot".utf8))
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext))
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
