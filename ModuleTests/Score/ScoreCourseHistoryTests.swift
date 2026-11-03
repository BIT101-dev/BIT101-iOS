import BIT101TestSupport
import ClientCore
import Combine
import CommunityCore
import Foundation
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import StorageCore
import Testing
import TransportCore
import os

@testable import DesignSystemKit
@testable import ScoreFeature

extension ScoreFeatureTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["distinct", "score-missing", "schedule-missing"])
    func coursesPreferTheirUseNamesMissingNumbers(_ scenario: String) async throws {
        let domain = "BIT101ModulesTests.score.course-identity"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "identity")
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-identity"),
            defaults: defaults, session: { session })
        let rows = [
            ScoreRow(
                index: 0, headers: ["课程名称", "课程编号", "成绩", "开课学期"],
                values: ["功能验收", scenario == "score-missing" ? "" : "B", "95", "A"])
        ]
        _ = await cache.saveDetailed(rows: rows)
        let course = ScoreCourseSummary(
            id: "A", term: "A", name: "功能验收", number: scenario == "schedule-missing" ? "" : "A",
            type: "", teacher: "", classroom: "", campus: "", description: "", creditText: "",
            scheduleText: "", weeksText: "", hourText: "")
        let model = ScoreViewModel(
            service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["A": [course]] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.pendingCourseCount == (scenario == "distinct" ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func entirelyTermsRemainCache(hasEarlierScores: Bool) async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "BIT101ModulesTests.score.pending-term"))
        defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.pending-term")
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.pending-term") }
        let session = AppStorageSession(accountIdentifier: "pending-term")
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/pending-term"),
            defaults: defaults, session: { session })
        if hasEarlierScores {
            _ = await cache.saveDetailed(rows: [
                ScoreRow(
                    index: 0, headers: ["课程名称", "成绩", "开课学期"], values: ["已出分课程", "95", "旧学期"])
            ])
        }
        let pending = ScoreCourseSummary(
            id: "pending", term: "新学期", name: "功能验收", number: "A", type: "", teacher: "",
            classroom: "", campus: "", description: "", creditText: "", scheduleText: "",
            weeksText: "", hourText: "")
        let model = ScoreViewModel(
            service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["新学期": [pending]] })
        await model.restoreCachedDataIfNeeded()
        #expect(Set(model.availableTerms) == (hasEarlierScores ? ["新学期", "旧学期"] : ["新学期"]))
        #expect(model.selectedTerms == Set(model.availableTerms))
        model.setSelectedTerms(["新学期"])
        #expect(model.pendingCourses?.map(\.id) == ["pending"] && model.pendingCourseCount == 1)
        model.setSelectedTerms([])
        #expect(model.pendingCourseCount == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func laterScheduleReadsRetainTheirTermCatalog() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "BIT101ModulesTests.score.schedule-reads"))
        defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.schedule-reads")
        defer {
            defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.schedule-reads")
        }
        let session = AppStorageSession(accountIdentifier: "schedule-reads")
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/schedule-reads"),
            defaults: defaults, session: { session })
        @MainActor final class Reads {
            var pending: [CheckedContinuation<[String: [ScoreCourseSummary]], Never>?] = []
            var suspended = true
        }
        let reads = Reads()
        defer {
            reads.suspended = false
            reads.pending.forEach { $0?.resume(returning: [:]) }
        }
        let model = ScoreViewModel(
            service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in
                guard reads.suspended else { return [:] }
                return await withCheckedContinuation { reads.pending.append($0) }
            })
        func course(_ id: String, term: String) -> ScoreCourseSummary {
            .init(
                id: id, term: term, name: id, number: id, type: "", teacher: "", classroom: "",
                campus: "", description: "",
                creditText: "", scheduleText: "", weeksText: "", hourText: "")
        }
        let first = Task { await model.restoreCachedDataIfNeeded() }
        defer { first.cancel() }
        try await waitForTestEvent { !(reads.pending.count < 1) }
        let second = Task { await model.restoreCachedDataIfNeeded() }
        defer { second.cancel() }
        try await waitForTestEvent { !(reads.pending.count < 2) }
        reads.pending[1]?.resume(returning: [
            "新学期": [course("new-1", term: "新学期"), course("new-2", term: "新学期")]
        ])
        reads.pending[1] = nil
        await second.value
        #expect(model.availableTerms == ["新学期"] && model.pendingCourseCount == 2)
        reads.pending[0]?.resume(returning: ["旧学期": [course("old", term: "旧学期")]])
        reads.pending[0] = nil
        await first.value
        #expect(
            model.availableTerms == ["新学期"] && model.selectedTerms == ["新学期"]
                && model.pendingCourseCount == 2)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func scoreSaveCancelFollowsRefresh(resetAccount: Bool) async throws {
        let domain = "BIT101ModulesTests.score-save-cancellation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let old = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["旧成绩", "80"])]
        let fresh = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["新成绩", "95"])]
        let cache = SuspendedSnapshotCache(rows: old)
        let model = ScoreViewModel(
            service: ScoreServiceSpy(detailedRows: fresh), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] }
        )
        cache.suspendSave = true
        let refresh = Task { await model.refresh() }
        defer {
            refresh.cancel()
            cache.pendingSave?.resume()
            cache.pendingSave = nil
        }
        try await waitForTestEvent { cache.pendingSave != nil }
        if resetAccount { model.resetForCurrentAccount() } else { refresh.cancel() }
        cache.pendingSave?.resume()
        cache.pendingSave = nil
        await refresh.value
        #expect(cache.cancelledSave && cache.snapshot.rows == old)
        if resetAccount { #expect(model.rows.isEmpty) }
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
        let model = ScoreViewModel(
            service: ScoreServiceSpy(detailedRows: fresh), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] }
        )
        if cloudRead { await model.restoreCachedDataIfNeeded() }
        let previous = cache.snapshot
        cache.suspendRead = true
        let reading = Task {
            if cloudRead {
                await model.applySyncedScores()
            } else {
                await model.restoreCachedDataIfNeeded()
            }
        }
        defer {
            cache.suspendRead = false
            reading.cancel()
            cache.pending?.resume(returning: previous)
            cache.pending = nil
        }
        try await waitForTestEvent { !(cache.pending == nil) }
        await model.refresh()
        cache.pending?.resume(returning: previous)
        cache.pending = nil
        await reading.value
        #expect(ScoreRowComparison.rowsMatch(model.rows, fresh))
        #expect(model.lastUpdatedAt == Date(timeIntervalSince1970: 200))
        cache.snapshot = .init(rows: [], updatedAt: Date(timeIntervalSince1970: 300))
        await model.applySyncedScores()
        #expect(model.rows.isEmpty)
        #expect(model.lastUpdatedAt == Date(timeIntervalSince1970: 300))
    }

    @Test("Score refresh requests fields required by the detail UI", .timeLimit(.minutes(1)))
    @MainActor
    func scoreRefreshRequestsDetailedRows() async throws {
        let service = ScoreServiceSpy()
        let (viewModel, _) = try makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test(
        "Score cache write failure presents a save error and retains downloaded rows",
        .timeLimit(.minutes(1)))
    func scoreSaveFailureIsPresented() async throws {
        clearPreferences()
        defer { clearPreferences() }
        let session = AppStorageSession(accountIdentifier: "write-failure")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        let rows = [
            ScoreRow(
                index: 0, headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"])
        ]
        let cache = RejectingScoreCache(
            snapshot: .init(rows: rows, updatedAt: Date(), detailedUpdatedAt: Date()))
        let model = ScoreViewModel(
            service: ScoreServiceSpy(detailedRows: rows), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] }
        )
        await model.refresh()
        #expect(model.alert?.title == "成绩保存失败")
        #expect(ScoreRowComparison.rowsMatch(model.rows, rows))
        #expect(model.lastUpdatedAt == nil)
        #expect(cache.writes == 1)
        #expect(model.refreshPhase == .idle)
    }

    @Test(
        "Refresh cancellation and account reset immediately cancel every score request",
        .timeLimit(.minutes(1)),
        arguments: ["authentication", "summary", "details"], [false, true])
    func scoreRequestsCancelImmediately(_ stage: String, _ resetAccount: Bool) async throws {
        let account = ScoreCacheSessionHolder(
            session: AppStorageSession(accountIdentifier: "cancel-account-a"))
        let oldSession = account.session
        let service = CancellableScoreService(stage: stage)
        let (model, cache) = try makeViewModel(service: service, session: { account.session })
        defer { clearPreferences() }
        let refresh = Task { await model.refresh() }
        try await service.waitUntilStarted()
        if resetAccount {
            account.session = AppStorageSession(accountIdentifier: "cancel-account-b")
            model.resetForCurrentAccount()
        } else {
            refresh.cancel()
        }
        #expect(service.cancelled.withLock { $0 })
        await refresh.value
        #expect(try await cache.loadSnapshot(for: oldSession) == nil)
        #expect(model.rows.isEmpty)
        #expect(model.refreshPhase == .idle)
    }

    @Test("Score refresh preserves detailed mode after SMS authentication", .timeLimit(.minutes(1)))
    @MainActor
    func scoreSMSRefreshRequestsDetailedRows() async throws {
        let service = ScoreServiceSpy(requiresSMS: true)
        let (viewModel, _) = try makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()
        #expect(viewModel.refreshPhase == .awaitingVerification)
        #expect(viewModel.isSyncing == false)
        await viewModel.submitVerificationCode("123456")
        #expect(viewModel.refreshPhase == .idle)
        #expect(viewModel.isSyncing == false)

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("Delayed score challenges respect account ownership", .timeLimit(.minutes(1)))
    @MainActor
    func delayedScoreChallengeIsDiscarded() async throws {
        let activeSession = ScoreCacheSessionHolder(
            session: AppStorageSession(accountIdentifier: "score-account-a")
        )
        let service = DelayedScoreServiceSpy()
        let (viewModel, _) = try makeViewModel(service: service, session: { activeSession.session })
        defer { clearPreferences() }

        let refreshTask = Task { await viewModel.refresh() }
        try await service.waitUntilStarted()

        activeSession.session = AppStorageSession(accountIdentifier: "score-account-b")
        viewModel.resetForCurrentAccount()
        service.completeStart(
            with: BITLoginAuthenticationChallenge(
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
        #expect(viewModel.verificationChallenge == nil)
        #expect(!viewModel.isSyncing)
    }

    @Test(
        "Unchanged score refresh presents the latest-state notice", .timeLimit(.minutes(1)),
        arguments: [false, true])
    @MainActor func unchangedScoreRefreshPresentsNotice(memoryOnly: Bool) async throws {
        let rows = [
            ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"])
        ]
        let service = ScoreServiceSpy(detailedRows: rows)
        let memory = SuspendedSnapshotCache(rows: rows)
        let (viewModel, cache) = try makeViewModel(
            service: service, cacheOverride: memoryOnly ? memory : nil)
        if memoryOnly {
            await viewModel.restoreCachedDataIfNeeded()
            memory.snapshot.rows = nil
        } else {
            await cache.saveDetailed(rows: rows)
        }
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

    @Test(arguments: ["nan", "NaN", "inf", "-inf", "Infinity"])
    func nonFiniteScoresShareMissingValueBoundary(value: String) {
        let row = ScoreRow(index: 0, headers: ["成绩", "平均分", "学分"], values: [value, value, value])
        for index in [ScoreSortIndex.score, .averageScore, .credit] {
            #expect(index.isMissingValue(in: row))
            #expect(
                index.compare(
                    row,
                    ScoreRow(index: 1, headers: ["成绩", "平均分", "学分"], values: ["90", "90", "3"]))
                    == .orderedDescending)
        }
    }
}
