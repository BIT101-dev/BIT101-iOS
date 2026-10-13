import BIT101TestSupport
import SchedulePersistence
import Foundation
@testable import ScheduleDomain
@testable import ScheduleSync
import StorageCore
import Testing

@MainActor
struct ScheduleSyncTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["id", "duplicate", "title", "text", "source", "rule", "replacement"])
    func invalidManualCloudRecordsPreserveLocalData(kind: String) async throws {
        let event = DDLEventRecord(id: kind == "id" ? "" : "ddl", group: kind == "source" ? "lexue" : "main",
            title: kind == "title" ? " \n" : "作业",
            text: kind == "text" ? String(repeating: "x", count: 4097) : "",
            dueAt: Date(timeIntervalSince1970: 100), done: false)
        var rules: [String: [ScheduleCourseRule]] = [:]
        if kind == "rule" || kind == "replacement" {
            let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "课程", weekday: 1, weeksText: "1"),
                to: [], term: "term", id: "course")
            let rule = ScheduleCourseRule(id: "rule", sourceIdentity: "local:course", sourceCourses: [],
                replacementCourses: kind == "replacement" ? courses + courses : courses)
            rules = ["term": kind == "rule" ? [rule, rule] : [rule]]
        }
        let local = Local(), cloud = Cloud(remote: try record(title: "damaged", updatedAt: 40,
            manualDDLEvents: kind == "duplicate" ? [event, event] : [event], manualCourseRules: rules))
        await local.manager(cloud).refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "local" && local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidPersonalCloudRecordsPreserveLocalData(duplicate: Bool) async throws {
        let event = CustomScheduleRecord(id: "event", title: "活动", subtitle: "", description: "",
            dateString: duplicate ? "2026-09-07" : "bad-date", beginTime: "12:00", endTime: "13:00")
        let local = Local(), cloud = Cloud(remote: try record(title: "damaged", updatedAt: 40,
            customSchedules: duplicate ? [event, event] : [event]))
        await local.manager(cloud).refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "local" && local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
    }
    @Test(.timeLimit(.minutes(1))) func previousCloudEnvelopeMigratesToTheRecurringScheduleSchema() async throws {
        let local = Local()
        let date = Date(timeIntervalSince1970: 40)
        // v2 的字段固定在样本中，迁移输入独立于当前模型编码。
        let payloadJSON = """
        {"schemaVersion":2,"payload":{"updatedAt":"1970-01-01T00:00:40Z","state":{
            "primaryScheduleTitle":"remote","manualCourseRulesByTerm":{},"manualDDLEvents":[],
            "lexueDDLCompletionByID":{},
            "customSchedules":[{"id":"legacy-event","title":"旧版活动","subtitle":"地点","description":"说明",
                "dateString":"2026-09-09","beginTime":"12:00","endTime":"13:00"}],
            "ddlBeforeDay":1,"ddlAfterDay":30,"selectedCampusName":"良乡校区","selectedCampusCode":"2",
            "selectedBuildingID":"building","selectedClassroomSectionIDs":[1],"isClassroomSectionFilterCustomized":true,
            "showSaturday":true,"showSunday":true,"showExamInfo":true,
            "scheduleDisplayMode":"weekly","scheduleCardContentMode":"nameAndLocation",
            "showCourseLiveActivityReminder":true,"courseLiveActivityLeadMinutes":10,
            "timeTable":[{"id":1,"start":"08:00","end":"08:45"}],"sharedSchedules":[]
        }}}
        """
        let cloud = Cloud(remote: ScheduleCloudRecord(recordName: "schedule-cache-A", recordType: "ScheduleCacheSyncRecord",
            studentID: "A", updatedAt: date, payloadJSON: payloadJSON, modificationDate: date,
            recordChangeTag: "remote-tag", systemFields: Data("lock-token".utf8)))
        await local.manager(cloud).refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "remote")
        let event = try #require(local.cache.customSchedules.first)
        #expect(event.id == "legacy-event" && event.dateString == "2026-09-09" && event.additionalDateStrings == nil)
        #expect(local.cache.selectedCampusName == "良乡校区" && local.cache.courseLiveActivityLeadMinutes == 10)
        #expect(local.statuses.last == .synchronized)
        try await waitForTestEvent(isolation: cloud) { $0.saved.count == 1 }
        let saved = try #require(await cloud.saved.last)
        let json = try #require(saved.payloadJSON)
        #expect(try JSONDecoder().decode(EnvelopeVersion.self, from: Data(json.utf8)).schemaVersion == 3)
    }
    private struct EnvelopeVersion: Decodable { let schemaVersion: Int }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func manualTransferAndRecurringSchedulesSurviveCloudReceiveAndSchoolRefresh(wholeCourse: Bool) async throws {
        let phone = Local(), other = Local(), cloud = Cloud()
        let source = try ScheduleCourseEditor.adding(CourseDraft(title: "原课程", weekday: 1, weeksText: "1-4"),
            to: [], term: "term", id: "phone-school")
        let snapshot = TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: source, exams: [], updatedAt: Date(timeIntervalSince1970: 20))
        phone.cache.currentTerm = "term"
        phone.cache.courseData.store(snapshot)
        let moved = try wholeCourse
            ? ScheduleCourseEditor.updatingArrangement(id: source[0].id,
                with: CourseDraft(title: "原课程", weekday: 3, weeksText: "1-4"), in: source)
            : ScheduleCourseEditor.transferring(courses: source,
                fromWeek: 1, fromWeekday: 1, toWeek: 1, toWeekday: 3)
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &phone.cache,
            previousCourses: source, currentCourses: moved)
        phone.cache.customSchedules = [.init(id: "recurring", title: "活动", subtitle: "", description: "",
            dateString: "2026-09-09", beginTime: "12:10", endTime: "12:40", additionalDateStrings: ["2026-09-16"])]
        phone.cache.hasUnpushedCloudChanges = true
        await phone.manager(cloud).pushLatestLocalCacheIfNeeded()
        #expect(phone.statuses.last == .synchronized)
        other.cache.currentTerm = "term"
        other.cache.courseData.store(snapshot)
        await other.manager(cloud).refreshFromCloudIfNeeded()
        #expect(other.statuses.last == .synchronized)
        #expect(other.cache.courses.contains { $0.weekday == 3 && $0.weeks == (wholeCourse ? [1, 2, 3, 4] : [1]) })
        #expect(other.cache.courses.contains { $0.weekday == 1 && $0.weeks == [2, 3, 4] } == !wholeCourse)
        #expect(other.cache.customSchedules == phone.cache.customSchedules)
        let refreshed = try ScheduleCourseEditor.adding(CourseDraft(title: "原课程", weekday: 1, weeksText: "1-4"),
            to: [], term: "term", id: "other-school")
        other.cache.courseData.store(TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: refreshed, exams: [], updatedAt: Date(timeIntervalSince1970: 80)))
        #expect(other.cache.manualCourseRulesByTerm == phone.cache.manualCourseRulesByTerm)
        #expect(other.cache.courses.contains { $0.weekday == 3 && $0.weeks == (wholeCourse ? [1, 2, 3, 4] : [1]) })
    }

    @Test(.timeLimit(.minutes(1))) func oversizedUserStatePreservesLocalEditsAndReportsCloudCapacity() async {
        let local = Local()
        local.cache.ddlEvents = [DDLEventRecord(id: "manual", group: "main",
            title: String(repeating: "日", count: ScheduleCloudRecord.maximumPayloadBytes / 3), text: "", dueAt: Date(), done: false)]
        local.cache.hasUnpushedCloudChanges = true
        let before = local.cache
        let cloud = Cloud()
        await local.manager(cloud).pushLatestLocalCacheIfNeeded()
        #expect(await cloud.saved.isEmpty)
        #expect(local.cache.ddlEvents == before.ddlEvents && local.cache.hasUnpushedCloudChanges)
        #expect(local.cache.updatedAt == before.updatedAt && local.sources.isEmpty)
        #expect(local.statuses.last == .failed(ScheduleCloudTransportError.capacityExceeded.localizedDescription))
    }

    @Test func absentSchoolCompletionHistoryExpiresAndMergesAcrossDevices() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var original = ScheduleCache()
        original.lexueDDLCompletionByID = ["eclass:gone": true, "eclass:active": false, "lexue-unavailable": true]
        original.ddlData.reconcileCompletionHistory(currentIDs: ["eclass:active"], syncedGroups: ["eclass"], now: now)
        #expect(original.ddlData.schoolDDLCompletionRetiredAtByID == ["eclass:gone": now])
        let baseline = try ScheduleCloudStateMerge.baseline(for: original)
        var retired = original
        retired.ddlData.reconcileCompletionHistory(currentIDs: ["eclass:active"], syncedGroups: ["eclass"],
            now: now.addingTimeInterval(2 * 366 * 24 * 3_600))
        let merged = try #require(try ScheduleCloudStateMerge.merge(local: .init(cache: original), remote: .init(cache: retired), baseline: baseline))
        var restored = original
        merged.apply(to: &restored)
        #expect(restored.lexueDDLCompletionByID == ["eclass:active": false, "lexue-unavailable": true])
        #expect(restored.ddlData.schoolDDLCompletionRetiredAtByID?.isEmpty != false)
        var first = original, second = original
        first.ddlData.schoolDDLCompletionRetiredAtByID = ["eclass:gone": now.addingTimeInterval(1)]
        second.ddlData.schoolDDLCompletionRetiredAtByID = ["eclass:gone": now.addingTimeInterval(2)]
        let independent = try #require(try ScheduleCloudStateMerge.merge(local: .init(cache: first), remote: .init(cache: second), baseline: baseline))
        #expect(independent.schoolDDLCompletionRetiredAtByID?["eclass:gone"] == now.addingTimeInterval(1))
    }

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
        var resolutions: [@Sendable (ScheduleCacheConflictResolution?) async -> Void] = []
        var conflictAccounts: [ScheduleCloudAccount] = []

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

        func waitForSave() async throws {
            try await waitForTestEvent { sources.isEmpty == false }
        }

        func manager(_ transport: Cloud) -> ScheduleCloudSyncManager {
            ScheduleCloudSyncManager(local: store, transport: transport,
                                     presentConflict: { account, _, resolve in
                                         self.conflictAccounts.append(account)
                                         self.resolutions.append(resolve)
                                     },
                                     reportStatus: { account, status in if account == self.account { self.statuses.append(status) } })
        }
    }

    private actor Cloud: ScheduleCloudTransport {
        var remote: ScheduleCloudRecord?
        var saved: [ScheduleCloudRecord] = []
        var readGate: CheckedContinuation<Void, Never>?
        var saveGate: CheckedContinuation<Void, Never>?
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
        func waitForEntry() async throws {
            try await waitForTestEvent { entered }
        }
        func resume() {
            readGate?.resume(); readGate = nil
            saveGate?.resume(); saveGate = nil
        }
        private func signal() {
            entered = true
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
                        studentID: String = "A", version: Int = 3, recordName: String = "schedule-cache-A",
                        timeTable: [TimeSlot] = TimeSlot.default, manualEventID: String? = nil,
                        customSchedules: [CustomScheduleRecord] = [], manualDDLEvents: [DDLEventRecord]? = nil,
                        manualCourseRules: [String: [ScheduleCourseRule]] = [:]) throws -> ScheduleCloudRecord {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = title
        cache.updatedAt = Date(timeIntervalSince1970: updatedAt)
        cache.timeTable = timeTable
        cache.customSchedules = customSchedules
        cache.manualCourseRulesByTerm = manualCourseRules
        if let manualEventID {
            cache.ddlEvents = [DDLEventRecord(id: manualEventID, group: "main", title: manualEventID,
                text: "", dueAt: Date(timeIntervalSince1970: 100), done: false)]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var state = ScheduleCloudSyncState(cache: cache)
        if let manualDDLEvents { state.manualDDLEvents = manualDDLEvents }
        let payload = try encoder.encode(Envelope(schemaVersion: version, payload: .init(updatedAt: cache.updatedAt, state: state)))
        return ScheduleCloudRecord(recordName: recordName, recordType: "ScheduleCacheSyncRecord",
            studentID: studentID, updatedAt: cache.updatedAt, payloadJSON: String(decoding: payload, as: UTF8.self),
            modificationDate: cache.updatedAt, recordChangeTag: tag, systemFields: Data("lock-token".utf8))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func firstIndependentEditsRequireAChoiceAndDismissalAllowsRetry(push: Bool) async throws {
        let local = Local()
        local.cache.updatedAt = Date(timeIntervalSince1970: 80)
        local.cache.hasUnpushedCloudChanges = true
        local.cache.ddlEvents = [DDLEventRecord(id: "local-ddl", group: "main", title: "local-ddl",
            text: "", dueAt: Date(timeIntervalSince1970: 100), done: false)]
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40, manualEventID: "cloud-ddl"))
        let manager = local.manager(cloud)
        if push { await manager.pushLatestLocalCacheIfNeeded() } else { await manager.refreshFromCloudIfNeeded() }
        #expect(await cloud.saved.isEmpty)
        #expect(local.cache.ddlEvents.map(\.id) == ["local-ddl"] && local.sources.isEmpty)
        #expect(local.conflictAccounts == [local.account] && local.statuses.last == .conflict)
        let resolve = try #require(local.resolutions.first)
        await resolve(nil)
        await resolve(.useCloud)
        #expect(local.cache.ddlEvents.map(\.id) == ["local-ddl"] && local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
        await manager.refreshFromCloudIfNeeded()
        #expect(local.resolutions.count == 2 && local.conflictAccounts == [local.account, local.account])
        #expect(await cloud.saved.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func schoolRefreshKeepsOlderCloudUserEditsAuthoritative(pushFirst: Bool) async throws {
        let local = Local()
        try await local.useDiskPersistence()
        local.cache.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: local.cache)
        local.cache.cloudSyncBaselineRecordTag = "old-tag"
        local.cache = try #require(await local.persistence?.write(local.cache,
            accountIdentifier: local.account.session.accountStorageIdentifier,
            legacyAccountIdentifier: local.account.session.legacyAccountDirectoryNameForMigration,
            source: .cloudBaseline, expectedUpdatedAt: local.cache.updatedAt))
        var refreshed = local.cache
        refreshed.currentTerm = "school-term"
        refreshed.courseData.store(TermScheduleSnapshot(term: "school-term", firstDayString: "2026-09-07",
            courses: [], exams: [], updatedAt: Date(timeIntervalSince1970: 80)))
        refreshed.updatedAt = Date(timeIntervalSince1970: 80)
        local.cache = try #require(await local.persistence?.write(refreshed,
            accountIdentifier: local.account.session.accountStorageIdentifier,
            legacyAccountIdentifier: local.account.session.legacyAccountDirectoryNameForMigration, source: .localWithoutCloudPush,
            expectedUpdatedAt: local.cache.updatedAt))
        #expect(local.cache.hasUnpushedCloudChanges == false)
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40, manualEventID: "cloud-ddl"))
        let manager = local.manager(cloud)
        if pushFirst {
            await manager.pushLatestLocalCacheIfNeeded()
            #expect(await cloud.saved.isEmpty && local.sources.isEmpty)
        }
        await manager.refreshFromCloudIfNeeded()
        #expect(await cloud.saved.isEmpty)
        #expect(local.cache.ddlEvents.map(\.id) == ["cloud-ddl"])
        #expect(local.cache.currentTerm == "school-term" && local.cache.firstDayString == "2026-09-07")
        #expect(local.sources == [.cloud] && local.resolutions.isEmpty)
        #expect(local.statuses.last == .synchronized)
        let persisted = try #require(await local.persistence?.load(for: local.account.session).cacheIfReadable)
        #expect(persisted.ddlEvents.map(\.id) == ["cloud-ddl"] && persisted.hasUnpushedCloudChanges == false)
    }

    @Test(.timeLimit(.minutes(1))) func keepingLocalConflictPersistsTheNewBaselineThroughTheProductionRepository() async throws {
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidRemoteDuringConflictChoiceAllowsTheSameConflictToBeRetried(futureSchema: Bool) async throws {
        let local = Local()
        local.cache.cloudSyncBaselineAt = Date(timeIntervalSince1970: 20)
        local.cache.hasUnpushedCloudChanges = true
        let valid = try record(title: "remote", updatedAt: 40)
        let cloud = Cloud(remote: valid)
        let manager = local.manager(cloud)
        await manager.refreshFromCloudIfNeeded()
        let first = try #require(local.resolutions.first)
        let invalid = try record(title: "remote", updatedAt: 40, studentID: futureSchema ? "A" : "B", version: futureSchema ? 4 : 3)
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

    @Test(.timeLimit(.minutes(1))) func mergedChangesStayPendingOnDiskAfterUploadFailureAndRetrySuccessfully() async throws {
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
        let data = try encoder.encode(Envelope(schemaVersion: 3, payload: .init(updatedAt: remote.updatedAt, state: .init(cache: remote))))
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
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
        let data = try encoder.encode(Envelope(schemaVersion: 3, payload: .init(updatedAt: remote.updatedAt, state: .init(cache: remote))))
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

    @Test(.timeLimit(.minutes(1))) func remoteApplyUsesTheInjectedLocalOwnerAndPreservesSchoolData() async throws {
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

    @Test(.timeLimit(.minutes(1)), arguments: ["student", "cloud"])
    func delayedRemoteReadHonorsTheAccountGenerationAcrossRoundTripSwitches(owner: String) async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.refreshFromCloudIfNeeded() }
        try await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(studentID: "A", session: local.account.session,
            generation: owner == "student" ? 3 : 1, cloudGeneration: owner == "cloud" ? 1 : 0)
        await cloud.resume()
        await task.value
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
        #expect(await cloud.saved.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["apply", "upload", "conflict", "save"])
    func cancelledSyncDiscardsLateTransportResultsAndAllowsFreshReconciliation(stage: String) async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = stage != "apply"
        local.cache.cloudSyncBaselineRecordTag = stage == "conflict" ? "old-tag" : "remote-tag"
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: stage == "apply" || stage == "conflict" ? 40 : 20),
                          holdRead: stage != "save", holdSave: stage == "save")
        let manager = local.manager(cloud)
        let pending = Task {
            if stage == "upload" || stage == "save" { await manager.pushLatestLocalCacheIfNeeded() }
            else { await manager.refreshFromCloudIfNeeded() }
        }
        try await cloud.waitForEntry()
        let statuses = local.statuses
        pending.cancel()
        await cloud.resume()
        await pending.value
        #expect(local.cache.primaryScheduleTitle == "local" && local.sources.isEmpty && local.resolutions.isEmpty)
        #expect(local.statuses == statuses)
        #expect(await cloud.saved.count == (stage == "save" ? 1 : 0))
        await manager.refreshFromCloudIfNeeded()
        if stage == "conflict" { #expect(local.resolutions.count == 1) }
        else {
            #expect(!local.sources.isEmpty && local.cache.hasUnpushedCloudChanges == false)
            #expect(local.cache.primaryScheduleTitle == (stage == "apply" ? "remote" : "local"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefreshRequestedDuringAccountSwitchRunsForTheCurrentOwner() async throws {
        let local = Local()
        let cloud = Cloud(remote: try record(title: "A remote", updatedAt: 40), holdRead: true)
        let manager = local.manager(cloud)
        let first = Task { await manager.refreshFromCloudIfNeeded() }
        try await cloud.waitForEntry()
        local.account = ScheduleCloudAccount(studentID: "B", session: AppStorageSession(accountIdentifier: "B"), generation: 2)
        local.cache.primaryScheduleTitle = "B local"
        await cloud.replaceRemote(try record(title: "B remote", updatedAt: 40, studentID: "B", recordName: "schedule-cache-B"))
        await manager.refreshFromCloudIfNeeded()
        await cloud.resume()
        await first.value
        try await local.waitForSave()
        #expect(local.cache.primaryScheduleTitle == "B remote")
        #expect(local.sources == [.cloud])
    }

    @Test(.timeLimit(.minutes(1))) func localEditsDuringCloudSaveKeepTheirDirtyStateAndReceiveTheBaseline() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        let cloud = Cloud(holdSave: true)
        let manager = local.manager(cloud)
        let task = Task { await manager.pushLatestLocalCacheIfNeeded() }
        try await cloud.waitForEntry()
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

    @Test(.timeLimit(.minutes(1))) func optimisticLockConflictRefetchesAndUsesTheInjectedDecision() async throws {
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

    @Test(.timeLimit(.minutes(1))) func invalidIdentityAndFuturePayloadVersionsPreserveLocalState() async throws {
        for remote in [try record(title: "wrong account", updatedAt: 40, studentID: "B"),
                       try record(title: "future", updatedAt: 40, version: 4),
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [ScheduleCacheConflictResolution.keepLocal, .useCloud])
    func aShorterCloudTablePreservesLocalSchoolCourses(dirty: Bool, choice: ScheduleCacheConflictResolution) async throws {
        let local = Local()
        local.cache.currentTerm = "term"
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "晚间课程", weeksText: "1", selectedSections: [12]),
            to: [], term: "term", id: "school")
        local.cache.courseData.store(.init(term: "term", firstDayString: "", courses: courses, exams: [], updatedAt: Date()))
        local.cache.hasUnpushedCloudChanges = dirty
        let cloud = Cloud(remote: try record(title: "remote", updatedAt: 40,
            timeTable: [.init(id: 1, start: "08:00", end: "08:45")]))
        let manager = local.manager(cloud)
        await manager.refreshFromCloudIfNeeded()
        #expect(local.statuses.last == .conflict && local.sources.isEmpty)
        let resolve = try #require(local.resolutions.first)
        await resolve(choice)
        #expect(local.cache.courses == courses)
        #expect(local.cache.timeTable == TimeSlot.default)
        if choice == .useCloud {
            if case .failed(let message)? = local.statuses.last { #expect(message.contains("保留本机版本")) }
            else { Issue.record("节次差异需要发布调整时间表的失败状态") }
            #expect(local.sources.isEmpty)
            #expect(await cloud.saved.isEmpty)
        } else {
            #expect(local.statuses.last == .synchronized)
            #expect(await cloud.saved.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func localCompareAndSaveFailurePreservesCache() async throws {
        let local = Local()
        local.failsSave = true
        await local.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(local.cache.primaryScheduleTitle == "local")
        #expect(local.sources.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func uploadingAnExistingRecordCarriesItsProviderLockToken() async throws {
        let local = Local()
        local.cache.hasUnpushedCloudChanges = true
        local.cache.cloudSyncBaselineRecordTag = "remote-tag"
        let cloud = Cloud(remote: try record(title: "old", updatedAt: 20))
        await local.manager(cloud).pushLatestLocalCacheIfNeeded()
        let saved = try #require(await cloud.saved.first)
        #expect(saved.systemFields == Data("lock-token".utf8))
        #expect(saved.recordName == "schedule-cache-A")
        #expect(local.cache.cloudSyncBaselineRecordTag == "saved-tag")
    }
    @Test(.timeLimit(.minutes(1))) func cloudStatusReportsSuccessAndLocalSaveDeferral() async throws {
        let saved = Local()
        await saved.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(saved.statuses == [.syncing, .synchronized])
        let deferred = Local()
        deferred.failsSave = true
        await deferred.manager(Cloud(remote: try record(title: "remote", updatedAt: 40))).refreshFromCloudIfNeeded()
        #expect(deferred.statuses.last == .pending)
        #expect(deferred.cache.primaryScheduleTitle == "local")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["readMatch", "pushMatch", "pushNew", "keepLocal", "useCloud"])
    func baselineSaveFailuresRemainVisibleAndAllowRetry(stage: String) async throws {
        let local = Local()
        local.failsSave = true
        local.cache.hasUnpushedCloudChanges = stage != "readMatch"
        let original = local.cache
        let choice = stage == "keepLocal" || stage == "useCloud"
        let cloud = Cloud(remote: stage == "pushNew" ? nil : try record(
            title: choice ? "remote" : "local", updatedAt: 40))
        let manager = local.manager(cloud)
        func synchronize() async throws {
            if stage.hasPrefix("push") { await manager.pushLatestLocalCacheIfNeeded() }
            else {
                await manager.refreshFromCloudIfNeeded()
                if choice {
                    let resolve = try #require(local.resolutions.last)
                    await resolve(stage == "keepLocal" ? .keepLocal : .useCloud)
                }
            }
        }
        try await synchronize()
        if case .failed(let reason)? = local.statuses.last { #expect(reason.contains("保存失败")) }
        else { Issue.record("基线落盘失败需要呈现失败状态") }
        #expect(local.sources.isEmpty && local.cache.cloudSyncBaselineRecordTag == original.cloudSyncBaselineRecordTag)
        #expect(local.cache.primaryScheduleTitle == original.primaryScheduleTitle && local.cache.updatedAt == original.updatedAt)
        #expect(local.cache.hasUnpushedCloudChanges == original.hasUnpushedCloudChanges)
        #expect(await cloud.saved.count == (stage == "pushNew" ? 1 : 0))
        local.failsSave = false
        try await synchronize()
        #expect(local.statuses.last == .synchronized && !local.cache.hasUnpushedCloudChanges)
        #expect(local.cache.cloudSyncBaselineRecordTag == (stage == "pushNew" || stage == "keepLocal" ? "saved-tag" : "remote-tag"))
        #expect(await cloud.saved.count == (stage == "pushNew" || stage == "keepLocal" ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1))) func cloudStatusPreservesFailureAndUnavailableAccountResults() async {
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
