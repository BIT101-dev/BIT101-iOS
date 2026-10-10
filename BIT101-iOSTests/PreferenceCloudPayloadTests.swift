import Foundation
import os
import ScoreDomain
import Testing
@testable import BIT101_iOS

@Suite(.serialized)
@MainActor
struct PreferenceCloudPayloadTests {
    @Test func encryptedPayloadWorkRunsOutsideTheUIExecutor() async throws {
        let domain = "BIT101UnitTests.preference-payload"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let encryption = ScoreCacheSyncEncryption(defaults: defaults, credentials: PreferenceMemoryScoreKeys())
        let rows = (0..<2_000).map { ScoreRow(index: $0, headers: ["课程名称", "成绩"], values: ["课程\($0)", "95"]) }
        let payload = ScoreCacheSyncPayload(rows: rows, updatedAt: Date(), detailedUpdatedAt: nil)
        let envelope = ExperimentalPreferenceSyncEnvelope(updatedAt: Date(), payload: payload)
        let seal = try encryption.prepareSeal(account: "payload-test")
        let encrypted = try await PreferenceCloudPayloadCodec.encode(envelope, seal: { data in
            #expect(!Thread.isMainThread)
            return try seal(data)
        })
        let open = try encryption.prepareOpen(encrypted, account: "payload-test")
        let decoded = try await PreferenceCloudPayloadCodec.decode(ScoreCacheSyncPayload.self, open: {
            #expect(!Thread.isMainThread)
            return try open()
        })
        #expect(decoded.payload == payload)
        #expect(ScoreCacheSyncEncryption.isEncrypted(encrypted))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringPayloadWorkKeepsTheUIExecutorAvailable() async throws {
        let envelope = ExperimentalPreferenceSyncEnvelope(updatedAt: Date(), payload: ["name": "value"])
        let data = try JSONEncoder().encode(envelope)
        let release = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        let task = Task {
            try await PreferenceCloudPayloadCodec.decode([String: String].self, open: {
                entered.withLock { $0 = true }
                release.wait()
                return data
            })
        }
        try await waitForTestEvent { entered.withLock { $0 } }
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
