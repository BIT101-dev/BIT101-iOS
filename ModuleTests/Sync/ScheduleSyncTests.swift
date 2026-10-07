import Foundation
import ScheduleDomain
import ScheduleSync
import StorageCore
import Testing

@MainActor
struct ScheduleSyncTests {
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
            DDLEventRecord(id: "manual", group: "main", title: "manual", text: "", dueAt: Date(), done: false),
        ]
        let state = ScheduleCloudSyncState(cache: source)
        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
                    self.cache = value
                    self.sources.append(source)
                    self.saveWaiter?.resume(); self.saveWaiter = nil
                    return true
                }
            )
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

        init(remote: ScheduleCloudRecord? = nil, holdRead: Bool = false, holdSave: Bool = false,
             conflict: ScheduleCloudRecord? = nil, available: Bool = true, failsRead: Bool = false) {
            self.remote = remote
            self.holdRead = holdRead
            self.holdSave = holdSave
            self.conflict = conflict
            self.available = available
            self.failsRead = failsRead
        }

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
                        studentID: String = "A", version: Int = 2, recordName: String = "schedule-cache-A") throws -> ScheduleCloudRecord {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = title
        cache.updatedAt = Date(timeIntervalSince1970: updatedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(Envelope(schemaVersion: version, payload: .init(updatedAt: cache.updatedAt, state: ScheduleCloudSyncState(cache: cache))))
        return ScheduleCloudRecord(recordName: recordName, recordType: "ScheduleCacheSyncRecord",
            studentID: studentID, updatedAt: cache.updatedAt, payloadJSON: String(decoding: payload, as: UTF8.self),
            modificationDate: cache.updatedAt, recordChangeTag: tag, systemFields: Data("lock-token".utf8))
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
                       try record(title: "future", updatedAt: 40, version: 3)] {
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
