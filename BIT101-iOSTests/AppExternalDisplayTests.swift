import Foundation
import ScheduleDomain
import ScheduleContracts
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct AppExternalDisplayTests {
    @Test(arguments: [false, true])
    func localSchoolSessionsKeepExtensionsAvailableDuringCommunityAuthenticationRecovery(communityExpired: Bool) throws {
        let storage = AppAccountSession.storage
        defer { _ = storage.clearAllLocalData() }
        if communityExpired {
            try storage.saveLoginState(studentID: "external-school", password: "fixture", fakeCookie: "fixture")
            storage.requireCommunityAuthentication()
        } else { try storage.saveSchoolLoginState(studentID: "external-school", password: "fixture") }
        var cache = ScheduleCache()
        cache.ddlEvents = [.init(id: "school", group: "lexue", title: "学校作业", text: "", dueAt: .distantFuture, done: false)]
        let snapshot = try #require(ScheduleWidgetExporter.makeSnapshot(cache: cache, session: AppFileDirectories.currentSession))
        #expect(storage.fakeCookie.isEmpty && snapshot.isLoggedIn && snapshot.deadlines.map(\.id) == ["school"])
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot).contentState == .ready)
        #expect(AppRestoreReadiness.sessionIsReady(.signedIn(studentID: "external-school"), storage: storage))
        #expect(!AppRestoreReadiness.sessionIsReady(.signedOut, storage: storage))
        storage.clearSession()
        let loggedOut = try #require(ScheduleWidgetExporter.makeSnapshot(cache: cache, session: AppFileDirectories.currentSession))
        #expect(!loggedOut.isLoggedIn && loggedOut.deadlines.isEmpty)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: loggedOut).contentState == .loggedOut)
        #expect(AppRestoreReadiness.sessionIsReady(.signedOut, storage: storage))
        #expect(!AppRestoreReadiness.sessionIsReady(.signedIn(studentID: "external-school"), storage: storage))
    }

    private final class Context {
        var session = AppStorageSession(accountIdentifier: "selected-display")
        var signedIn = true
        var resolved = true
        var events: [String] = []
        var exportAction: (() async -> Void)?
        let refreshDate = Date(timeIntervalSince1970: 100)

        func adapter() -> AppExternalDisplayCoordinator {
            AppExternalDisplayCoordinator(currentSession: { self.session }, isSessionResolved: { self.resolved }, isSignedIn: { self.signedIn },
                activateWatch: { self.events.append("activate") }, resetPresentation: { self.events.append("reset") },
                exportWidget: { self.events.append("widget"); await self.exportAction?() },
                nextReminderRefresh: { self.events.append("next"); return self.refreshDate },
                scheduleBackgroundRefresh: { self.events.append($0 == self.refreshDate ? "schedule" : "clear") },
                endActivities: { self.events.append("end") }, refreshActivities: { self.events.append($0) })
        }
    }

    @Test(.timeLimit(.minutes(1))) func selectedCapabilitiesOwnSignedInAndSignedOutRefreshes() async {
        let context = Context()
        let adapter = context.adapter()
        adapter.activate()
        adapter.resetAccountPresentation()
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: context.session)
        #expect(context.events == ["activate", "reset", "widget", "next", "schedule", "refresh"])
        context.events = []
        context.signedIn = false
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: false, session: context.session)
        #expect(context.events == ["clear", "end"])
    }

    @Test(.timeLimit(.minutes(1))) func pendingCredentialsKeepPublishedDisplaysUntilRecoveryOrExplicitLogout() async {
        let context = Context()
        context.resolved = false
        context.signedIn = false
        let adapter = context.adapter()
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: context.session)
        #expect(context.events.isEmpty)
        context.resolved = true
        context.signedIn = true
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: context.session)
        #expect(context.events == ["widget", "next", "schedule", "refresh"])
        context.events = []
        context.signedIn = false
        await adapter.refresh(trigger: "logout", syncWidgetSnapshot: true, session: context.session)
        #expect(context.events == ["widget", "clear", "end"])
    }

    @Test(.timeLimit(.minutes(1))) func suspendedRefreshChecksAccountAndCancellationBeforeSystemEffects() async throws {
        for boundary in ["cancel", "account", "pending"] {
            let context = Context()
            var resume: CheckedContinuation<Void, Never>?
            context.exportAction = {
                await withCheckedContinuation {
                    resume = $0
                }
            }
            let adapter = context.adapter()
            let owner = context.session
            let task = Task { await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: owner) }
            try await waitForTestEvent { resume != nil }
            if boundary == "cancel" { task.cancel() }
            if boundary == "account" { context.session = AppStorageSession(accountIdentifier: "changed") }
            if boundary == "pending" { context.resolved = false }
            resume?.resume()
            await task.value
            #expect(context.events == ["widget"])
        }
    }
}
