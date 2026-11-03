import ClientCore
import Combine
import CommunityCore
import CommunityPersistence
import CommunityTransport
import DesignSystemKit
import Foundation
import ScheduleDomain
import ScoreDomain
import ScorePorts
import StorageCore
import Testing
import TransportCore
import os

@testable import BIT101_iOS
@testable import CommunityUI
@testable import GalleryFeature
@testable import MediaKit
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import ScoreInfrastructure

extension ExperimentalPreferenceCloudSyncTests {
    @Test(.timeLimit(.minutes(1))) func authoritativeEmptyScoreClearsStore() async throws {
        let senderDomain = preferenceDomain + ".sender"
        let (sender, senderDefaults, senderCloud, senderAccount) = try context(
            domain: senderDomain, synchronizedDomains: [.scoreCache])
        let (receiver, receiverDefaults, receiverCloud, receiverAccount) = try context(
            synchronizedDomains: [.scoreCache])
        defer {
            senderDefaults.removePersistentDomain(forName: senderDomain)
            receiverDefaults.removePersistentDomain(forName: preferenceDomain)
        }
        let old = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await receiver.stores.scoreCache.applySynced(old, for: nil, replacing: nil))
        await receiver.refreshFromCloudIfNeeded()?.value
        await sender.refreshFromCloudIfNeeded()?.value
        #expect(await sender.stores.scoreCache.saveDetailed(rows: [], for: nil) != nil)
        await sender.refreshFromCloudIfNeeded()?.value
        let payload = try #require(try await sender.stores.scoreCache.syncPayload(for: nil))
        #expect(
            payload.rows.isEmpty && payload.updatedAt != nil && payload.detailedUpdatedAt != nil)
        let encrypted = try #require(
            senderCloud.data(forKey: key(.scoreCache, account: senderAccount)))
        #expect(ScoreCacheSyncEncryption.isEncrypted(encrypted))
        receiverCloud.scoreKeys.values = senderCloud.scoreKeys.values
        receiverCloud.set(encrypted, forKey: key(.scoreCache, account: receiverAccount))
        await receiver.refreshFromCloudIfNeeded()?.value
        #expect(try await receiver.stores.scoreCache.syncPayload(for: nil) == payload)
        let envelope = try sender.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: encrypted)
        let versionKey =
            """
            experimental.preference-cloud-sync.local-updated.\
            \(receiverAccount.session.accountStorageIdentifier).\
            \(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)
            """
        #expect(receiverDefaults.object(forKey: versionKey) as? Date == envelope.updatedAt)
        await receiver.refreshFromCloudIfNeeded()?.value
        #expect(try await receiver.stores.scoreCache.syncPayload(for: nil) == payload)
    }

    @Test(.timeLimit(.minutes(1))) func plaintextScoreMigration() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let recordKey = key(.scoreCache, account: account)
        let payload = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        let clear = try ScoreCacheSyncPayloadCodec.encode(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: Date(timeIntervalSince1970: 200), payload: payload))
        cloud.set(clear, forKey: recordKey)
        await sync.refreshFromCloudIfNeeded()?.value
        let encrypted = try #require(cloud.data(forKey: recordKey))
        #expect(ScoreCacheSyncEncryption.isEncrypted(encrypted))
        #expect(try await sync.stores.scoreCache.syncPayload(for: nil) == payload)
        let savedKeys = cloud.scoreKeys.values
        cloud.scoreKeys.values = [:]
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue?.contains("钥匙串") == true)
        #expect(cloud.data(forKey: recordKey) == encrypted)
        #expect(try await sync.stores.scoreCache.syncPayload(for: nil) == payload)
        cloud.scoreKeys.values = savedKeys
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue == nil)
        #expect(
            try sync.decodeScoreCloudEnvelope(
                ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
                from: encrypted
            ).payload == payload)
    }

    @Test(.timeLimit(.minutes(1))) func failedCloudSynchronizationRetainsChanges() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.appSettings])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        cloud.synchronizationSucceeds = false
        sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue?.contains("同步暂时失败") == true)
        #expect(sync.settings.galleryHiddenUserIDs == [42])
        #expect(cloud.data(forKey: key(.appSettings, account: account)) != nil)
        cloud.synchronizationSucceeds = true
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue == nil)
        #expect(sync.settings.galleryHiddenUserIDs == [42])
    }

    @Test("Independent domain timestamps choose the newest value")
    func reconciliationPolicy() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)

        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: nil, remoteUpdatedAt: nil)
                == .noChange)
        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: nil, remoteUpdatedAt: new)
                == .applyRemote)
        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: nil)
                == .uploadLocal)
        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: old, remoteUpdatedAt: new)
                == .applyRemote)
        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: old)
                == .uploadLocal)
        #expect(
            ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: new)
                == .noChange)
    }

    @Test("Score sync compresses payloads and reads existing JSON envelopes")
    func scorePayloadCodec() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<300).map { index in
            ScoreRow(
                index: index,
                headers: ["课程名称", "成绩", "课程性质"],
                values: ["数据结构与算法", "95", "必修"]
            )
        }
        let envelope = ExperimentalPreferenceSyncEnvelope(
            updatedAt: timestamp,
            payload: ScoreCacheSyncPayload(
                rows: rows,
                updatedAt: timestamp,
                detailedUpdatedAt: timestamp
            )
        )

        let legacyData = try JSONEncoder().encode(envelope)
        let compressedData = try ScoreCacheSyncPayloadCodec.encode(envelope)
        #expect(compressedData.count < legacyData.count)

        let compressed = try ScoreCacheSyncPayloadCodec.decode(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: compressedData
        )
        #expect(compressed.payload.rows.count == rows.count)
        #expect(compressed.payload.rows.first?.courseName == "数据结构与算法")

        let legacy = try ScoreCacheSyncPayloadCodec.decode(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: legacyData
        )
        #expect(legacy.payload.rows.count == rows.count)
        #expect(legacy.payload.updatedAt == timestamp)
    }

    @Test("KVS writes honor per-value, total-space, key-count and key-length quotas")
    func keyValueStoreQuotaPolicy() {
        let maximum = ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize

        #expect(
            ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: 64,
                existingValueBytes: maximum - 64,
                existingKeyCount: 1_023,
                replacingExistingKey: false,
                keyUTF16Count: 128
            ))
        #expect(
            !ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: maximum + 1,
                existingValueBytes: 0,
                existingKeyCount: 0,
                replacingExistingKey: false,
                keyUTF16Count: 1
            ))
        #expect(
            !ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: 2,
                existingValueBytes: maximum - 1,
                existingKeyCount: 0,
                replacingExistingKey: false,
                keyUTF16Count: 1
            ))
        #expect(
            !ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: 1,
                existingValueBytes: 0,
                existingKeyCount: 1_024,
                replacingExistingKey: false,
                keyUTF16Count: 1
            ))
        #expect(
            ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: 1,
                existingValueBytes: 0,
                existingKeyCount: 1_024,
                replacingExistingKey: true,
                keyUTF16Count: 1
            ))
        #expect(
            !ExperimentalPreferenceCloudQuotaPolicy.canStore(
                valueSize: 1,
                existingValueBytes: 0,
                existingKeyCount: 0,
                replacingExistingKey: false,
                keyUTF16Count: 129
            ))
    }
}
