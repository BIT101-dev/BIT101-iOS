import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import StorageCore
import Testing
import TransportCore
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
        #expect(model.visibleDDLEvents().isEmpty)
        #expect(model.ddlEmptyStateMessage.contains("1 条日程"))
        model.setDDLAfterDay(7)
        #expect(model.visibleDDLEvents().map(\.id) == ["eclass:overdue"])
    }

    @Test func advancingTheClockUpdatesCountdownTintAndRetention() async {
        var cache = ScheduleCache()
        var deadline = event("manual", group: "main")
        deadline.dueAt = Date(timeIntervalSince1970: 1000)
        cache.ddlEvents = [deadline]
        cache.ddlBeforeDay = 1
        cache.ddlAfterDay = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "clock") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        let model = ScheduleDDLViewModel(service: Service(payload: DDLSyncPayload(url: "", events: [])), repository: repository)
        await repository.loadIfNeeded()
        let before = deadline.dueAt.addingTimeInterval(-30), after = deadline.dueAt.addingTimeInterval(30)
        #expect(model.ddlRemainingText(for: deadline, now: before) == "剩余 0分钟")
        #expect(model.ddlRemainingText(for: deadline, now: after) == "已过 0分钟")
        #expect(model.ddlTint(for: deadline, now: before) == "orange")
        #expect(model.ddlTint(for: deadline, now: after) == "red")
        #expect(model.visibleDDLEvents(at: before).map(\.id) == [deadline.id])
        #expect(model.visibleDDLEvents(at: after).isEmpty)
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
        cache.ddlEvents = [event("eclass:1", group: "eclass", done: true), event("eclass:2", group: "eclass"), event("manual", group: "main")]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value })
        let service = Service(payload: DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"]))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        await repository.loadIfNeeded()
        #expect(await model.syncDDL())
        #expect(saved?.ddlEvents.map(\.id) == ["manual"])
        #expect(saved?.lexueDDLCompletionByID["eclass:1"] == true)
        #expect(saved?.lexueDDLCompletionByID.count == 1)
        service.payload = DDLSyncPayload(url: "", events: (1...100).map { event("eclass:\($0)", group: "eclass") }, syncedGroups: ["eclass"])
        #expect(await model.syncDDL())
        #expect(saved?.ddlEvents.first(where: { $0.id == "eclass:1" })?.done == true)
        #expect(saved?.lexueDDLCompletionByID.count == 1)
        model.toggleDDLDone(model.cache.ddlEvents.first(where: { $0.id == "eclass:1" }) ?? event("eclass:1", group: "eclass"))
        service.payload = DDLSyncPayload(url: "", events: [], syncedGroups: ["eclass"])
        #expect(await model.syncDDL())
        #expect(saved?.lexueDDLCompletionByID == ["eclass:1": false])
        service.payload = DDLSyncPayload(url: "", events: [event("eclass:1", group: "eclass")], syncedGroups: ["eclass"])
        #expect(await model.syncDDL())
        #expect(saved?.ddlEvents.first(where: { $0.id == "eclass:1" })?.done == false)
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

    @Test(.timeLimit(.minutes(1)))
    func staleSMSCleanupPreservesTheNextWaitAndCurrentCancellationCompletes() async throws {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "sms") },
            load: { _ in .missing }, save: { _, _, _ in })
        let model = ScheduleDDLViewModel(service: Service(payload: DDLSyncPayload(url: "", events: [])), repository: repository)
        let handler = model.makeSchoolSMSCodeHandler()
        let first = Task { try await handler(SchoolSMSCodeRequest(maskedPhone: "first", purpose: "DDL")) }
        while model.schoolSMSWaitID == nil { await Task.yield() }
        let oldID = try #require(model.schoolSMSWaitID)
        model.dismissSchoolSMSCode()
        _ = try? await first.value
        let request = SchoolSMSCodeRequest(maskedPhone: "second", purpose: "DDL")
        let second = Task { try await handler(request) }
        while model.schoolSMSWaitID == nil { await Task.yield() }
        model.cancelSchoolSMSWait(matching: oldID)
        #expect(model.schoolSMSCodeRequest?.id == request.id)
        model.submitSchoolSMSCode("123456")
        #expect(try await second.value == "123456")
        let third = Task { try await handler(request) }
        while model.schoolSMSWaitID == nil { await Task.yield() }
        third.cancel()
        do {
            _ = try await third.value
            Issue.record("The current SMS wait must finish with cancellation.")
        } catch { #expect(TaskCancellation.matches(error)) }
        #expect(model.schoolSMSWaitID == nil)
        #expect(model.schoolSMSCodeRequest == nil)
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
