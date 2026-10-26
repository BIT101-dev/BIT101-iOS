import BIT101TestSupport
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
    @Test func manualDDLPhotosPersistAndRemainEditable() throws {
        let image = DDLImageAttachment(data: Data([1, 2, 3]))
        var draft = DDLDraft(title: "论文", dueAt: Date(timeIntervalSince1970: 100), text: "要求", images: [image])
        let added = try ScheduleDDLEditor.adding(draft, to: [], id: "ddl")
        var cache = ScheduleCache(); cache.ddlEvents = added
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.ddlEvents.first?.images == [image])
        #expect(ScheduleDDLEditor.draft(for: restored.ddlEvents.first) == draft)
        draft.title = "修改标题"
        let edited = try ScheduleDDLEditor.updating(id: "ddl", with: draft, in: restored.ddlEvents)
        #expect(edited.first?.images == [image] && edited.first?.title == "修改标题")
        #expect(ScheduleDDLEditor.togglingDone(id: "ddl", in: edited).first?.images == [image])
        draft.images = []
        #expect(try ScheduleDDLEditor.updating(id: "ddl", with: draft, in: edited).first?.images == nil)
        draft.images = [image, image]
        #expect(throws: (any Error).self) { try ScheduleDDLEditor.adding(draft, to: []) }
        draft.images = (0...DDLImagePolicy.maximumImageCount).map { _ in DDLImageAttachment(data: Data([1])) }
        #expect(throws: (any Error).self) { try ScheduleDDLEditor.adding(draft, to: []) }
    }

    @Test(arguments: [
        ("lexue", "作业 已到期", "作业"),
        ("lexue", "  实验报告   已到期 \n", "实验报告"),
        ("lexue", "已到期任务说明", "已到期任务说明"),
        ("lexue", "作业", "作业"),
        ("lexue", "已到期", "已到期"),
        ("eclass", "作业 已到期", "作业 已到期"),
        ("main", "作业 已到期", "作业 已到期"),
    ])
    func deadlineDisplayTitlesFollowTheirSourceAndPreserveStoredContent(
        group: String, title: String, expected: String
    ) throws {
        let event = DDLEventRecord(id: "title", group: group, title: title, text: "课程与作业描述",
            dueAt: .distantFuture, done: true)
        #expect(event.displayTitle == expected)
        let restored = try JSONDecoder().decode(DDLEventRecord.self, from: JSONEncoder().encode(event))
        #expect(restored == event)
        #expect(restored.title == title && restored.displayTitle == expected)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func blockedDDLStorageReportsFailureBeforeSchoolRequests(loading: Bool) async {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .unreadable }, save: { _, _, _ in })
        if !loading { await repository.loadIfNeeded() }
        let service = Service(payload: DDLSyncPayload(url: "", events: []))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        #expect(await model.syncDDL() == false && service.syncCalls == 0)
        let before = model.beforeDay, after = model.afterDay
        #expect(!model.setDDLBeforeDay(before + 1) && !model.setDDLAfterDay(after + 1))
        #expect(model.beforeDay == before && model.afterDay == after)
        #expect(model.notice?.message.contains(loading ? "正在读取" : "重试读取") == true)
        await model.refreshLexueCalendarURL()
        #expect(service.subscriptionCalls == 0 && model.notice?.message.contains(loading ? "正在读取" : "重试读取") == true)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledDDLResponsesPreserveMemoryAndDisk() async {
        var cache = ScheduleCache()
        cache.ddlEvents = [event("existing", group: "manual")]
        var saves = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in saves += 1 })
        await repository.loadIfNeeded()
        let service = Service(payload: DDLSyncPayload(url: "", events: [event("late", group: "eclass")]))
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        var operation: Task<Bool, Never>?
        service.beforeReturn = { operation?.cancel() }
        operation = Task { await model.syncDDL() }
        #expect(await operation?.value == false)
        #expect(model.cache.ddlEvents.map(\.id) == ["existing"] && saves == 0 && model.notice == nil)
    }

    @Test(.timeLimit(.minutes(1))) func overdueEclassVisibilityFollowsTheConfiguredRetentionWindow() async {
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

    @Test(.timeLimit(.minutes(1)), arguments: ["main", "lexue", "eclass"])
    func visibleDeadlinesKeepRecentOverdueItemsAheadOfOlderOnes(group: String) async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func deadline(_ id: String, _ offset: TimeInterval, done: Bool = false) -> DDLEventRecord {
            .init(id: id, group: group, title: id, text: "", dueAt: now.addingTimeInterval(offset), done: done)
        }
        var cache = ScheduleCache()
        cache.ddlAfterDay = 7
        cache.ddlEvents = [
            deadline("later", 7_200), deadline("older", -7_200),
            deadline("done-older", -10_800, done: true), deadline("recent", -3_600),
            deadline("soon", 3_600), deadline("done-recent", -1_800, done: true),
            deadline("due-now", 0), deadline("outside-retention", -8 * 86_400),
        ]
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "ddl-order") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        let model = ScheduleDDLViewModel(service: Service(payload: DDLSyncPayload(url: "", events: [])), repository: repository)
        await repository.loadIfNeeded()
        #expect(model.visibleDDLEvents(at: now).map(\.id)
            == ["recent", "older", "due-now", "soon", "later", "done-recent", "done-older"])
        #expect(model.visibleDDLEvents(at: now.addingTimeInterval(8_000)).map(\.id)
            == ["later", "soon", "due-now", "recent", "older", "done-recent", "done-older"])
    }

    @Test(.timeLimit(.minutes(1))) func advancingTheClockUpdatesCountdownTintAndRetention() async {
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

    @Test(.timeLimit(.minutes(1))) func completedEclassStatePersistsAcrossEmptyAndRestoredSnapshots() async {
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

    @Test(.timeLimit(.minutes(1))) func sourceFailurePreservesTheOwnedCacheAndUpdateTime() async {
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

    @Test(.timeLimit(.minutes(1))) func partialSuccessRetainsFailedSourceAndReportsPartialUpdate() async {
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

    @Test(.timeLimit(.minutes(1))) func nativeSMSChallengeUsesTheSharedVerificationPresentation() async {
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
        try await waitForTestEvent { !(model.schoolSMSWaitID == nil) }
        let oldID = try #require(model.schoolSMSWaitID)
        model.dismissSchoolSMSCode()
        _ = try? await first.value
        let request = SchoolSMSCodeRequest(maskedPhone: "second", purpose: "DDL")
        let second = Task { try await handler(request) }
        try await waitForTestEvent { !(model.schoolSMSWaitID == nil) }
        model.cancelSchoolSMSWait(matching: oldID)
        #expect(model.schoolSMSCodeRequest?.id == request.id)
        model.submitSchoolSMSCode("123456")
        #expect(try await second.value == "123456")
        let third = Task { try await handler(request) }
        try await waitForTestEvent { !(model.schoolSMSWaitID == nil) }
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
        var subscriptionCalls = 0
        var beforeReturn: (() -> Void)?
        init(payload: DDLSyncPayload) { self.payload = payload }
        func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?, onSource: DDLSyncSourceDelivery?) async throws -> DDLSyncPayload {
            syncCalls += 1
            if let error { throw error }
            beforeReturn?()
            return payload
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { subscriptionCalls += 1; return "" }
    }
}
