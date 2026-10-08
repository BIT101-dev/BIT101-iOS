import Combine
import BIT101TestSupport
import ScoreDomain
import ScoreInfrastructure
import TransportCore
import CommunityCore
@testable import DesignSystemKit
import ClientCore
import StorageCore
import Foundation
import os
import Testing
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct ScoreFeatureTests {
    @Test(arguments: [("", false), ("1", false), ("123", false), ("1234", true),
                      ("12345678", true), ("123456789", false), ("12a34", false), (" 1234\n", false)])
    func sharedVerificationCodeValidation(_ sample: (String, Bool)) {
        #expect(AppVerificationCode.isValid(sample.0) == sample.1)
    }

    @Test(arguments: [("", ""), ("1234", "1234"), ("12a 34\n", "1234"),
                      ("1234567890", "12345678"), ("a1b2c3d4e5f6g7h8i9", "12345678")])
    func sharedVerificationCodeNormalization(_ sample: (String, String)) {
        let normalized = AppVerificationCode.normalize(sample.0)
        #expect(normalized == sample.1)
        #expect(AppVerificationCode.normalize(normalized) == normalized)
    }

    @Test(arguments: [("", "", false), ("1", "1234", false), ("6", "123456", false),
                      ("123", "123", false), ("1234", "1234", true), ("123456", "123456", true),
                      ("12345678", "12345678", true), ("12 34-56", "123456", true),
                      ("123456789", "12345678", false), ("1234", "12341234", false)])
    func sharedVerificationAutomaticSubmission(_ sample: (String, String, Bool)) {
        #expect(AppVerificationCode.shouldSubmitAutomatically(insertedText: sample.0, code: sample.1) == sample.2)
    }

    private func clearPreferences() {
        UserDefaults(suiteName: "BIT101ModulesTests.score")?.removePersistentDomain(forName: "BIT101ModulesTests.score")
    }

    private func makeViewModel(
        service: any ScoreListServicing,
        session: @escaping @MainActor () -> AppStorageSession = { AppStorageSession(accountIdentifier: "module-score") }
    ) throws -> (ScoreViewModel, ScoreCacheStore) {
        clearPreferences()
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/module-score"), defaults: defaults,
            session: session
        )
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: session)
        let viewModel = ScoreViewModel(
            service: service, cacheStore: cache, preferenceStore: preferences, currentScoreCacheSession: session,
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] }
        )
        return (viewModel, cache)
    }

    @Test func localSaveSubscriptionsFanOutAndCancelByOwner() async throws {
        let (_, cache) = try makeViewModel(service: ScoreServiceSpy(requiresSMS: false))
        var first: [AppStorageSession] = []
        var second: [AppStorageSession] = []
        let firstSubscription = cache.localSaves.sink { first.append($0) }
        let secondSubscription = cache.localSaves.sink { second.append($0) }
        #expect(await cache.save(rows: []) != nil)
        #expect(first == second)
        #expect(first.count == 1)
        firstSubscription.cancel()
        #expect(await cache.save(rows: []) != nil)
        #expect(first.count == 1)
        #expect(second.count == 2)
        withExtendedLifetime(secondSubscription) {}
    }

    @Test func preferenceStreamsKeepInstancesScoped() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score.scopes"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.scopes") }
        let session = AppStorageSession(accountIdentifier: "same-account")
        let firstStore = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        let secondStore = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        func model(_ preferences: ScoreFilterPreferenceStore) -> ScoreViewModel {
            ScoreViewModel(service: ScoreServiceSpy(requiresSMS: false),
                cacheStore: ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/module-score"), defaults: defaults, session: { session }),
                preferenceStore: preferences, currentScoreCacheSession: { session },
                scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        }
        let first = model(firstStore)
        let second = model(secondStore)
        firstStore.applySynced(.init(sortIndex: "score", sortOrder: "descending"))
        #expect(first.sortIndex == .score)
        #expect(second.sortIndex == .courseName)
        secondStore.applySynced(.init(sortIndex: "term", sortOrder: "ascending"))
        #expect(second.sortIndex == .term)
        #expect(first.sortIndex == .score)
        firstStore.save(selectedTerms: [], selectedCourseTypes: [], sortIndex: .courseName, sortOrder: .ascending)
        #expect(first.sortIndex == .courseName)
        #expect(second.sortIndex == .term)
    }

    @Test func accountSwitchRestoresIndependentSortingAndDefaults() async throws {
        let domain = "BIT101ModulesTests.score.account-sorting"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let owner = ScoreCacheSessionHolder(session: AppStorageSession(accountIdentifier: "A"))
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { owner.session })
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-sorting"),
            defaults: defaults, session: { owner.session })
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期"], values: ["功能验收", "95", "验收学期"])]
        _ = await cache.saveDetailed(rows: rows)
        preferences.save(selectedTerms: ["验收学期"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        owner.session = AppStorageSession(accountIdentifier: "B")
        _ = await cache.saveDetailed(rows: rows)
        preferences.save(selectedTerms: ["验收学期"], selectedCourseTypes: [], sortIndex: .term, sortOrder: .descending)
        owner.session = AppStorageSession(accountIdentifier: "A")
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { owner.session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded()
        for account in ["B", "C", "A"] {
            owner.session = AppStorageSession(accountIdentifier: account)
            model.resetForCurrentAccount()
            await model.restoreCachedDataIfNeeded()
            #expect(model.sortIndex == (account == "A" ? .score : account == "B" ? .term : .courseName))
            #expect(model.sortOrder == (account == "C" ? .ascending : .descending))
            if account != "C" { #expect(preferences.load()?.sortIndex == model.sortIndex.rawValue) }
        }
    }

    @Test func pendingCourseCoverageRequiresEverySelectedTerm() async throws {
        let domain = "BIT101ModulesTests.score.term-coverage"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "coverage")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-coverage"),
            defaults: defaults, session: { session })
        let rows = ["A", "B"].enumerated().map { index, term in
            ScoreRow(index: index, headers: ["课程名称", "成绩", "开课学期"], values: ["功能验收", "95", term])
        }
        _ = await cache.saveDetailed(rows: rows)
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        preferences.save(selectedTerms: ["A", "B"], selectedCourseTypes: [], sortIndex: .courseName, sortOrder: .ascending)
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["A": []] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.pendingCourseCount == nil)
        model.setSelectedTerms(["A"])
        #expect(model.pendingCourseCount == 0)
        model.setSelectedTerms(["B"])
        #expect(model.pendingCourseCount == nil)
    }

    @Test(arguments: ["distinct", "score-missing", "schedule-missing"])
    func pendingCoursesPreferTheirNumbersAndUseNamesForMissingNumbers(_ scenario: String) async throws {
        let domain = "BIT101ModulesTests.score.course-identity"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "identity")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-identity"), defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "课程编号", "成绩", "开课学期"], values: ["功能验收", scenario == "score-missing" ? "" : "B", "95", "A"])]
        _ = await cache.saveDetailed(rows: rows)
        let course = ScoreCourseSummary(id: "A", term: "A", name: "功能验收", number: scenario == "schedule-missing" ? "" : "A", type: "", teacher: "", classroom: "", campus: "", description: "", creditText: "", scheduleText: "", weeksText: "", hourText: "")
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in ["A": [course]] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.pendingCourseCount == (scenario == "distinct" ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func entirelyPendingTermsRemainSelectableWithAnEmptyOrOlderScoreCache(hasEarlierScores: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score.pending-term"))
        defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.pending-term")
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.pending-term") }
        let session = AppStorageSession(accountIdentifier: "pending-term")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/pending-term"), defaults: defaults, session: { session })
        if hasEarlierScores {
            _ = await cache.saveDetailed(rows: [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期"], values: ["已出分课程", "95", "旧学期"])])
        }
        let pending = ScoreCourseSummary(id: "pending", term: "新学期", name: "功能验收", number: "A", type: "", teacher: "", classroom: "", campus: "", description: "", creditText: "", scheduleText: "", weeksText: "", hourText: "")
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in ["新学期": [pending]] })
        await model.restoreCachedDataIfNeeded()
        #expect(Set(model.availableTerms) == (hasEarlierScores ? ["新学期", "旧学期"] : ["新学期"]))
        #expect(model.selectedTerms == Set(model.availableTerms))
        model.setSelectedTerms(["新学期"])
        #expect(model.pendingCourses?.map(\.id) == ["pending"] && model.pendingCourseCount == 1)
        model.setSelectedTerms([])
        #expect(model.pendingCourseCount == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func laterScheduleReadsRetainTheirTermCatalogWhenEarlierReadsFinishLast() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score.schedule-reads"))
        defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.schedule-reads")
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.schedule-reads") }
        let session = AppStorageSession(accountIdentifier: "schedule-reads")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/schedule-reads"), defaults: defaults, session: { session })
        var reads: [CheckedContinuation<[String: [ScoreCourseSummary]], Never>] = []
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }), currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in
                await withCheckedContinuation { reads.append($0) }
            })
        func course(_ id: String, term: String) -> ScoreCourseSummary {
            .init(id: id, term: term, name: id, number: id, type: "", teacher: "", classroom: "", campus: "", description: "",
                creditText: "", scheduleText: "", weeksText: "", hourText: "")
        }
        let first = Task { await model.restoreCachedDataIfNeeded() }
        while reads.count < 1 { await Task.yield() }
        let second = Task { await model.restoreCachedDataIfNeeded() }
        while reads.count < 2 { await Task.yield() }
        reads[1].resume(returning: ["新学期": [course("new-1", term: "新学期"), course("new-2", term: "新学期")]])
        await second.value
        #expect(model.availableTerms == ["新学期"] && model.pendingCourseCount == 2)
        reads[0].resume(returning: ["旧学期": [course("old", term: "旧学期")]])
        await first.value
        #expect(model.availableTerms == ["新学期"] && model.selectedTerms == ["新学期"] && model.pendingCourseCount == 2)
    }

    private final class SuspendedSnapshotCache: ScoreCaching {
        let events = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { events.eraseToAnyPublisher() }
        var snapshot: ScoreCacheSnapshot
        var suspendRead = false
        var pending: CheckedContinuation<ScoreCacheSnapshot?, Never>?
        init(rows: [ScoreRow]) { snapshot = .init(rows: rows, updatedAt: Date(timeIntervalSince1970: 100)) }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            if suspendRead {
                suspendRead = false
                return await withCheckedContinuation { pending = $0 }
            }
            return snapshot
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? {
            let date = Date(timeIntervalSince1970: 200)
            snapshot = .init(rows: rows, updatedAt: date, detailedUpdatedAt: date)
            return date
        }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { await save(rows: rows, for: session) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func delayedCacheReadsPreserveANewerRefresh(cloudRead: Bool) async throws {
        let domain = "BIT101ModulesTests.score.delayed-cache"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "delayed-cache")
        let old = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["功能验收", "80"])]
        let fresh = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["功能验收", "95"])]
        let cache = SuspendedSnapshotCache(rows: old)
        let model = ScoreViewModel(service: ScoreServiceSpy(detailedRows: fresh), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        if cloudRead { await model.restoreCachedDataIfNeeded() }
        let previous = cache.snapshot
        cache.suspendRead = true
        let reading = Task {
            if cloudRead { await model.applySyncedScoreCacheIfAvailable() }
            else { await model.restoreCachedDataIfNeeded() }
        }
        while cache.pending == nil { await Task.yield() }
        await model.refresh()
        cache.pending?.resume(returning: previous)
        await reading.value
        #expect(ScoreRowComparison.rowsMatch(model.rows, fresh))
        #expect(model.lastUpdatedAt == Date(timeIntervalSince1970: 200))
        cache.snapshot = .init(rows: [], updatedAt: Date(timeIntervalSince1970: 300))
        await model.applySyncedScoreCacheIfAvailable()
        #expect(model.rows.isEmpty)
        #expect(model.lastUpdatedAt == Date(timeIntervalSince1970: 300))
    }

    private final class ScoreServiceSpy: ScoreListServicing {
        private(set) var requestedDetailValues: [Bool] = []
        private let requiresSMS: Bool
        private let detailedRowsOverride: [ScoreRow]?

        init(requiresSMS: Bool = false, detailedRows: [ScoreRow]? = nil) {
            self.requiresSMS = requiresSMS
            detailedRowsOverride = detailedRows
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
            detailedRowsOverride ?? [ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"]
            )]
        }
    }

    @MainActor
    private final class ScoreCacheSessionHolder {
        var session: AppStorageSession

        init(session: AppStorageSession) {
            self.session = session
        }
    }

    @MainActor
    private final class DelayedScoreServiceSpy: ScoreListServicing {
        private var challengeContinuation: CheckedContinuation<BITLoginAuthenticationChallenge, Error>?
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private(set) var fetchCount = 0

        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            hasStarted = true
            startContinuation?.resume()
            startContinuation = nil
            return try await withCheckedThrowingContinuation { continuation in
                challengeContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }

        func completeStart(with challenge: BITLoginAuthenticationChallenge) {
            challengeContinuation?.resume(returning: challenge)
            challengeContinuation = nil
        }

        func fetchScores(
            detail: Bool,
            authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] {
            fetchCount += 1
            return []
        }

        func submitScoreSMSCode(
            _ code: String,
            for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge {
            challenge
        }
    }

    @Test("Score refresh requests fields required by the detail UI")
    @MainActor
    func scoreRefreshRequestsDetailedRows() async throws {
        let service = ScoreServiceSpy()
        let (viewModel, _) = try makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    private final class CancellableScoreService: ScoreListServicing {
        let stage: String
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private let challenge = BITLoginAuthenticationChallenge(challengeID: "cancel-test", accessToken: "test-token",
            status: "authenticated", maskedPhone: nil, expiresIn: 300)
        init(stage: String) { self.stage = stage }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        private func suspend() async throws {
            try await withTaskCancellationHandler {
                started = true
                waiter?.resume()
                waiter = nil
                try await Task.sleep(for: .seconds(2))
            } onCancel: { [cancelled] in
                cancelled.withLock { $0 = true }
            }
        }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if stage == "authentication" { try await suspend() }
            return challenge
        }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] {
            if stage == (detail ? "details" : "summary") { try await suspend() }
            return []
        }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    private final class RejectingScoreCache: ScoreCaching {
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var writes = 0
        let snapshot: ScoreCacheSnapshot
        init(snapshot: ScoreCacheSnapshot) { self.snapshot = snapshot }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? { snapshot }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { writes += 1; return nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { writes += 1; return nil }
    }

    @Test("Score cache write failure presents a save error and retains downloaded rows")
    func scoreSaveFailureIsPresented() async throws {
        clearPreferences()
        defer { clearPreferences() }
        let session = AppStorageSession(accountIdentifier: "write-failure")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        let rows = [ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
            values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"])]
        let cache = RejectingScoreCache(snapshot: .init(rows: rows, updatedAt: Date(), detailedUpdatedAt: Date()))
        let model = ScoreViewModel(service: ScoreServiceSpy(detailedRows: rows), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.refresh()
        #expect(model.alert?.title == "成绩保存失败")
        #expect(ScoreRowComparison.rowsMatch(model.rows, rows))
        #expect(model.lastUpdatedAt == nil)
        #expect(cache.writes == 1)
        #expect(model.refreshPhase == .idle)
    }

    @Test("Refresh cancellation and account reset immediately cancel every score request",
          arguments: ["authentication", "summary", "details"], [false, true])
    func scoreRequestsCancelImmediately(_ stage: String, _ resetAccount: Bool) async throws {
        let account = ScoreCacheSessionHolder(session: AppStorageSession(accountIdentifier: "cancel-account-a"))
        let oldSession = account.session
        let service = CancellableScoreService(stage: stage)
        let (model, cache) = try makeViewModel(service: service, session: { account.session })
        defer { clearPreferences() }
        let refresh = Task { await model.refresh() }
        await service.waitUntilStarted()
        if resetAccount {
            account.session = AppStorageSession(accountIdentifier: "cancel-account-b")
            model.resetForCurrentAccount()
        } else { refresh.cancel() }
        #expect(service.cancelled.withLock { $0 })
        await refresh.value
        #expect(await cache.loadSnapshot(for: oldSession) == nil)
        #expect(model.rows.isEmpty)
        #expect(model.refreshPhase == .idle)
    }

    @Test("Score refresh preserves detailed mode after SMS authentication")
    @MainActor
    func scoreSMSRefreshRequestsDetailedRows() async throws {
        let service = ScoreServiceSpy(requiresSMS: true)
        let (viewModel, _) = try makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()
        #expect(viewModel.refreshPhase == .awaitingVerification)
        #expect(viewModel.isSyncing == false)
        await viewModel.submitSMSCode("123456")
        #expect(viewModel.refreshPhase == .idle)
        #expect(viewModel.isSyncing == false)

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("A delayed score challenge cannot write into the newly selected account")
    @MainActor
    func delayedScoreChallengeIsDiscardedAfterAccountSwitch() async throws {
        let activeSession = ScoreCacheSessionHolder(
            session: AppStorageSession(accountIdentifier: "score-account-a")
        )
        let service = DelayedScoreServiceSpy()
        let (viewModel, _) = try makeViewModel(service: service, session: { activeSession.session })
        defer { clearPreferences() }

        let refreshTask = Task { await viewModel.refresh() }
        await service.waitUntilStarted()

        activeSession.session = AppStorageSession(accountIdentifier: "score-account-b")
        viewModel.resetForCurrentAccount()
        service.completeStart(with: BITLoginAuthenticationChallenge(
            challengeID: "account-a-challenge",
            accessToken: "account-a-token",
            status: "authenticated",
            maskedPhone: nil,
            expiresIn: 300
        ))
        await refreshTask.value

        let fetchCount = service.fetchCount
        #expect(fetchCount == 0)
        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.smsChallenge == nil)
        #expect(!viewModel.isSyncing)
    }

    @Test("Unchanged score refresh presents the latest-state notice")
    @MainActor
    func unchangedScoreRefreshPresentsNotice() async throws {
        let rows = [ScoreRow(
            index: 0,
            headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
            values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"]
        )]
        let service = ScoreServiceSpy(detailedRows: rows)
        let (viewModel, cache) = try makeViewModel(service: service)
        await cache.saveDetailed(rows: rows)
        defer { clearPreferences() }
        await viewModel.refresh()

        #expect(viewModel.alert?.title == "成绩已是最新")
        #expect(viewModel.alert?.message == "本次获取结果与本地成绩完全一致。")
        await cache.save(rows: [])
    }

    @Test("Qualitative scores use their numeric ordering")
    func qualitativeScoresUseNumericOrdering() throws {
        let excellent = makeRow(index: 0, score: "优秀")
        let pass = makeRow(index: 1, score: "及格")

        #expect(ScoreSortIndex.score.compare(excellent, pass) == .orderedDescending)
        #expect(!ScoreSortIndex.score.isMissingValue(in: excellent))
    }

    @Test("Missing values are identified independently from sort direction")
    func missingValuesAreIdentified() throws {
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
