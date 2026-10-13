import Foundation
import os
import ScoreDomain
import Testing
@testable import BIT101_iOS

@Suite(.serialized)
@MainActor
struct PreferenceCloudPayloadTests {
    @Test(arguments: ["missing", "stale", "usable"])
    func openingAnExistingCloudPayloadRestoresItsActiveKeyForReuse(boundary: String) throws {
        let domain = "BIT101UnitTests.preference-payload-key"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let keys = PreferenceMemoryScoreKeys()
        let encryption = ScoreCacheSyncEncryption(defaults: defaults, credentials: keys)
        let account = "payload-test", activeKey = "experimental.preference-cloud-sync.score-key.payload-test"
        let plaintext = Data("score-payload".utf8)
        let encrypted = try encryption.prepareSeal(account: account)(plaintext)
        let identifier = try #require(defaults.string(forKey: activeKey))
        defaults.removeObject(forKey: activeKey)
        if boundary == "stale" {
            defaults.set("00000000-0000-0000-0000-000000000001", forKey: activeKey)
            #expect(throws: ScoreSyncEncryptionError.self) { try encryption.prepareSeal(account: account) }
        } else if boundary == "usable" {
            _ = try encryption.prepareSeal(account: account)(Data("local".utf8))
        }
        let previousKey = defaults.string(forKey: activeKey)
        #expect(try encryption.prepareOpen(encrypted, account: account)() == plaintext)
        #expect(defaults.string(forKey: activeKey) == previousKey)
        try encryption.acceptReceivedKey(from: encrypted, account: account)
        #expect(defaults.string(forKey: activeKey) == (boundary == "usable" ? previousKey : identifier))
        let sealedAgain = try encryption.prepareSeal(account: account)(plaintext)
        #expect(keys.values.count == (boundary == "usable" ? 2 : 1))
        #expect(try encryption.prepareOpen(sealedAgain, account: account)() == plaintext)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["prepared", "authentication", "payload"], [false, true])
    func unfinishedOrInvalidCloudReadsPreserveTheActiveKey(boundary: String, stalePointer: Bool) async throws {
        let domain = "BIT101UnitTests.preference-payload-key"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let encryption = ScoreCacheSyncEncryption(defaults: defaults, credentials: PreferenceMemoryScoreKeys())
        let activeKey = "experimental.preference-cloud-sync.score-key.payload-test"
        var data = try encryption.seal(Data("invalid-envelope".utf8), account: "payload-test")
        defaults.removeObject(forKey: activeKey)
        if stalePointer { defaults.set("00000000-0000-0000-0000-000000000001", forKey: activeKey) }
        let previousKey = defaults.string(forKey: activeKey)
        if boundary == "authentication" { data[data.endIndex - 1] ^= 1 }
        let open = try encryption.prepareOpen(data, account: "payload-test")
        if boundary != "prepared" {
            await #expect(throws: (any Error).self) {
                try await PreferenceCloudPayloadCodec.decode(ScoreCacheSyncPayload.self, open: open)
            }
        }
        #expect(defaults.string(forKey: activeKey) == previousKey)
    }

    @Test(.timeLimit(.minutes(1))) func encryptedPayloadWorkRunsOutsideTheUIExecutor() async throws {
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
