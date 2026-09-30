import SchedulePorts
import ClientCore
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct SchedulePersistenceTests {
    private func store(files: ModuleScoreFiles, root: String = "/schedule") -> SchedulePersistenceStore {
        SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: root), userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
    }

    @Test func independentStoresOwnTheirPathsAndAccounts() async throws {
        let files = ModuleScoreFiles()
        let first = store(files: files, root: "/first")
        let second = store(files: files, root: "/second")
        let account = AppStorageSession(accountIdentifier: "account")
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "first"
        let saved = await first.write(cache, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil)
        #expect(saved?.primaryScheduleTitle == "first")
        #expect(await first.load(for: account).cacheIfReadable?.primaryScheduleTitle == "first")
        #expect(await second.load(for: account).cacheIfReadable?.primaryScheduleTitle == "课表")
        #expect(await first.load(for: AppStorageSession(accountIdentifier: "other")).cacheIfReadable?.primaryScheduleTitle == "课表")
    }

    @Test func corruptedSourceKeepsItsBytesAndWriteGate() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "corrupt")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data("corrupt-source".utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).isUnreadable)
        #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test func failedWritesReturnFailureAndPreserveTheStoredVersion() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "write-failure")
        let initial = ScheduleCache()
        #expect(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        files.setFailures(writing: true)
        var update = initial
        update.primaryScheduleTitle = "edited"
        #expect(await persistence.write(update, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == initial.primaryScheduleTitle)
    }

    @Test func repositoryReportsSaveFailureAndPreservesEdits() async {
        let account = AppStorageSession(accountIdentifier: "repository")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }, cacheDidChange: Notification.Name("persistence-test"), notificationCenter: NotificationCenter())
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "edited"
        #expect(await repository.persistAndWait() == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "edited")
        #expect(repository.notice?.title == "日程保存失败")
    }

    @Test func ddlSuccessWaitsForPersistence() async {
        let account = AppStorageSession(accountIdentifier: "ddl")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }, cacheDidChange: Notification.Name("ddl-persistence-test"), notificationCenter: NotificationCenter())
        await repository.loadIfNeeded()
        let viewModel = ScheduleDDLViewModel(service: DDLService(), repository: repository)
        #expect(await viewModel.syncDDL() == false)
        #expect(viewModel.notice == nil)
        #expect(repository.notice?.title == "日程保存失败")
    }

    private final class DelayedWriter {
        var stored: ScheduleCache?
        var writes: [(String, AppStorageSession)] = []
        var failsFirstWrite = false
        private var started: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Void, Never>?

        func save(_ cache: ScheduleCache, session: AppStorageSession) async throws {
            writes.append((cache.primaryScheduleTitle, session))
            if writes.count == 1 {
                await withCheckedContinuation { completion = $0; started?.resume(); started = nil }
                if failsFirstWrite { throw CocoaError(.fileWriteNoPermission) }
            }
            stored = cache
            stored?.updatedAt = Date(timeIntervalSince1970: Double(writes.count))
        }

        func waitUntilStarted() async {
            if completion != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finishFirstWrite() { completion?.resume(); completion = nil }
    }

    private func repository(writer: DelayedWriter, session: @escaping () -> AppStorageSession) -> ScheduleRepository {
        ScheduleRepository(session: session, load: { _ in writer.stored.map(ScheduleCacheLoadResult.loaded) ?? .missing }, save: { cache, _, session in try await writer.save(cache, session: session) }, cacheDidChange: Notification.Name("queued-persistence"), notificationCenter: NotificationCenter())
    }

    @Test func queuedWritesPreserveOrderAndReloadTheCommittedVersion() async {
        let account = AppStorageSession(accountIdentifier: "queued")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "first"
        repository.persist()
        await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "second"
        repository.persist()
        writer.finishFirstWrite()
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["first", "second", "second"])
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "second")
        #expect(repository.persistenceSnapshot.updatedAt == Date(timeIntervalSince1970: 3))
    }

    @Test func editsMadeDuringSavingRemainInMemory() async {
        let account = AppStorageSession(accountIdentifier: "editing")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "saved"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "editing"
        writer.finishFirstWrite()
        #expect(await saving.value)
        #expect(writer.stored?.primaryScheduleTitle == "saved")
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "editing")
    }

    @Test func cancelledWaiterKeepsCommittedDataAndReturnsCancellationOutcome() async {
        let account = AppStorageSession(accountIdentifier: "cancelled-waiter")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "committed-edit"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        saving.cancel()
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(writer.stored?.primaryScheduleTitle == "committed-edit")
        #expect(repository.notice == nil)
    }

    @Test func oldAccountFailuresAndQueuedWritesStayWithTheirOwner() async {
        var account = AppStorageSession(accountIdentifier: "old")
        let writer = DelayedWriter()
        writer.failsFirstWrite = true
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "old-edit"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        repository.persist()
        account = AppStorageSession(accountIdentifier: "current")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "current-edit"
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["old-edit", "current-edit"])
        #expect(writer.writes.last?.1 == account)
        #expect(repository.notice == nil)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "current-edit")
    }

    private struct DDLService: ScheduleDDLServicing {
        func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
            DDLSyncPayload(url: "https://example.invalid/calendar", events: [])
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "https://example.invalid/calendar" }
    }
}
