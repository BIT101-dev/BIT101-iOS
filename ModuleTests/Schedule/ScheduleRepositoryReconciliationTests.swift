import BIT101TestSupport
import Combine
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct ScheduleRepositoryReconciliationTests {
    @Test(.timeLimit(.minutes(1)))
    func eventWaitFinishesOnTimeoutCancellationAndReadiness() async throws {
        await #expect(throws: URLError.self) {
            try await waitForTestEvent(timeout: .milliseconds(1)) { false }
        }
        do {
            try await waitForTestEvent { throw URLError(.networkConnectionLost) }
            Issue.record("事件读取失败需要传播原始错误。")
        } catch { #expect((error as? URLError)?.code == .networkConnectionLost) }
        let waiting = Task { try await waitForTestEvent { false } }
        waiting.cancel()
        do { try await waiting.value; Issue.record("取消等待需要抛出取消错误。") }
        catch { #expect(error is CancellationError) }
        var ready = false
        let producer = Task { ready = true }
        try await waitForTestEvent { ready }
        await producer.value
        var pending: CheckedContinuation<Void, Never>?
        var completed = false
        let suspended = Task {
            await withCheckedContinuation { pending = $0 }
            completed = true
        }
        try await waitForTestEvent { pending != nil }
        func missingEvent() async throws {
            defer { suspended.cancel(); pending?.resume(); pending = nil }
            try await waitForTestEvent(timeout: .milliseconds(1)) { false }
        }
        await #expect(throws: URLError.self) { try await missingEvent() }
        try await waitForTestEvent { completed }
        await suspended.value
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondConflictChoiceWaitsForTheSubmittedChoice() async throws {
        let account = AppStorageSession(accountIdentifier: "choice-queue")
        var disk = ScheduleCache()
        var pauseRead = false
        var pending: CheckedContinuation<Void, Never>?
        let repository = ScheduleRepository(session: { account }, load: { _ in
            if pauseRead { await withCheckedContinuation { pending = $0 } }
            return .loaded(disk)
        }, save: { cache, _, _ in
            guard cache.cloudSyncBaselineRecordTag == disk.cloudSyncBaselineRecordTag else { throw CocoaError(.fileWriteUnknown) }
            disk = cache
        })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "本机"
        disk.primaryScheduleTitle = "同步"
        disk.cloudSyncBaselineRecordTag = "new-version"
        #expect(await repository.persistAndWait() == false)
        pauseRead = true
        let choice = Task { await repository.resolvePersistenceConflict(.keepLocal) }
        defer { pauseRead = false; choice.cancel(); pending?.resume(); pending = nil }
        try await waitForTestEvent { !(pending == nil) }
        #expect(repository.isResolvingPersistenceConflict)
        await repository.resolvePersistenceConflict(.useCloud)
        pauseRead = false
        pending?.resume()
        pending = nil
        await choice.value
        #expect(disk.primaryScheduleTitle == "本机" && !repository.isResolvingPersistenceConflict)
    }

    private func write(_ cache: ScheduleCache, to store: SchedulePersistenceStore,
                       account: AppStorageSession, source: ScheduleCacheSaveSource = .cloud) async throws {
        guard await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration,
            source: source, expectedUpdatedAt: nil) != nil else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ScheduleCacheSaveSource.local, .localWithoutCloudPush], [false, true])
    func cloudWritesDuringTheQueuePreserveIndependentEditsAndResumeSaving(source: ScheduleCacheSaveSource, queuedEdit: Bool) async throws {
        let account = AppStorageSession(accountIdentifier: "repository-rebase")
        let store = SchedulePersistenceStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/repository-rebase"),
            userStateMatches: ScheduleCloudSyncState.matches)
        var initial = ScheduleCache()
        initial.iCloudSyncEnabled = true
        initial.cloudSyncBaselineRecordTag = "initial"
        initial.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: initial)
        try await write(initial, to: store, account: account)
        let changes = PassthroughSubject<AppStorageSession, Never>()
        var pending: CheckedContinuation<Void, Never>?
        var writes = 0
        var pauseWrite = true
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) },
            save: { cache, source, owner in
                writes += 1
                if writes == 1 && pauseWrite { await withCheckedContinuation { pending = $0 } }
                try await write(cache, to: store, account: owner, source: source)
            }, changes: changes.eraseToAnyPublisher())
        await repository.loadIfNeeded()
        repository.presentationPreferences.showSunday = false
        let saving = Task { await repository.persistAndWait(source: source) }
        defer { pauseWrite = false; saving.cancel(); pending?.resume(); pending = nil }
        try await waitForTestEvent { !(pending == nil) }
        var remote = initial
        remote.primaryScheduleTitle = "同步标题"
        remote.cloudSyncBaselineRecordTag = "remote"
        remote.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: remote)
        try await write(remote, to: store, account: account)
        changes.send(account)
        await repository.reload()
        var second: Task<Bool, Never>?
        if queuedEdit {
            repository.presentationPreferences.showSaturday = false
            second = Task { await repository.persistAndWait(source: source) }
            await Task.yield()
        }
        pending?.resume()
        pending = nil
        _ = await saving.value
        if let second { #expect(await second.value) }
        else { #expect(repository.notice == nil) }
        let result = try #require(await store.load(for: account).cacheIfReadable)
        #expect(result.primaryScheduleTitle == "同步标题" && result.showSunday == false)
        #expect(result.showSaturday == !queuedEdit && result.cloudSyncBaselineRecordTag == "remote")
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "同步标题")
        repository.presentationPreferences.showExamInfo = false
        #expect(await repository.persistAndWait())
        #expect(await store.load(for: account).cacheIfReadable?.showExamInfo == false)
    }

    @Test(arguments: [ScheduleCacheConflictResolution.keepLocal, .useCloud])
    func explicitConflictChoiceRetainsIndependentChangesAndTheNextSave(resolution: ScheduleCacheConflictResolution) async throws {
        let account = AppStorageSession(accountIdentifier: "repository-choice")
        let store = SchedulePersistenceStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/repository-choice"),
            userStateMatches: ScheduleCloudSyncState.matches)
        var initial = ScheduleCache()
        initial.cloudSyncBaselineRecordTag = "initial"
        try await write(initial, to: store, account: account)
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) },
            save: { cache, source, owner in try await write(cache, to: store, account: owner, source: source) })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "本机标题"
        repository.presentationPreferences.showSunday = false
        var remote = initial
        remote.primaryScheduleTitle = "同步标题"
        remote.showSaturday = false
        remote.cloudSyncBaselineRecordTag = "remote"
        try await write(remote, to: store, account: account)
        #expect(await repository.persistAndWait() == false && repository.hasPersistenceConflict)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "本机标题")
        await repository.resolvePersistenceConflict(resolution)
        #expect(repository.hasPersistenceConflict == false)
        let saved = try #require(await store.load(for: account).cacheIfReadable)
        #expect(saved.primaryScheduleTitle == (resolution == .keepLocal ? "本机标题" : "同步标题"))
        #expect(saved.showSunday == false && saved.showSaturday == false)
        repository.presentationPreferences.showExamInfo = false
        #expect(await repository.persistAndWait())
    }
}
