import BIT101TestSupport
import ClientCore
import Combine
import Foundation
import ScoreDomain
import ScorePorts
import StorageCore
import Testing
import TransportCore
import os

@testable import ScoreFeature
@testable import ScoreInfrastructure

extension ScorePublicContractTests {
    @Test(arguments: [false, true])
    func filterPrefEditsRetainFutureFields(legacy: Bool) throws {
        let domain = "BIT101ModulesTests.score-filter-format"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "filter-format")
        let key = session.key("score.filter.preferences")
        let sourceKey = legacy ? session.legacyKey("score.filter.preferences") : key
        defaults.set(
            Data(
                #"""
                {"selectedTerms":["old"],"selectedCourseTypes":[],"sortIndex":"score","sortOrd\#
                er":"descending","futureSetting":{"enabled":true,"values":[1,2]}}
                """#
                .utf8), forKey: sourceKey)
        let store = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        #expect(store.load()?.selectedTerms == ["old"])
        #expect(
            store.save(
                selectedTerms: ["new"], selectedCourseTypes: [], sortIndex: .score,
                sortOrder: .ascending))
        store.applySynced(.init())
        let data = try #require(defaults.data(forKey: key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["sortIndex"] == nil && object["sortOrder"] == nil)
        #expect((object["futureSetting"] as? [String: Any])?["values"] as? [Int] == [1, 2])
        #expect(defaults.object(forKey: session.legacyKey("score.filter.preferences")) == nil)
        session = AppStorageSession(accountIdentifier: "other-filter-format")
        #expect(
            store.save(
                selectedTerms: [], selectedCourseTypes: [], sortIndex: .term, sortOrder: .ascending)
        )
        let otherData = try #require(defaults.data(forKey: session.key("score.filter.preferences")))
        let other = try #require(
            try JSONSerialization.jsonObject(with: otherData) as? [String: Any])
        #expect(other["futureSetting"] == nil)
        session = AppStorageSession(accountIdentifier: "filter-format")
        #expect(store.load()?.sortOrder == nil)
    }

    @Test(arguments: ["99", "true", "null", "\"1\""], [false, true])
    func unsupportedFilterPrefRetainTheirBytesBytes(version: String, legacy: Bool) throws {
        let domain = "BIT101ModulesTests.score-filter-future"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "future-filter")
        let key =
            legacy
            ? session.legacyKey("score.filter.preferences")
            : session.key("score.filter.preferences")
        let source = Data(
            ("{\"schemaVersion\":" + version + ",\"selectedTerms\":[],\"selectedCourseTypes\":[]}")
                .utf8)
        defaults.set(source, forKey: key)
        let store = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        #expect(store.hasUnreadableSnapshot && store.load() == nil)
        #expect(
            !store.save(
                selectedTerms: [], selectedCourseTypes: [], sortIndex: .score, sortOrder: .ascending
            ))
        store.applySynced(.init())
        #expect(defaults.data(forKey: key) == source)
        if legacy {
            #expect(defaults.object(forKey: session.key("score.filter.preferences")) == nil)
        }
    }

    @Test(arguments: [
        #"{}"#, #"{"selectedTerms":[]}"#, #"{"selectedCourseTypes":[]}"#,
        #"{"selectedTerms":null,"selectedCourseTypes":[]}"#,
    ])
    func incompleteFilterPrefsRetainReadFailure(_ source: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ScoreFilterPreferenceSnapshot.self, from: Data(source.utf8))
        }
    }

    @Test("Memory backend shares the production file service contract")
    func fileServiceContract() throws {
        let files = ModuleScoreFiles()
        try verifyFileServiceContract(
            files, root: URL(fileURLWithPath: "/file-service-contract"),
            setRemovalFailure: { files.setFailures(removal: $0) })
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: [false, true])
    func unreadableFilterPrefsRetainTheirBytesBytes(empty: Bool) async throws {
        let domain = "BIT101ModulesTests.score-filter-corruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = Account()
        let key = account.session.key("score.filter.preferences")
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: key)
        let preferences = ScoreFilterPreferenceStore(
            defaults: defaults, session: { account.session })
        let cache = Cache()
        cache.rows =
            empty
            ? []
            : [
                ScoreRow(
                    index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
                    values: ["fixture", "90", "fixture", "必修"])
            ]
        var changes = 0
        let observation = preferences.changes.sink { _ in changes += 1 }
        defer { observation.cancel() }
        let model = ScoreViewModel(
            service: Service(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { account.session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in [:] })
        #expect(model.needsStorageRecovery && model.alert == nil)
        await model.restoreCachedDataIfNeeded()
        model.setSortOrder(.descending)
        #expect(model.needsStorageRecovery && model.alert == nil)
        #expect(model.sortOrder == .descending && changes == 0)
        #expect(defaults.data(forKey: key) == damaged)
        account.session = AppStorageSession(accountIdentifier: "healthy-filter")
        model.resetForCurrentAccount()
        #expect(model.alert == nil && !model.needsStorageRecovery)
        await model.restoreCachedDataIfNeeded()
        model.setSortOrder(.descending)
        #expect(preferences.load()?.sortOrder == (empty ? nil : ScoreSortOrder.descending.rawValue))
        #expect((changes > 0) == !empty && defaults.data(forKey: key) == damaged)
    }

    @Test(.timeLimit(.minutes(1))) func publicAssemblyAcceptsStoragePorts() async throws {
        let cache = Cache()
        let surroundingCache = Cache()
        let preferences = Preferences()
        let surroundingPreferences = Preferences()
        let session = AppStorageSession(accountIdentifier: "public-score")
        let model = ScoreViewModel(
            service: Service(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in [:] })
        surroundingPreferences.changeSubject.send(session)
        #expect(preferences.loads == 1)
        preferences.changeSubject.send(AppStorageSession(accountIdentifier: "other"))
        #expect(preferences.loads == 1)
        preferences.changeSubject.send(session)
        #expect(preferences.loads == 2)
        surroundingCache.changeSubject.send(session)
        cache.changeSubject.send(AppStorageSession(accountIdentifier: "other"))
        #expect(cache.loads == 0)
        cache.changeSubject.send(session)
        try await cache.waitForLoad()
        #expect(cache.loads == 1)
        #expect(surroundingCache.loads == 0)
        withExtendedLifetime(model) {}
    }

    @Test func everySortingFieldUsesOwnValue() {
        let headers = ["课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"]
        let first = ScoreRow(
            index: 0, headers: headers, values: [" A ", "85", "80", "1", "A", "A"])
        let second = ScoreRow(index: 1, headers: headers, values: ["B", "95", "90", "4", "B", "B"])
        let empty = ScoreRow(index: 2, headers: [], values: [])
        #expect(ScoreSortIndex.allCases.map(\.title) == ["名称", "成绩", "均分", "学分", "学期", "种类"])
        for field in ScoreSortIndex.allCases {
            #expect(field.id == field.rawValue)
            #expect(field.compare(first, second) == .orderedAscending)
            #expect(field.compare(second, first) == .orderedDescending)
            #expect(field.compare(first, first) == .orderedSame)
            #expect(field.isMissingValue(in: first) == false)
            #expect(field.isMissingValue(in: empty))
        }
        #expect(ScoreSortIndex.averageScore.compare(first, empty) == .orderedAscending)
        #expect(ScoreSortIndex.averageScore.compare(empty, first) == .orderedDescending)
        #expect(ScoreSortOrder.ascending.toggled == .descending)
        #expect(ScoreSortOrder.descending.toggled == .ascending)
        #expect(ScoreSortOrder.allCases.map(\.title) == ["升序", "降序"])
        #expect(ScoreSortOrder.ascending.id == "ascending")
    }

    @Test func domainPoliciesRunTheirPublicContracts() {
        func row(_ index: Int, _ score: String, status: String = "是") -> ScoreRow {
            ScoreRow(
                index: index, headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "该课程所有教学班成绩录入完毕"],
                values: ["math", "数学", score, "4", "2026-2027-1", status])
        }
        let low = row(0, "及格")
        let high = row(1, "优秀")
        let summary = ScoreSummary.make(from: [low, high])
        #expect(summary.selectedCourseCount == 1)
        #expect(summary.totalCredit == 4)
        #expect(summary.weightedAverageScore == 95)
        #expect(ScoreSortIndex.score.compare(high, low) == .orderedDescending)
        #expect(ScoreRowComparison.rowsMatch([high, low], [low, high]))
        #expect(ScoreRowComparison.briefRowsMatchCache([high], cachedRows: [high]))
        #expect(!ScoreRowComparison.rowsMatch([high], [low]))
        #expect(ScoreRowComparison.rowsMatch([], []))
        #expect(!ScoreRowComparison.rowsMatch([high], []))
        let position = ScoreRow(index: 0, headers: ["序号", "操作栏"], values: ["1", "查看"])
        #expect(!ScoreRowComparison.rowsMatch([position], [position]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([], cachedRows: [high]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([position], cachedRows: [position]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([high], cachedRows: [low]))
    }
}

extension ScoreInfrastructureBoundaryTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "score.detail.cache", "score.detail.cache.updated-at",
            "score.detail.cache.full-updated-at",
        ])
    func partialLegacyCorruptionPreservesFragment(prefix: String) async throws {
        for malformedType in [false, true] {
            let domain = "BIT101ModulesTests.score-legacy-corruption.\(prefix).\(malformedType)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            defaults.removePersistentDomain(forName: domain)
            defer { defaults.removePersistentDomain(forName: domain) }
            let session = AppStorageSession(accountIdentifier: "legacy-corruption")
            let files = ModuleScoreFiles()
            let root = URL(fileURLWithPath: "/score-legacy-corruption")
            let cache = ScoreCacheStore(
                files: files, storageRoot: root, defaults: defaults, session: { session })
            let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(rows), forKey: session.key("score.detail.cache"))
            defaults.set(
                try encoder.encode(Date()), forKey: session.key("score.detail.cache.updated-at"))
            defaults.set(
                try encoder.encode(Date()),
                forKey: session.key("score.detail.cache.full-updated-at"))
            defaults.set(
                malformedType ? "damaged" as Any : Data("damaged".utf8), forKey: session.key(prefix)
            )
            let retained = defaults.dictionaryRepresentation() as NSDictionary
            await #expect(throws: ScoreCacheReadError.self) { try await cache.loadSnapshot() }
            await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
            #expect(await cache.save(rows: rows) == nil)
            await #expect(throws: ScoreCacheReadError.self) {
                try await cache.applySynced(
                    .init(rows: rows, updatedAt: Date(), detailedUpdatedAt: nil))
            }
            #expect(defaults.dictionaryRepresentation() as NSDictionary == retained)
            let file = root.appending(path: session.accountStorageIdentifier).appending(
                path: "score-cache.json")
            #expect(files.fileExists(at: file) == false)
        }
    }

    @Test(.timeLimit(.minutes(1))) func healthyLegacyMigrationPreservesRows() async throws {
        let domain = "BIT101ModulesTests.score-legacy-valid"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "legacy-valid")
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["90"])]
        let date = Date(timeIntervalSince1970: 100)
        let encoder = JSONEncoder()
        defaults.set(try encoder.encode(rows), forKey: session.legacyKey("score.detail.cache"))
        defaults.set(
            try encoder.encode(date), forKey: session.legacyKey("score.detail.cache.updated-at"))
        defaults.set(
            try encoder.encode(date),
            forKey: session.legacyKey("score.detail.cache.full-updated-at"))
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/legacy-valid"),
            defaults: defaults, session: { session })
        #expect(
            try await cache.syncPayload()
                == .init(rows: rows, updatedAt: date, detailedUpdatedAt: date))
        #expect(defaults.object(forKey: session.legacyKey("score.detail.cache")) == nil)
        #expect(try await cache.loadSnapshot()?.rows == rows)
    }

    @Test(.timeLimit(.minutes(1))) func cloudApplyComparesCompleteRepository() async throws {
        let session = AppStorageSession(accountIdentifier: "score-cas")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-cas"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-cas") }
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-cas"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(initial))
        let read = try #require(try await cache.syncPayload())
        let newer = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: newer) != nil)
        let remote = ScoreCacheSyncPayload(
            rows: initial.rows, updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(remote, replacing: read) == false)
        let current = try #require(try await cache.syncPayload())
        #expect(current.rows == newer)
        #expect(try await cache.applySynced(remote, replacing: current))
        #expect(try await cache.syncPayload() == remote)
    }

    @Test(.timeLimit(.minutes(1))) func cloudApplyReportsWriteFailure() async throws {
        let session = AppStorageSession(accountIdentifier: "score-write-failure")
        let defaults = try #require(
            UserDefaults(suiteName: "BIT101ModulesTests.score-write-failure"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-write-failure") }
        let files = ModuleScoreFiles()
        let cache = ScoreCacheStore(
            files: files, storageRoot: URL(fileURLWithPath: "/score-write-failure"),
            defaults: defaults, session: { session })
        let original = ScoreCacheSyncPayload(
            rows: [], updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(original))
        let remote = ScoreCacheSyncPayload(
            rows: [], updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        files.setFailures(writing: true)
        await #expect(throws: ScoreCacheWriteError.self) {
            try await cache.applySynced(remote, replacing: original)
        }
        #expect(try await cache.syncPayload() == original)
        files.setFailures()
        #expect(try await cache.applySynced(remote, replacing: original))
        #expect(try await cache.syncPayload() == remote)
        let bytes = files.storedData
        files.setFailures(protection: true)
        await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
        await #expect(throws: ScoreCacheReadError.self) { try await cache.applySynced(original) }
        #expect(files.storedData == bytes)
        files.setFailures()
        #expect(try await cache.syncPayload() == remote)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func authoritativeEmptyScoreReplacesRowsRows(detailed: Bool) async throws {
        let domain = "BIT101ModulesTests.score-empty-sync"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-empty-sync")
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-empty-sync"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(initial))
        #expect(
            try await cache.applySynced(
                .init(rows: [], updatedAt: nil, detailedUpdatedAt: nil), replacing: initial)
                == false)
        #expect(try await cache.syncPayload() == initial)
        let timestamp = Date(timeIntervalSince1970: 200)
        let empty = ScoreCacheSyncPayload(
            rows: [], updatedAt: detailed ? nil : timestamp,
            detailedUpdatedAt: detailed ? timestamp : nil)
        #expect(try await cache.applySynced(empty, replacing: initial))
        #expect(try await cache.syncPayload() == empty)
        #expect(try await cache.loadSnapshot()?.rows == [])
    }

    @Test(.timeLimit(.minutes(1))) func scoreDiskFormatPreservesAdditionalFields() async throws {
        let session = AppStorageSession(accountIdentifier: "score-format")
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-format")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-format"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-format") }
        let cache = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
        #expect(await cache.saveDetailed(rows: rows) != nil)
        #expect(try await cache.loadSnapshot()?.detailedUpdatedAt != nil)
        let url = root.appending(path: session.accountStorageIdentifier).appending(
            path: "score-cache.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        object["additionalField"] = ["nested": [1, 2]]
        try files.writeData(JSONSerialization.data(withJSONObject: object), to: url, options: [])
        #expect(await cache.save(rows: rows) != nil)
        #expect(try await cache.loadSnapshot()?.detailedUpdatedAt == nil)
        #expect(try await cache.syncPayload()?.detailedUpdatedAt == nil)
        let written = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(
            written["additionalField"] as? NSDictionary == object["additionalField"]
                as? NSDictionary)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "{}", #"{"rows":[],"schemaVersion":2}"#, #"{"rows":[],"schemaVersion":true}"#,
            #"{"rows":[],"schemaVersion":null}"#, #"{"rows":[],"schemaVersion":"1"}"#,
        ])
    func unsupportedScoreDiskPreserveTheirBytes(_ json: String) async throws {
        let session = AppStorageSession(accountIdentifier: "score-format-rejected")
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-format-rejected")
        let defaults = try #require(
            UserDefaults(suiteName: "BIT101ModulesTests.score-format-rejected"))
        defer {
            defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-format-rejected")
        }
        let cache = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        let url = root.appending(path: session.accountStorageIdentifier).appending(
            path: "score-cache.json")
        let bytes = Data(json.utf8)
        try files.writeData(bytes, to: url, options: [])
        await #expect(throws: ScoreCacheReadError.self) { try await cache.loadSnapshot() }
        await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
        #expect(await cache.save(rows: []) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test(arguments: [
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],[" ","C1","","2"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["课程"," ","","2"]]}"#,
        #"{"msg":"查询失败","data":[["课程名称","成绩"],["功能验收","95"]]}"#,
        #"{"msg":"查询成功","data":[["错误"],["未登录"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","95"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分","成绩"],["功能验收","C1","95","2","95"]]}"#,
    ])
    func malformed(_ response: String) {
        #expect(throws: (any Error).self) { try ScoreService.decodeScoreRows(Data(response.utf8)) }
    }

    @Test func scoreResponseParsingRunsInThePackageHost() throws {
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[]}"#.utf8)).isEmpty)
        #expect(
            try ScoreService.decodeScoreRows(
                Data(
                    #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","95","2"]]}"#
                        .utf8)
            ).first?.courseName == "功能验收")
    }

    @Test(arguments: Array(ScoreRow.requiredHeaderNames).sorted())
    func scoreResponseRequiresTheSharedHeaders(missing: String) throws {
        let headers = ScoreRow.requiredHeaderNames.sorted().filter { $0 != missing }
        let response = try JSONSerialization.data(withJSONObject: [
            "msg": "查询成功", "data": [headers],
        ])
        #expect(throws: ScoreServiceError.self) { try ScoreService.decodeScoreRows(response) }
    }
}
