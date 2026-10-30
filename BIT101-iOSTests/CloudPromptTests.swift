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

    @Test(.timeLimit(.minutes(1))) func cloudAssetWritesRemainSerializedAcrossSuspension() async throws {
        let queue = AppScheduleCloudUploadQueue(), activity = SaveActivity()
        try await withThrowingTaskGroup(of: ScheduleCloudRecord.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try await queue.run {
                        await activity.begin()
                        await Task.yield()
                        await activity.end()
                        return ScheduleCloudRecord(recordName: "record-\(index)", recordType: "ScheduleCacheSyncRecord")
                    }
                }
            }
            var names: Set<String> = []
            for try await record in group { names.insert(record.recordName) }
            #expect(names.count == 16)
        }
        #expect(await activity.maximum == 1)
    }
    private actor SaveActivity {
        private var active = 0
        var maximum = 0
        func begin() { active += 1; maximum = max(maximum, active) }
        func end() { active -= 1 }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCloudAccountNotificationInvalidatesAnAlreadyPresentedChoice() async throws {
        let center = NotificationCenter()
        let generation = AppCloudAccountGeneration(center: center)
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts,
            currentIdentity: { identity }, currentCloudGeneration: { generation.value })
        let decisions = Decisions()
        present(account, .init(signature: "cloud-owner", hasCommonBaseline: false)) { await decisions.record($0) }
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
        present(account, .init(signature: "same-conflict", hasCommonBaseline: false)) { await decisions.record($0) }
        let first = try #require(prompts.activePrompt)
        #expect(first.account == identity)
        prompts.alertPresentationChanged(isPresented: false, promptID: prompts.activePrompt?.id)
        try await waitForTestEvent { decisions.values.count == 1 }
        #expect(decisions.values == [nil])
        present(account, .init(signature: "same-conflict", hasCommonBaseline: false)) { _ in }
        let second = try #require(prompts.activePrompt)
        #expect(first.id != second.id)
        #expect(second.title == first.title)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["keep-local", "use-cloud", "later", "account-change"], [false, true])
    func conflictActionsAndAccountCancellationResolveExactlyOnce(action: String, hasCommonBaseline: Bool) async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier, generation: account.generation)
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts, currentIdentity: { identity })
        let decisions = Decisions()
        present(account, .init(signature: "conflict", hasCommonBaseline: hasCommonBaseline)) { await decisions.record($0) }
        let prompt = try #require(prompts.activePrompt)
        #expect(prompt.message.contains(hasCommonBaseline ? "独立修改" : "首次关联"))
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
        for signature in ["first", "second"] { present(account, .init(signature: signature, hasCommonBaseline: false)) { await decisions.record($0) } }
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
        present(account, .init(signature: "delayed", hasCommonBaseline: false)) { await decisions.record($0) }
        try await waitForTestEvent { decisions.values.count == 1 }
        #expect(decisions.values == [nil])
        #expect(prompts.activePrompt == nil)
    }
}
