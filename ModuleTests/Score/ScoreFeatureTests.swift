import Combine
import BIT101TestSupport
import ScoreDomain
import ScorePorts
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
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func storageRecoverySerializesRefreshAndKeepsLatestRows(resetAccount: Bool) async throws {
        let headers = ["课程编号", "课程名称", "成绩", "学分", "开课学期"]
        let previous = [ScoreRow(index: 0, headers: headers, values: ["old", "旧成绩", "60", "4", "term"])]
        let fresh = [ScoreRow(index: 0, headers: headers, values: ["new", "新成绩", "95", "4", "term"])]
        let cache = SuspendedSnapshotCache(rows: previous)
        cache.suspendRecovery = true
        let service = ScoreServiceSpy(detailedRows: fresh)
        service.briefRowsOverride = fresh
        let domain = "BIT101ModulesTests.score-recovery-refresh"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = ScoreCacheSessionHolder(session: AppStorageSession(accountIdentifier: "recovery-refresh"))
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { account.session }),
            currentScoreCacheSession: { account.session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded()
        #expect(ScoreRowComparison.rowsMatch(model.rows, previous))
        model.requestStorageRecovery()
        let recovery = Task { await model.recoverStorage() }
        defer {
            recovery.cancel()
            cache.pendingRecovery?.resume(returning: nil)
            cache.pendingRecovery = nil
        }
        try await waitForTestEvent { cache.pendingRecovery != nil }
        await model.refresh()
        #expect(service.requestedDetailValues.isEmpty)
        #expect(ScoreRowComparison.rowsMatch(model.rows, previous))
        if resetAccount {
            account.session = AppStorageSession(accountIdentifier: "current-account")
            model.resetForCurrentAccount()
            #expect(!model.isRecoveringStorage)
        }
        cache.pendingRecovery?.resume(returning: Date(timeIntervalSince1970: 200))
        cache.pendingRecovery = nil
        await recovery.value
        if resetAccount { #expect(model.rows.isEmpty) }
        else { #expect(ScoreRowComparison.rowsMatch(model.rows, cache.snapshot.rows ?? [])) }
        await model.refresh()
        #expect(ScoreRowComparison.rowsMatch(model.rows, fresh))
        #expect(ScoreRowComparison.rowsMatch(cache.snapshot.rows ?? [], fresh))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func detailedFailurePersistsMatchedDetailsAlongsideNewCourses(includesTerm: Bool) async throws {
        let headers = ["课程编号", "课程名称", "成绩", "学分", "开课学期", "平均分", "本人成绩在班级中占"]
        let original = ScoreRow(index: 0, headers: headers, values: ["MATH", "数学", "90", "4", "term", "82.5", "1/20"])
        let service = ScoreServiceSpy()
        let count = includesTerm ? 5 : 4
        service.briefRowsOverride = [ScoreRow(index: 0, headers: Array(headers.prefix(count)), values: Array(["MATH", "数学", "90", "4", "term"].prefix(count))),
            ScoreRow(index: 1, headers: Array(headers.prefix(count)), values: Array(["NEW", "新课程", "85", "2", "term"].prefix(count)))]
        service.detailedError = URLError(.notConnectedToInternet)
        let (model, cache) = try makeViewModel(service: service)
        defer { clearPreferences() }
        #expect(await cache.saveDetailed(rows: [original]) != nil)
        await model.restoreCachedDataIfNeeded()
        await model.refresh()
        let saved = try #require(await cache.loadSnapshot())
        #expect(saved.rows?.count == 2 && saved.detailedUpdatedAt == nil)
        #expect(saved.rows?.first?.averageScore == "82.5" && saved.rows?.first?.classRank == "1/20")
        #expect(ScoreRowComparison.rowsMatch(model.rows, saved.rows ?? []))
        if !includesTerm {
            let otherTerm = ScoreRow(index: 1, headers: headers, values: ["MATH", "数学", "90", "4", "other", "70", "2/20"])
            let ambiguous = ScoreRowComparison.retainingDetailedFields([try #require(service.briefRowsOverride?.first)], from: [original, otherTerm])
            #expect(ambiguous.first?.averageScore == "" && ambiguous.first?.term == "")
        }
    }

    @Test(.timeLimit(.minutes(1))) func detailedFilterFieldsPreserveTheInitialAllSelection() async throws {
        let detailed = ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "课程性质"],
            values: ["MATH", "数学", "90", "4", "term", "必修"])
        let service = ScoreServiceSpy(detailedRows: [detailed])
        service.briefRowsOverride = [ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩", "学分"], values: ["MATH", "数学", "90", "4"])]
        let (model, _) = try makeViewModel(service: service)
        defer { clearPreferences() }
        await model.refresh()
        #expect(model.selectedTerms == ["term"] && model.selectedCourseTypes == ["必修"])
        #expect(model.visibleRows.count == 1)
        await model.restoreCachedDataIfNeeded()
        #expect(model.visibleRows.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func confirmedScoreRecoveryPreservesOtherAccountsAndOnlineRows() async throws {
        let domain = "BIT101ModulesTests.score-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "recover"), other = AppStorageSession(accountIdentifier: "other")
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-recovery")
        let file = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
        let otherFile = root.appending(path: other.accountStorageIdentifier).appending(path: "score-cache.json")
        let damaged = Data("damaged".utf8)
        try files.writeData(damaged, to: file, options: [])
        try files.writeData(damaged, to: otherFile, options: [])
        defaults.set(damaged, forKey: session.key("score.filter.preferences"))
        defaults.set(damaged, forKey: other.key("score.filter.preferences"))
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.refresh()
        #expect(model.needsStorageRecovery && !model.rows.isEmpty && files.storedData[file] == damaged)
        model.requestStorageRecovery()
        model.cancelStorageRecovery()
        #expect(files.storedData[file] == damaged && preferences.hasUnreadableSnapshot)
        model.requestStorageRecovery()
        await model.recoverStorage()
        #expect(!model.needsStorageRecovery && !preferences.hasUnreadableSnapshot)
        #expect(try await cache.loadSnapshot()?.rows == model.rows)
        #expect(files.storedData[otherFile] == damaged && defaults.data(forKey: other.key("score.filter.preferences")) == damaged)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledDetailsKeepThePriorCompleteSnapshotVisible() async throws {
        let service = CancellableScoreService(stage: "details")
        let (model, cache) = try makeViewModel(service: service)
        defer { clearPreferences() }
        let headers = ["课程编号", "课程名称", "成绩", "学分", "开课学期", "平均分", "本人成绩在班级中占"]
        let original = ScoreRow(index: 0, headers: headers, values: ["MATH", "数学", "90", "4", "term", "82.5", "1/20"])
        let briefHeaders = Array(headers.prefix(5))
        service.briefRows = [ScoreRow(index: 0, headers: briefHeaders, values: ["MATH", "数学", "90", "4", "term"]),
            ScoreRow(index: 1, headers: briefHeaders, values: ["NEW", "新课程", "85", "2", "term"])]
        #expect(await cache.saveDetailed(rows: [original]) != nil)
        await model.restoreCachedDataIfNeeded()
        let loading = Task { await model.refresh() }
        defer { loading.cancel() }
        try await service.waitUntilStarted()
        #expect(model.rows.first?.averageScore == "82.5" && model.rows.first?.classRank == "1/20")
        #expect(model.rows.count == 2)
        loading.cancel()
        await loading.value
        #expect(model.rows == [original] && model.alert == nil && model.refreshPhase == .idle)
        #expect(try await cache.loadSnapshot()?.rows == [original])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func detailedFailureKeepsNewBriefScores(startFailed: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        defer { clearPreferences() }
        clearPreferences()
        let session = AppStorageSession(accountIdentifier: "brief-score-retry")
        let files = ModuleScoreFiles()
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/brief-score-retry"),
            defaults: defaults, session: { session })
        let service = ScoreServiceSpy()
        service.detailedError = URLError(.cannotConnectToHost)
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        if startFailed {
            files.setFailures(reading: true, existence: true)
            await model.restoreCachedDataIfNeeded()
            #expect(model.state == .failed(ScoreCacheReadError.unreadable.localizedDescription))
            files.setFailures()
        }
        await model.refresh()
        let saved = try #require(await cache.loadSnapshot(for: session))
        let savedRows = try #require(saved.rows)
        #expect(model.state == .loaded && model.rows.first?.score == "90")
        #expect(ScoreRowComparison.rowsMatch(model.rows, savedRows))
        #expect(model.lastUpdatedAt == saved.updatedAt && saved.detailedUpdatedAt == nil)
        #expect(model.alert?.title == "成绩刷新失败" && model.refreshPhase == .idle)
        service.detailedError = nil
        await model.refresh()
        #expect(model.state == .loaded && model.rows.first?.averageScore == "82.5")
        #expect(service.requestedDetailValues == [false, true, false, true])
    }
    @Test(.timeLimit(.minutes(1))) func protectedCacheRestoreReportsItsReasonAndRetriesAfterReadabilityReturns() async throws {
        let domain = "BIT101ModulesTests.score-protected-restore"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-protected-restore")
        let files = ModuleScoreFiles()
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/score-protected-restore"),
            defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: rows) != nil)
        let service = ScoreServiceSpy()
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        files.setFailures(reading: true, existence: true)
        await model.restoreCachedDataIfNeeded()
        #expect(model.state == .failed(ScoreCacheReadError.unreadable.localizedDescription))
        files.setFailures()
        await model.restoreCachedDataIfNeeded()
        #expect(model.state == .loaded && model.rows == rows)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["reading", "protection", "corrupt"], [false, true])
    func unreadableCacheKeepsOnlineScoresVisible(failure: String, detailedFailure: Bool) async throws {
        clearPreferences()
        defer { clearPreferences() }
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        let session = AppStorageSession(accountIdentifier: "online-score-recovery")
        let files = ModuleScoreFiles()
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/online-score-recovery"),
            defaults: defaults, session: { session })
        #expect(await cache.saveDetailed(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]) != nil)
        if failure == "corrupt" {
            let url = try #require(files.storedData.keys.first)
            try files.writeData(Data("corrupt-cache".utf8), to: url, options: .atomic)
        } else {
            files.setFailures(reading: failure == "reading", protection: failure == "protection")
        }
        let retained = files.storedData
        let service = ScoreServiceSpy()
        if detailedFailure { service.detailedError = URLError(.cannotConnectToHost) }
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.state == .failed(ScoreCacheReadError.unreadable.localizedDescription))
        await model.refresh()
        #expect(service.requestedDetailValues == [false, true])
        #expect(model.state == .loaded && model.rows.first?.score == "90")
        if !detailedFailure { #expect(model.rows.first?.averageScore == "82.5") }
        #expect(model.alert?.title == "成绩保存失败" && model.refreshPhase == .idle)
        #expect(files.storedData == retained)
        let visibleRows = model.rows
        await model.restoreCachedDataIfNeeded()
        #expect(model.state == .loaded && model.rows == visibleRows)
        await model.applySyncedScoreCacheIfAvailable()
        #expect(model.state == .loaded && model.rows == visibleRows)
        #expect(files.storedData == retained)
        if failure != "corrupt" {
            files.setFailures()
            service.detailedError = nil
            await model.refresh()
            #expect(model.state == .loaded && model.alert == nil)
            #expect(await cache.loadRows(for: session) == model.rows)
        }
    }

    @Test(arguments: [("", false), ("1", false), ("123", false), ("1234", true),
                      ("12345678", true), ("123456789", false), ("12a34", false), (" 1234\n", false),
                      ("１２３４", false), ("١٢٣٤", false), ("①②③④", false), ("1️⃣234", false)])
    func sharedVerificationCodeValidation(_ sample: (String, Bool)) {
        #expect(AppVerificationCode.isValid(sample.0) == sample.1)
    }

    @Test(arguments: [("", ""), ("1234", "1234"), ("12a 34\n", "1234"),
                      ("1234567890", "12345678"), ("a1b2c3d4e5f6g7h8i9", "12345678"),
                      ("１２٣٤５６", "123456"), ("𝟙𝟚𝟛𝟜", "1234"), ("①②³Ⅳ½", ""), ("1️⃣234", "234")])
    func sharedVerificationCodeNormalization(_ sample: (String, String)) {
        let normalized = AppVerificationCode.normalize(sample.0)
        #expect(normalized == sample.1)
        #expect(AppVerificationCode.normalize(normalized) == normalized)
    }

    @Test(arguments: [("", "", false), ("1", "1234", false), ("6", "123456", false),
                      ("123", "123", false), ("1234", "1234", true), ("123456", "123456", true),
                      ("12345678", "12345678", true), ("12 34-56", "123456", true),
                      ("123456789", "12345678", false), ("1234", "12341234", false),
                      ("１２٣٤５６", "123456", true), ("١٢٣٤", "1234", true),
                      ("１２３４５６７８９", "12345678", false), ("①②③④", "1234", false)])
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

    @Test(.timeLimit(.minutes(1)))
    func missingFilterFieldsRemainVisibleAndSelectable() async throws {
        defer { clearPreferences() }
        clearPreferences()
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score"))
        let session = AppStorageSession(accountIdentifier: "missing-filters")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/missing-filters"),
            defaults: defaults, session: { session })
        let headers = ["课程名称", "成绩", "学分", "开课学期", "课程性质"]
        let rows = [
            ScoreRow(index: 0, headers: headers, values: ["已分类课程", "90", "2", "A", "必修"]),
            ScoreRow(index: 1, headers: headers, values: ["缺少性质", "80", "2", "A", " \n"]),
            ScoreRow(index: 2, headers: headers, values: ["缺少学期", "70", "2", "", "必修"])
        ]
        #expect(await cache.saveDetailed(rows: rows) != nil)
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["A": [ScoreCourseSummary(id: "schedule-only-type", term: "A",
                name: "课表课程", number: "schedule-only", type: "选修", teacher: "", classroom: "", campus: "",
                description: "", creditText: "", scheduleText: "", weeksText: "", hourText: "")]] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.visibleRows.count == 3)
        #expect(model.summary.selectedCourseCount == 3 && model.summary.weightedAverageScore == 80)
        #expect(Set(model.availableTerms) == ["A", "未分类"])
        #expect(Set(model.availableCourseTypes) == ["必修", "选修", "未分类"])
        model.setSelectedTerms(["未分类"])
        #expect(model.visibleRows.map(\.courseName) == ["缺少学期"])
        model.toggleAllTerms()
        model.setSelectedCourseTypes(["未分类"])
        #expect(model.visibleRows.map(\.courseName) == ["缺少性质"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["missing", "", " \n"])
    func scoresWithoutCourseTypesIgnoreScheduleCategories(restorePreference: Bool, field: String) async throws {
        let domain = "BIT101ModulesTests.score.without-types"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "without-types")
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        if restorePreference {
            #expect(preferences.save(selectedTerms: ["A"], selectedCourseTypes: ["必修"],
                sortIndex: .courseName, sortOrder: .ascending))
        }
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/without-types"),
            defaults: defaults, session: { session })
        let hasField = field != "missing"
        let headers = ["课程名称", "课程编号", "成绩", "学分", "开课学期"] + (hasField ? ["课程性质"] : [])
        let rows = [ScoreRow(index: 0, headers: headers,
            values: ["已出分课程", "scored", "90", "2", "A"] + (hasField ? [field] : []))]
        #expect(await cache.saveDetailed(rows: rows) != nil)
        let courses = ["必修", "选修", ""].map { type in
            ScoreCourseSummary(id: type, term: "A", name: "待出分\(type)", number: type, type: type,
                teacher: "", classroom: "", campus: "", description: "", creditText: "",
                scheduleText: "", weeksText: "", hourText: "")
        }
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in ["A": courses] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.availableCourseTypes.isEmpty && model.visibleRows == rows)
        #expect(model.summary.selectedCourseCount == 1 && model.pendingCourseCount == 3)
        model.setSelectedCourseTypes(["必修"])
        #expect(model.visibleRows == rows && model.pendingCourseCount == 3)
        model.setSortIndex(.score)
        #expect(preferences.load()?.sortIndex == ScoreSortIndex.score.rawValue)
        preferences.applySynced(.init(selectedTerms: ["A"], selectedCourseTypes: ["选修"]))
        #expect(model.visibleRows == rows && model.pendingCourseCount == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingCoursesFollowLocalAndSyncedCourseTypeFilters() async throws {
        let domain = "BIT101ModulesTests.score.pending-types"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "pending-types")
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        let courses = ["必修", "选修", ""].map { type in
            ScoreCourseSummary(id: type, term: "A", name: "待出分\(type)", number: type, type: type,
                teacher: "", classroom: "", campus: "", description: "", creditText: "",
                scheduleText: "", weeksText: "", hourText: "")
        }
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/pending-types"),
            defaults: defaults, session: { session })
        let rows = ["必修"].enumerated().map { index, type in
            ScoreRow(index: index, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
                values: ["已出分\(index)", "90", "A", type])
        }
        #expect(await cache.saveDetailed(rows: rows) != nil)
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: preferences, currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in ["A": courses] })
        await model.restoreCachedDataIfNeeded()
        #expect(model.pendingCourseCount == 3 && Set(model.availableCourseTypes) == ["必修", "选修", "未分类"])
        model.setSelectedCourseTypes(["必修"])
        #expect(model.pendingCourses?.map(\.type) == ["必修"])
        model.toggleAllCourseTypes()
        #expect(model.pendingCourseCount == 3)
        model.toggleAllCourseTypes()
        #expect(model.pendingCourseCount == 0)
        preferences.applySynced(.init(selectedTerms: ["A"], selectedCourseTypes: ["选修"]))
        #expect(model.pendingCourses?.map(\.type) == ["选修"])
    }

    @Test(.timeLimit(.minutes(1))) func localSaveSubscriptionsFanOutAndCancelByOwner() async throws {
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

    @Test(.timeLimit(.minutes(1))) func preferenceStreamsKeepInstancesScoped() async throws {
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

    @Test(.timeLimit(.minutes(1))) func accountSwitchRestoresIndependentSortingAndDefaults() async throws {
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

    @Test(.timeLimit(.minutes(1))) func pendingCourseCoverageRequiresEverySelectedTerm() async throws {
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

    @Test(.timeLimit(.minutes(1)), arguments: ["distinct", "score-missing", "schedule-missing"])
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
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
        @MainActor final class Reads {
            var pending: [CheckedContinuation<[String: [ScoreCourseSummary]], Never>?] = []
            var suspended = true
        }
        let reads = Reads()
        defer { reads.suspended = false; reads.pending.forEach { $0?.resume(returning: [:]) } }
        let model = ScoreViewModel(service: ScoreServiceSpy(), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }), currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in
                guard reads.suspended else { return [:] }
                return await withCheckedContinuation { reads.pending.append($0) }
            })
        func course(_ id: String, term: String) -> ScoreCourseSummary {
            .init(id: id, term: term, name: id, number: id, type: "", teacher: "", classroom: "", campus: "", description: "",
                creditText: "", scheduleText: "", weeksText: "", hourText: "")
        }
        let first = Task { await model.restoreCachedDataIfNeeded() }
        defer { first.cancel() }
        try await waitForTestEvent { !(reads.pending.count < 1) }
        let second = Task { await model.restoreCachedDataIfNeeded() }
        defer { second.cancel() }
        try await waitForTestEvent { !(reads.pending.count < 2) }
        reads.pending[1]?.resume(returning: ["新学期": [course("new-1", term: "新学期"), course("new-2", term: "新学期")]])
        reads.pending[1] = nil
        await second.value
        #expect(model.availableTerms == ["新学期"] && model.pendingCourseCount == 2)
        reads.pending[0]?.resume(returning: ["旧学期": [course("old", term: "旧学期")]])
        reads.pending[0] = nil
        await first.value
        #expect(model.availableTerms == ["新学期"] && model.selectedTerms == ["新学期"] && model.pendingCourseCount == 2)
    }

    private final class SuspendedSnapshotCache: ScoreCaching {
        var suspendRecovery = false
        var pendingRecovery: CheckedContinuation<Date?, Never>?
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? {
            guard suspendRecovery else { return nil }
            suspendRecovery = false
            return await withCheckedContinuation { pendingRecovery = $0 }
        }
        let events = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { events.eraseToAnyPublisher() }
        var snapshot: ScoreCacheSnapshot
        var suspendRead = false
        var pending: CheckedContinuation<ScoreCacheSnapshot?, Never>?
        var suspendSave = false
        var pendingSave: CheckedContinuation<Void, Never>?
        var cancelledSave = false
        init(rows: [ScoreRow]) { snapshot = .init(rows: rows, updatedAt: Date(timeIntervalSince1970: 100)) }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            if suspendRead {
                suspendRead = false
                return await withCheckedContinuation { pending = $0 }
            }
            return snapshot
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? {
            if suspendSave { await withCheckedContinuation { pendingSave = $0 } }
            guard !Task.isCancelled else { cancelledSave = true; return nil }
            let date = Date(timeIntervalSince1970: 200)
            snapshot = .init(rows: rows, updatedAt: date, detailedUpdatedAt: date)
            return date
        }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { await save(rows: rows, for: session) }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func scoreSaveCancellationFollowsRefreshAndAccountGeneration(resetAccount: Bool) async throws {
        let domain = "BIT101ModulesTests.score-save-cancellation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let old = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["旧成绩", "80"])]
        let fresh = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["新成绩", "95"])]
        let cache = SuspendedSnapshotCache(rows: old)
        let model = ScoreViewModel(service: ScoreServiceSpy(detailedRows: fresh), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        cache.suspendSave = true
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); cache.pendingSave?.resume(); cache.pendingSave = nil }
        try await waitForTestEvent { cache.pendingSave != nil }
        if resetAccount { model.resetForCurrentAccount() } else { refresh.cancel() }
        cache.pendingSave?.resume(); cache.pendingSave = nil
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
        defer { cache.suspendRead = false; reading.cancel(); cache.pending?.resume(returning: previous); cache.pending = nil }
        try await waitForTestEvent { !(cache.pending == nil) }
        await model.refresh()
        cache.pending?.resume(returning: previous)
        cache.pending = nil
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
        var detailedError: (any Error)?
        private let requiresSMS: Bool
        private let detailedRowsOverride: [ScoreRow]?
        var briefRowsOverride: [ScoreRow]?

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
            if detail, let detailedError { throw detailedError }
            return detail ? detailedRows : briefRowsOverride ?? briefRows
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
        private var hasStarted = false
        private(set) var fetchCount = 0

        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            hasStarted = true
            return try await withCheckedThrowingContinuation { continuation in
                challengeContinuation = continuation
            }
        }

        func waitUntilStarted() async throws {
            try await waitForTestEvent { hasStarted }
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

    private final class CancellableScoreService: ScoreListServicing {
        let stage: String
        var briefRows: [ScoreRow] = []
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        private var started = false
        private let challenge = BITLoginAuthenticationChallenge(challengeID: "cancel-test", accessToken: "test-token",
            status: "authenticated", maskedPhone: nil, expiresIn: 300)
        init(stage: String) { self.stage = stage }
        func waitUntilStarted() async throws {
            try await waitForTestEvent { started }
        }
        private func suspend() async throws {
            try await withTaskCancellationHandler {
                started = true
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
            return detail ? [] : briefRows
        }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    private final class RejectingScoreCache: ScoreCaching {
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? { nil }
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var writes = 0
        let snapshot: ScoreCacheSnapshot
        init(snapshot: ScoreCacheSnapshot) { self.snapshot = snapshot }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? { snapshot }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { writes += 1; return nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { writes += 1; return nil }
    }

    @Test("Score cache write failure presents a save error and retains downloaded rows", .timeLimit(.minutes(1)))
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

    @Test("Refresh cancellation and account reset immediately cancel every score request", .timeLimit(.minutes(1)),
          arguments: ["authentication", "summary", "details"], [false, true])
    func scoreRequestsCancelImmediately(_ stage: String, _ resetAccount: Bool) async throws {
        let account = ScoreCacheSessionHolder(session: AppStorageSession(accountIdentifier: "cancel-account-a"))
        let oldSession = account.session
        let service = CancellableScoreService(stage: stage)
        let (model, cache) = try makeViewModel(service: service, session: { account.session })
        defer { clearPreferences() }
        let refresh = Task { await model.refresh() }
        try await service.waitUntilStarted()
        if resetAccount {
            account.session = AppStorageSession(accountIdentifier: "cancel-account-b")
            model.resetForCurrentAccount()
        } else { refresh.cancel() }
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
        await viewModel.submitSMSCode("123456")
        #expect(viewModel.refreshPhase == .idle)
        #expect(viewModel.isSyncing == false)

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("A delayed score challenge cannot write into the newly selected account", .timeLimit(.minutes(1)))
    @MainActor
    func delayedScoreChallengeIsDiscardedAfterAccountSwitch() async throws {
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

    @Test("Unchanged score refresh presents the latest-state notice", .timeLimit(.minutes(1)))
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

    @Test(arguments: ["nan", "NaN", "inf", "-inf", "Infinity"])
    func nonFiniteScoresShareTheMissingValueBoundary(value: String) {
        let row = ScoreRow(index: 0, headers: ["成绩", "平均分", "学分"], values: [value, value, value])
        for index in [ScoreSortIndex.score, .averageScore, .credit] {
            #expect(index.isMissingValue(in: row))
            #expect(index.compare(row, ScoreRow(index: 1, headers: ["成绩", "平均分", "学分"], values: ["90", "90", "3"])) == .orderedDescending)
        }
    }

    private func makeRow(index: Int, score: String) -> ScoreRow {
        ScoreRow(
            index: index,
            headers: ["课程编号", "课程名称", "成绩", "学分"],
            values: ["MATH-\(index)", "高等数学", score, "4"]
        )
    }
}
