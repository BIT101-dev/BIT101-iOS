import CommunityTransport
import CloudKit
import ScheduleDomain
import ScheduleSync
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct CloudPromptTests {
    private let account = ScheduleCloudAccount(studentID: "A", session: .init(accountIdentifier: "A@BIT101"), generation: 1)

    @Test(.timeLimit(.minutes(1)))
    func aCloudAccountNotificationInvalidatesAnAlreadyPresentedChoice() async throws {
        let center = NotificationCenter()
        let generation = AppCloudAccountGeneration(center: center)
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts,
            currentIdentity: { identity }, currentCloudGeneration: { generation.value })
        let decisions = Decisions()
        present(account, "cloud-owner") { await decisions.record($0) }
        let prompt = try #require(prompts.activePrompt)
        await Task.detached { center.post(name: .CKAccountChanged, object: nil) }.value
        #expect(generation.value == 1)
        prompts.perform(try #require(prompt.actions.first { $0.id == "use-cloud" }), promptID: prompt.id)
        try await waitForTestEvent { decisions.values.count == 1 }
        #expect(decisions.values == [nil])
        #expect(prompts.activePrompt == nil)
    }

    @MainActor private final class Decisions {
        var values: [ScheduleCacheConflictResolution?] = []
        func record(_ value: ScheduleCacheConflictResolution?) { values.append(value) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aDismissedConflictCanBePresentedAgainThroughTheAppAdapter() async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        prompts.markHostReady()
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts, currentIdentity: { identity })
        let decisions = Decisions()
        present(account, "same-conflict") { await decisions.record($0) }
        let first = try #require(prompts.activePrompt)
        #expect(first.account == identity)
        prompts.alertPresentationChanged(isPresented: false, promptID: prompts.activePrompt?.id)
        try await waitForTestEvent { decisions.values.count == 1 }
        #expect(decisions.values == [nil])
        present(account, "same-conflict") { _ in }
        let second = try #require(prompts.activePrompt)
        #expect(first.id != second.id)
        #expect(second.title == first.title)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["keep-local", "use-cloud", "later", "account-change"])
    func conflictActionsAndAccountCancellationResolveExactlyOnce(action: String) async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts, currentIdentity: { identity })
        let decisions = Decisions()
        present(account, "conflict") { await decisions.record($0) }
        let prompt = try #require(prompts.activePrompt)
        if action == "account-change" {
            prompts.accountDidChange(to: CommunitySessionIdentity(accountIdentifier: "B", generation: 2))
        } else {
            prompts.perform(try #require(prompt.actions.first { $0.id == action }), promptID: prompt.id)
        }
        prompts.alertPresentationChanged(isPresented: false, promptID: prompt.id)
        prompts.perform(try #require(prompt.actions.first), promptID: prompt.id)
        try await waitForTestEvent { decisions.values.count == 1 }
        let expected: ScheduleCacheConflictResolution? = action == "keep-local" ? .keepLocal : action == "use-cloud" ? .useCloud : nil
        #expect(decisions.values == [expected])
        #expect(prompts.activePrompt == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func accountChangeCancelsQueuedConflictsAndPreservesTheGlobalPrompt() async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        prompts.enqueue(AppPrompt(id: "global", title: "global", message: "fixture", actions: []))
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts, currentIdentity: { identity })
        let decisions = Decisions()
        for signature in ["first", "second"] { present(account, signature) { await decisions.record($0) } }
        prompts.accountDidChange(to: CommunitySessionIdentity(accountIdentifier: "B", generation: 2))
        try await waitForTestEvent { decisions.values.count == 2 }
        #expect(decisions.values == [nil, nil])
        #expect(prompts.activePrompt?.id == "global")
        prompts.alertPresentationChanged(isPresented: false, promptID: "global")
        #expect(prompts.activePrompt == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["B", "A@BIT101"])
    func delayedConflictKeepsItsOriginalAccountAndGeneration(currentAccount: String) async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let current = CommunitySessionIdentity(accountIdentifier: currentAccount, generation: 2)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts, currentIdentity: { current })
        let decisions = Decisions()
        present(account, "delayed") { await decisions.record($0) }
        try await waitForTestEvent { decisions.values.count == 1 }
        #expect(decisions.values == [nil])
        #expect(prompts.activePrompt == nil)
    }
}
