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

    @Test("Score refresh preserves detailed mode after SMS authentication")
    @MainActor
    func scoreSMSRefreshRequestsDetailedRows() async throws {
        let service = ScoreServiceSpy(requiresSMS: true)
        let (viewModel, _) = try makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()
        await viewModel.submitSMSCode("123456")

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
