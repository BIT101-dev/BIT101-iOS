import BIT101TestSupport
import SchedulePersistence
import Foundation
import ScheduleDomain
@testable import ScheduleSync
import StorageCore
import Testing

@MainActor
struct ScheduleSyncTests {
    @Test(arguments: [Int.min, 0, 1, 60, 61, Int.max])
    func cloudLeadMinutesApplyTheSamePresentationBounds(value: Int) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ScheduleCloudSyncState(cache: ScheduleCache()))) as? [String: Any])
        object["courseLiveActivityLeadMinutes"] = value
        let state = try JSONDecoder().decode(ScheduleCloudSyncState.self, from: JSONSerialization.data(withJSONObject: object))
        var destination = ScheduleCache()
        state.apply(to: &destination)
        #expect(destination.courseLiveActivityLeadMinutes == (value < 1 ? 1 : value > 60 ? 60 : value))
    }

    @Test(arguments: ["unchanged", "reordered", "additions"])
    func mergingIndependentEditsRetainsSharedScheduleOrder(mode: String) throws {
        let payload = ScheduleExportPayload(currentTerm: "term", firstDayString: "2026-09-07", timeTable: TimeSlot.default, courses: [])
        func shared(_ id: String) -> SharedScheduleRecord {
            SharedScheduleRecord(id: id, title: id, importedAt: Date(timeIntervalSince1970: 100), payload: payload)
        }
        var base = ScheduleCache()
        base.sharedSchedules = [shared("z"), shared("a")]
        var local = base, remote = base
        local.ddlBeforeDay += 1
        remote.showSunday.toggle()
        if mode == "reordered" { local.sharedSchedules.reverse(); remote.sharedSchedules[0].title = "edited" }
        if mode == "additions" { local.sharedSchedules.append(shared("c")); remote.sharedSchedules.append(shared("b")) }
        let baseline = try ScheduleCloudStateMerge.baseline(for: base)
        let merged = try #require(try ScheduleCloudStateMerge.merge(local: .init(cache: local), remote: .init(cache: remote), baseline: baseline))
        let mirrored = try #require(try ScheduleCloudStateMerge.merge(local: .init(cache: remote), remote: .init(cache: local), baseline: baseline))
        let expected = mode == "reordered" ? ["a", "z"] : mode == "additions" ? ["z", "a", "b", "c"] : ["z", "a"]
        #expect(merged.sharedSchedules.map(\.id) == expected)
        #expect(mirrored.sharedSchedules.map(\.id) == expected)
        #expect(merged.ddlBeforeDay == local.ddlBeforeDay)
        #expect(merged.showSunday == remote.showSunday)
        if mode == "reordered" { #expect(merged.sharedSchedules.first { $0.id == "z" }?.title == "edited") }
    }

    @Test func schoolRefreshAndEmptyRulesKeepTheSameCloudUserState() throws {
        let original = ScheduleCache()
        var refreshed = original
        refreshed.currentTerm = "school-term"
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "学校课程", weeksText: "1-4"),
            to: [], term: refreshed.currentTerm, id: "school")
        refreshed.courseData.store(TermScheduleSnapshot(term: refreshed.currentTerm, firstDayString: "2026-09-07",
            courses: courses, exams: [], updatedAt: Date()))
        refreshed.updatedAt = Date()
        refreshed.cloudSyncBaselineRecordTag = "record"
        refreshed.manualFirstDayStringsByTerm[refreshed.currentTerm] = "2026-09-28"
        #expect(refreshed.manualCourseRulesByTerm.isEmpty)
        #expect(try ScheduleCloudSyncState.matches(original, refreshed))
        refreshed.manualCourseRulesByTerm["old-term"] = []
        #expect(try ScheduleCloudSyncState.matches(original, refreshed))
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(refreshed))
        #expect(try ScheduleCloudSyncState.matches(original, restored))
        let edited = try ScheduleCourseEditor.adding(CourseDraft(title: "个人课程", weekday: 3, weeksText: "1"),
            to: refreshed.courses, term: refreshed.currentTerm, id: "manual")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &refreshed, previousCourses: refreshed.courses, currentCourses: edited)
        #expect(try ScheduleCloudSyncState.matches(original, refreshed) == false)
    }

    @Test func schoolDDLCloudStateSharesCompletionAndPreservesLocalBodies() throws {
        var source = ScheduleCache()
        source.ddlEvents = [
            DDLEventRecord(id: "eclass:1", group: "eclass", title: "source-body", text: "", dueAt: Date(), done: true),
            DDLEventRecord(id: "eclass:2", group: "eclass", title: "untouched", text: "", dueAt: Date(), done: false),
            DDLEventRecord(id: "manual", group: "main", title: "manual", text: "", dueAt: Date(), done: false),
        ]
        source.lexueDDLCompletionByID["eclass:3"] = false
        let state = ScheduleCloudSyncState(cache: source)
        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["lexueDDLCompletionByID"] as? [String: Bool] == ["eclass:1": true, "eclass:3": false])
        let manual = try #require(json["manualDDLEvents"] as? [[String: Any]])
        #expect(manual.compactMap { $0["id"] as? String } == ["manual"])
        var destination = ScheduleCache()
        destination.ddlEvents = [DDLEventRecord(id: "eclass:1", group: "eclass", title: "local-body", text: "", dueAt: Date(), done: false)]
        state.apply(to: &destination)
        #expect(destination.ddlEvents.first(where: { $0.id == "eclass:1" })?.title == "local-body")
        #expect(destination.ddlEvents.first(where: { $0.id == "eclass:1" })?.done == true)
    }

    private final class Local {
        var account = ScheduleCloudAccount(studentID: "A", session: AppStorageSession(accountIdentifier: "A"), generation: 1)
        var cache = ScheduleCache()
        var sources: [ScheduleCacheSaveSource] = []
        var statuses: [ScheduleCloudSyncStatus] = []
        var failsSave = false
        var persistence: SchedulePersistenceStore?
        private var saveWaiter: CheckedContinuation<Void, Never>?
        var resolutions: [@Sendable (ScheduleCacheConflictResolution?) async -> Void] = []

        init() {
            cache.iCloudSyncEnabled = true
            cache.updatedAt = Date(timeIntervalSince1970: 30)
            cache.primaryScheduleTitle = "local"
        }

        var store: ScheduleCloudLocalStore {
            ScheduleCloudLocalStore(
                currentAccount: { self.account },
                load: { session in await MainActor.run { session == self.account.session ? .loaded(self.cache) : .missing } },
                save: { value, source, account, expected in
                    guard account == self.account, expected == nil || expected == self.cache.updatedAt,
                          !self.failsSave else { return false }
                    if let persistence = self.persistence {
                        guard let saved = await persistence.write(value,
                            accountIdentifier: account.session.accountStorageIdentifier,
                            legacyAccountIdentifier: account.session.legacyAccountDirectoryNameForMigration,
                            source: source, expectedUpdatedAt: expected) else { return false }
                        self.cache = saved
                    } else {
                        self.cache = value
                    }
                    self.sources.append(source)
                    self.saveWaiter?.resume(); self.saveWaiter = nil
                    return true
                }
            )
        }

        func useDiskPersistence() async throws {
            let store = SchedulePersistenceStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/sync-tests"),
                userStateMatches: ScheduleCloudSyncState.matches)
            cache = try #require(await store.write(cache, accountIdentifier: account.session.accountStorageIdentifier,
                legacyAccountIdentifier: account.session.legacyAccountDirectoryNameForMigration,
                source: .cloudBaseline, expectedUpdatedAt: nil))
            persistence = store
        }

        func waitForSave() async {
            if !sources.isEmpty { return }
            await withCheckedContinuation { saveWaiter = $0 }
        }

        func manager(_ transport: Cloud) -> ScheduleCloudSyncManager {
            ScheduleCloudSyncManager(local: store, transport: transport,
                                     presentConflict: { _, resolve in self.resolutions.append(resolve) },
                                     reportStatus: { account, status in if account == self.account { self.statuses.append(status) } })
        }
    }

    private actor Cloud: ScheduleCloudTransport {
        var remote: ScheduleCloudRecord?
        var saved: [ScheduleCloudRecord] = []
        var readGate: CheckedContinuation<Void, Never>?
        var saveGate: CheckedContinuation<Void, Never>?
        var entryWaiter: CheckedContinuation<Void, Never>?
        var entered = false
        let holdRead: Bool
        let holdSave: Bool
        var conflict: ScheduleCloudRecord?
        let available: Bool
        let failsRead: Bool
        var failsSaving: Bool = false

        init(remote: ScheduleCloudRecord? = nil, holdRead: Bool = false, holdSave: Bool = false,
             conflict: ScheduleCloudRecord? = nil, available: Bool = true, failsRead: Bool = false) {
            self.remote = remote
            self.holdRead = holdRead
            self.holdSave = holdSave
            self.conflict = conflict
            self.available = available
            self.failsRead = failsRead
        }

        func setSavingFailure(_ value: Bool) { failsSaving = value }
        func replaceRemote(_ record: ScheduleCloudRecord) { remote = record }
        func accountAvailable() async throws -> Bool { available }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }
        func resume() {
            readGate?.resume(); readGate = nil
            saveGate?.resume(); saveGate = nil
        }
        private func signal() {
            entered = true
            entryWaiter?.resume(); entryWaiter = nil
        }
        func record(named name: String) async throws -> ScheduleCloudRecord {
            if failsRead { throw URLError(.notConnectedToInternet) }
            if holdRead && !entered {
                await withCheckedContinuation { readGate = $0; signal() }
            }
            guard let remote else { throw ScheduleCloudTransportError.unknownItem }
            return remote
        }
        func save(_ record: ScheduleCloudRecord) async throws -> ScheduleCloudRecord {
            if failsSaving { throw URLError(.notConnectedToInternet) }
            if let conflict {
                remote = conflict
                self.conflict = nil
                throw ScheduleCloudTransportError.serverRecordChanged
            }
            saved.append(record)
            if holdSave {
                await withCheckedContinuation { saveGate = $0; signal() }
            }
            var result = record
            result.modificationDate = Date(timeIntervalSince1970: 60)
            result.recordChangeTag = "saved-tag"
            remote = result
            return result
        }
    }

    private struct Envelope: Encodable {
        let schemaVersion: Int
        let payload: Payload
        struct Payload: Encodable {
            let updatedAt: Date
            let state: ScheduleCloudSyncState
        }
    }

    private func record(title: String, updatedAt: TimeInterval, tag: String = "remote-tag",
                        studentID: String = "A", version: Int = 2, recordName: String = "schedule-cache-A",
                        timeTable: [TimeSlot] = TimeSlot.default) throws -> ScheduleCloudRecord {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = title
        cache.updatedAt = Date(timeIntervalSince1970: updatedAt)
        cache.timeTable = timeTable
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(Envelope(schemaVersion: version, payload: .init(updatedAt: cache.updatedAt, state: ScheduleCloudSyncState(cache: cache))))
        return ScheduleCloudRecord(recordName: recordName, recordType: "ScheduleCacheSyncRecord",
            studentID: studentID, updatedAt: cache.updatedAt, payloadJSON: String(decoding: payload, as: UTF8.self),
            modificationDate: cache.updatedAt, recordChangeTag: tag, systemFields: Data("lock-token".utf8))
    }

    @Test func keepingLocalConflictPersistsTheNewBaselineThroughTheProductionRepository() async throws {
        let local = Local()
        local.cache.cloudSyncBaselineAt = Date(timeIntervalSince1970: 20)
        local.cache.cloudSyncBaselineRecordTag = "base-tag"
        local.cache.hasUnpushedCloudChanges = true
        try await local.useDiskPersistence()
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40))
        let manager = local.manager(cloud)
        await manager.pushLatestLocalCacheIfNeeded()
        let resolve = try #require(local.resolutions.first)
        await resolve(.keepLocal)
        #expect(local.resolutions.count == 1)
        #expect(await cloud.saved.count == 1)
        #expect(local.sources == [.cloudBaseline, .cloud])
        let restored = try #require(await local.persistence?.load(for: local.account.session).cacheIfReadable)
        #expect(restored.primaryScheduleTitle == "local")
        #expect(restored.cloudSyncBaselineRecordTag == "saved-tag")
        #expect(restored.hasUnpushedCloudChanges == false)
    }

    @Test(arguments: [false, true])
    func invalidRemoteDuringConflictChoiceAllowsTheSameConflictToBeRetried(futureSchema: Bool) async throws {
        let local = Local()
        local.cache.cloudSyncBaselineAt = Date(timeIntervalSince1970: 20)
        local.cache.hasUnpushedCloudChanges = true
        let valid = try record(title: "remote", updatedAt: 40)
        let cloud = Cloud(remote: valid)
        let manager = local.manager(cloud)
        await manager.refreshFromCloudIfNeeded()
        let first = try #require(local.resolutions.first)
        let invalid = try record(title: "remote", updatedAt: 40, studentID: futureSchema ? "A" : "B", version: futureSchema ? 3 : 2)
        await cloud.replaceRemote(invalid)
        await first(.useCloud)
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
        if case .failed? = local.statuses.last {} else { Issue.record("远端验证失败需要发布失败状态") }
        await cloud.replaceRemote(valid)
        await manager.refreshFromCloudIfNeeded()
        #expect(local.resolutions.count == 2)
        let retry = try #require(local.resolutions.last)
        await retry(.useCloud)
        #expect(local.cache.primaryScheduleTitle == "remote")
        #expect(local.sources == [.cloud])
        #expect(local.statuses.last == .synchronized)
    }

    @Test func mergedChangesStayPendingOnDiskAfterUploadFailureAndRetrySuccessfully() async throws {
        let local = Local()
        let base = local.cache
        local.cache.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: base)
        local.cache.cloudSyncBaselineRecordTag = "base-tag"
        local.cache.hasUnpushedCloudChanges = true
        local.cache.ddlEvents = [.init(id: "local", group: "main", title: "local", text: "", dueAt: Date(), done: false)]
        try await local.useDiskPersistence()
        var remote = base
        remote.updatedAt = Date(timeIntervalSince1970: 40)
        remote.ddlEvents = [.init(id: "remote", group: "main", title: "remote", text: "", dueAt: Date(), done: false)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(schemaVersion: 2, payload: .init(updatedAt: remote.updatedAt, state: .init(cache: remote))))
        let cloud = Cloud(remote: ScheduleCloudRecord(recordName: local.account.recordName,
            recordType: "ScheduleCacheSyncRecord", studentID: "A", updatedAt: remote.updatedAt,
            payloadJSON: String(decoding: data, as: UTF8.self), modificationDate: remote.updatedAt, recordChangeTag: "remote-tag"))
        await cloud.setSavingFailure(true)
        let manager = local.manager(cloud)
        await manager.pushLatestLocalCacheIfNeeded()
        let retained = try #require(await local.persistence?.load(for: local.account.session).cacheIfReadable)
        #expect(retained.hasUnpushedCloudChanges)
        #expect(retained.cloudSyncBaselineRecordTag == "remote-tag")
        #expect(Set(retained.ddlEvents.map(\.id)) == ["local", "remote"])
        #expect(local.sources == [.cloudBaseline])
        await cloud.setSavingFailure(false)
        await manager.pushLatestLocalCacheIfNeeded()
        #expect(local.cache.hasUnpushedCloudChanges == false)
        #expect(Set(local.cache.ddlEvents.map(\.id)) == ["local", "remote"])
        #expect(await cloud.saved.count == 1)
    }

    @Test(arguments: [false, true])
    func concurrentIndependentDDLChangesMergeThroughBothSyncEntrypoints(push: Bool) async throws {
        let local = Local()
        let base = local.cache
        local.cache.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: base)
        local.cache.cloudSyncBaselineRecordTag = "baseline-tag"
        local.cache.hasUnpushedCloudChanges = true
        local.cache.ddlEvents = [.init(id: "local", group: "main", title: "local", text: "", dueAt: Date(timeIntervalSince1970: 100), done: false)]
        var remote = base
        remote.updatedAt = Date(timeIntervalSince1970: 40)
        remote.ddlEvents = [.init(id: "remote", group: "main", title: "remote", text: "", dueAt: Date(timeIntervalSince1970: 200), done: false)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(schemaVersion: 2, payload: .init(updatedAt: remote.updatedAt, state: .init(cache: remote))))
        let record = ScheduleCloudRecord(recordName: "schedule-cache-A", recordType: "ScheduleCacheSyncRecord", studentID: "A",
            updatedAt: remote.updatedAt, payloadJSON: String(decoding: data, as: UTF8.self), modificationDate: remote.updatedAt,
            recordChangeTag: "remote-tag")
        let cloud = Cloud(remote: record)
        let manager = local.manager(cloud)
        if push { await manager.pushLatestLocalCacheIfNeeded() }
        else { await manager.refreshFromCloudIfNeeded() }
        #expect(Set(local.cache.ddlEvents.map(\.id)) == ["local", "remote"])
        #expect(local.resolutions.isEmpty)
        #expect(local.cache.hasUnpushedCloudChanges == false)
        #expect(local.cache.syncData.cloudSyncBaselineUserState != nil)
        #expect(await cloud.saved.count == 1)
    }

    @Test func remoteApplyUsesTheInjectedLocalOwnerAndPreservesSchoolData() async throws {
        let local = Local()
        local.cache.currentTerm = "school-term"
        local.cache.courseData.store(TermScheduleSnapshot(term: "school-term", firstDayString: "", courses: [], exams: [], updatedAt: .distantPast))
        let manager = local.manager(Cloud(remote: try record(title: "remote", updatedAt: 40)))
        await manager.refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "remote")
        #expect(local.cache.currentTerm == "school-term")
        #expect(local.cache.cachedCoursesByTerm.keys.contains("school-term"))
        #expect(local.cache.cloudSyncBaselineRecordTag == "remote-tag")
        #expect(local.sources == [.cloud])
    }

    @Test func delayedRemoteReadHonorsTheAccountGenerationAcrossRoundTripSwitches() async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.refreshFromCloudIfNeeded() }
        await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(studentID: "A", session: local.account.session, generation: 3)
        await cloud.resume()
        await task.value
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshRequestedDuringAccountSwitchRunsForTheCurrentOwner() async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "A remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let first = Task { await manager.refreshFromCloudIfNeeded() }
        await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(studentID: "B", session: AppStorageSession(accountIdentifier: "B"), generation: 2)
        local.cache.primaryScheduleTitle = "B local"
        await cloud.replaceRemote(try record(title: "B remote", updatedAt: 40, studentID: "B", recordName: "schedule-cache-B"))
        await manager.refreshFromCloudIfNeeded()
        await cloud.resume()
        await first.value
        await local.waitForSave()
        #expect(local.cache.primaryScheduleTitle == "B remote")
        #expect(local.sources == [.cloud])
    }

    @Test func localEditsDuringCloudSaveKeepTheirDirtyStateAndReceiveTheBaseline() async {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        let cloud = Cloud(holdSave: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.pushLatestLocalCacheIfNeeded() }
        await cloud.waitForEntry()
        local.cache.primaryScheduleTitle = "continued edit"
        local.cache.updatedAt = Date(timeIntervalSince1970: 45)
        await cloud.resume()
        await task.value
        #expect(local.cache.primaryScheduleTitle == "continued edit")
        #expect(local.cache.updatedAt == Date(timeIntervalSince1970: 45))
        #expect(local.cache.hasUnpushedCloudChanges)
        #expect(local.cache.cloudSyncBaselineRecordTag == "saved-tag")
        #expect(local.sources == [.cloudBaseline])
    }

    @Test func optimisticLockConflictRefetchesAndUsesTheInjectedDecision() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        local.cache.cloudSyncBaselineRecordTag = "old-tag"
        let cloud = Cloud(remote: try record(title: "old", updatedAt: 20, tag: "old-tag"),
                          conflict: try record(title: "concurrent remote", updatedAt: 40))
        let manager = local.manager(cloud)
        await manager.pushLatestLocalCacheIfNeeded()
        #expect(local.resolutions.count == 1)
        let resolve = try #require(local.resolutions.first)
        await resolve(.useCloud)
        #expect(local.cache.primaryScheduleTitle == "concurrent remote")
        #expect(local.cache.hasUnpushedCloudChanges == false)
        #expect(local.sources == [.cloud])
    }

    @Test func invalidIdentityAndFuturePayloadVersionsPreserveLocalState() async throws {
        for remote in [try record(title: "wrong account", updatedAt: 40, studentID: "B"),
                       try record(title: "future", updatedAt: 40, version: 3),
                       try record(title: "repeated sections", updatedAt: 40, timeTable: [
                        TimeSlot(id: 1, start: "08:00", end: "08:45"), TimeSlot(id: 1, start: "09:00", end: "09:45")])] {
            let local = Local()
            let cloud = Cloud(remote: remote)
            await local.manager(cloud).refreshFromCloudIfNeeded()
            #expect(local.cache.primaryScheduleTitle == "local")
            #expect(local.sources.isEmpty)
            #expect(await cloud.saved.isEmpty)
        }
    }

    @Test func localCompareAndSaveFailurePreservesCache() async throws {
        let local = Local()
        local.failsSave = true
        await local.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
    }

    @Test func uploadingAnExistingRecordCarriesItsProviderLockToken() async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "old", updatedAt: 20))
        await local.manager(cloud).pushLatestLocalCacheIfNeeded()
        let saved = try #require(await cloud.saved.first)
        #expect(saved.systemFields == Data("lock-token".utf8))
        #expect(saved.recordName == "schedule-cache-A")
        #expect(local.cache.cloudSyncBaselineRecordTag == "saved-tag")
    }
    @Test func cloudStatusReportsSuccessAndLocalSaveDeferral() async throws {
        let saved = Local()
        await saved.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(saved.statuses == [.syncing, .synchronized])
        let deferred = Local()
        deferred.failsSave = true
        await deferred.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(deferred.statuses.last == .pending)
        #expect(deferred.cache.primaryScheduleTitle == "local")
    }

    @Test func cloudStatusPreservesFailureAndUnavailableAccountResults() async {
        let local = Local()
        await local.manager(Cloud(failsRead: true)).refreshFromCloudIfNeeded()
        guard case .failed(let reason)? = local.statuses.last else {
            Issue.record("A cloud transport failure must reach the status consumer")
            return
        }
        #expect(!reason.isEmpty)
        let unavailable = Local()
        let cloud = Cloud(available: false)
        await unavailable.manager(cloud).pushLatestLocalCacheIfNeeded()
        #expect(unavailable.statuses == [.unavailable])
        #expect(await cloud.saved.isEmpty)
    }

}
