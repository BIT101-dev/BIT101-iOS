import Foundation
import ScheduleDomain
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct ReminderContextTests {
    @Test func delayedCacheLoadHonorsItsCapturedAccountGeneration() async {
        var current = ScheduleReminderSession(studentID: "A", storage: AppStorageSession(accountIdentifier: "A"), generation: 1, signedIn: true)
        var loadContinuation: CheckedContinuation<ScheduleCache, Never>?
        var enteredContinuation: CheckedContinuation<Void, Never>?
        let context = ScheduleReminderContext(currentSession: { current }, loadCache: { captured in
            #expect(captured.accountIdentifier == "A")
            return await withCheckedContinuation {
                loadContinuation = $0
                enteredContinuation?.resume(); enteredContinuation = nil
            }
        })
        let task = Task { await context.loadCurrentCache() }
        await withCheckedContinuation { enteredContinuation = $0 }
        current = ScheduleReminderSession(studentID: "A", storage: current.storage, generation: 3, signedIn: true)
        loadContinuation?.resume(returning: ScheduleCache())
        #expect(await task.value == nil)
    }

    @Test func currentSnapshotUsesTheInjectedAccountPartition() async {
        let session = ScheduleReminderSession(studentID: "B", storage: AppStorageSession(accountIdentifier: "B"), generation: 1, signedIn: true)
        let context = ScheduleReminderContext(currentSession: { session }, loadCache: { storage in
            #expect(storage == session.storage)
            var cache = ScheduleCache()
            cache.primaryScheduleTitle = "injected reminder"
            return cache
        })
        let value = await context.loadCurrentCache()
        #expect(value?.session == session)
        #expect(value?.cache.primaryScheduleTitle == "injected reminder")
    }
}
