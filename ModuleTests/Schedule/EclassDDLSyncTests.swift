import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import StorageCore
import Testing
@testable import ScheduleFeature

@MainActor
struct EclassDDLSyncTests {
    @Test func overdueEclassVisibilityFollowsTheConfiguredRetentionWindow() async {
        var cache = ScheduleCache()
        var overdue = event("eclass:overdue", group: "eclass")
        overdue.dueAt = Date().addingTimeInterval(-24 * 3600)
        cache.ddlEvents = [overdue]
        cache.ddlAfterDay = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        let model = ScheduleDDLViewModel(service: Service(payload: DDLSyncPayload(url: "", events: [])), repository: repository)
        await repository.loadIfNeeded()
        #expect(model.visibleDDLEvents.isEmpty)
        #expect(model.ddlEmptyStateMessage.contains("1 条日程"))
        model.setDDLAfterDay(7)
        #expect(model.visibleDDLEvents.map(\.id) == ["eclass:overdue"])
    }

    @Test func mergingBothSourcesKeepsCompletionManualItemsAndUniqueIDs() {
        let manual = event("manual", group: "main", done: true)
        let lexue = event("lexue-id", group: "lexue", done: true)
        let eclass = event("eclass:1", group: "eclass", done: true)
        let result = ScheduleDDLEditor.mergingSyncedEvents(
            [event("eclass:1", group: "eclass"), event("eclass:1", group: "eclass"), event("lexue-id", group: "lexue")],
            into: [manual, lexue, eclass, event("eclass:old", group: "eclass")], syncedGroups: ["lexue", "eclass"])
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.done })
        #expect(result.contains(manual))
    }

    @Test func emptySuccessfulSourceClearsItsEventsAndKeepsOtherSources() {
        let manual = event("manual", group: "main")
        let lexue = event("lexue", group: "lexue")
        let result = ScheduleDDLEditor.mergingSyncedEvents([], into: [manual, lexue, event("eclass:1", group: "eclass")], syncedGroups: ["eclass"])
        #expect(Set(result.map(\.id)) == ["manual", "lexue"])
    }

    @Test func completedEclassStatePersistsAcrossEmptyAndRestoredSnapshots() async {
        var cache = ScheduleCache()
        cache.ddlEvents = [event("eclass:1", group: "eclass", done: true), event("manual", group: "main")]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value })
        let service = Service(payload: DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"]))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        await repository.loadIfNeeded()
        #expect(await model.syncDDL())
        #expect(saved?.ddlEvents.map(\.id) == ["manual"])
        #expect(saved?.lexueDDLCompletionByID["eclass:1"] == true)
        service.payload = DDLSyncPayload(url: "", events: [event("eclass:1", group: "eclass")], syncedGroups: ["eclass"])
        #expect(await model.syncDDL())
        #expect(saved?.ddlEvents.first(where: { $0.id == "eclass:1" })?.done == true)
    }

    @Test func sourceFailurePreservesTheOwnedCacheAndUpdateTime() async {
        var cache = ScheduleCache()
        cache.ddlEvents = [event("eclass:1", group: "eclass", done: true)]
        cache.ddlUpdatedAt = Date(timeIntervalSince1970: 100)
        var saves = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in saves += 1 })
        let service = Service(payload: DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"]))
        service.error = ScheduleServiceError.eclassAuthenticationFailed
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        await repository.loadIfNeeded()
        #expect(await model.syncDDL() == false)
        #expect(model.cache.ddlEvents == cache.ddlEvents)
        #expect(model.cache.ddlUpdatedAt == cache.ddlUpdatedAt)
        #expect(saves == 0)
        #expect(model.notice?.message.contains("课程中心") == true)
    }

    @Test func partialSuccessRetainsFailedSourceAndReportsPartialUpdate() async {
        var cache = ScheduleCache()
        cache.ddlEvents = [event("lexue", group: "lexue", done: true), event("eclass:1", group: "eclass")]
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        let service = Service(payload: DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"], warnings: ["乐学：请求失败"]))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        await repository.loadIfNeeded()
        #expect(await model.syncDDL() == false)
        #expect(model.cache.ddlEvents.map(\.id) == ["lexue"])
        #expect(model.notice?.title == "DDL 部分更新")
    }

    @Test func nativeSMSChallengeUsesTheSharedVerificationPresentation() async {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .missing }, save: { _, _, _ in })
        let service = Service(payload: DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"]))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        await repository.loadIfNeeded()
        service.error = ScheduleServiceError.schoolSecondFactorRequired
        #expect(await model.syncDDL() == false)
        #expect(model.notice?.message.contains("短信") == true)
    }

    private func event(_ id: String, group: String, done: Bool = false) -> DDLEventRecord {
        DDLEventRecord(id: id, group: group, title: "作业", text: "课名", dueAt: Date(timeIntervalSince1970: 200), done: done)
    }

    private final class Service: ScheduleDDLServicing {
        var payload: DDLSyncPayload
        var error: Error?
        var syncCalls = 0
        init(payload: DDLSyncPayload) { self.payload = payload }
        func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
            syncCalls += 1
            if let error { throw error }
            return payload
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "" }
    }
}
