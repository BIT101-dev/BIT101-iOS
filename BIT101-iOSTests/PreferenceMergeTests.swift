import Combine
import CommunityCore
import CommunityPersistence
import CommunityTransport
import Foundation
import ScheduleSync
import ScoreDomain
import ScoreInfrastructure
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
@Suite(.serialized)
struct PreferenceMergeTests {
    private final class Cloud: PreferenceCloudStoring {
        var dictionaryRepresentation: [String: Any] = [:]
        func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
        func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
        func synchronize() -> Bool { true }
    }

    private struct Device {
        let domain: String
        let defaults: UserDefaults
        let cloud: Cloud
        let sync: ExperimentalPreferenceCloudSync
        func record(_ domain: ExperimentalPreferenceSyncDomain) -> String {
            "preference-sync.v2.\(AppStorageSession(accountIdentifier: "merge-account").accountDirectoryName).\(domain.rawValue)"
        }
    }

    private func device(_ domain: String) throws -> Device {
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let session = AppStorageSession(accountIdentifier: "merge-account")
        let files = PreferenceMemoryFiles()
        let root = URL(fileURLWithPath: "/preference-merge")
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(defaults: defaults, session: { session }),
            composerDrafts: ComposerDraftStore(files: files, applicationSupport: root, session: { session }, prepareImageData: { $0 }),
            scoreCache: ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentSession: { session }, scoreSession: { session })
        defaults.set(true, forKey: "experimental.preference-cloud-sync.enabled.\(session.accountStorageIdentifier)")
        let cloud = Cloud()
        return Device(domain: domain, defaults: defaults, cloud: cloud,
            sync: ExperimentalPreferenceCloudSync(settings: settings, stores: stores, defaults: defaults,
                cloudStore: cloud, notificationCenter: NotificationCenter()))
    }

    @Test func twoOfflineDevicesKeepIndependentSettingsAndConvergeAfterReload() async throws {
        let first = try device("BIT101Tests.preference-merge.first")
        let second = try device("BIT101Tests.preference-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        second.sync.settings.updateGallerySettings(hideAnonymousContent: true)
        let firstValue = try #require(first.cloud.data(forKey: first.record(.appSettings)))
        let secondValue = try #require(second.cloud.data(forKey: second.record(.appSettings)))
        first.cloud.set(secondValue, forKey: first.record(.appSettings))
        second.cloud.set(firstValue, forKey: second.record(.appSettings))
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
        #expect(first.sync.settings.galleryHiddenUserIDs == [42])
        #expect(first.sync.settings.galleryHideAnonymousContent)
        #expect(AppSettingsSyncPayload(snapshot: second.sync.settings.snapshot) == AppSettingsSyncPayload(snapshot: first.sync.settings.snapshot))
        let firstEnvelope = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(first.cloud.data(forKey: first.record(.appSettings))))
        let secondEnvelope = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(second.cloud.data(forKey: second.record(.appSettings))))
        #expect(firstEnvelope.payload == secondEnvelope.payload)
        #expect(firstEnvelope.fieldUpdatedAt == secondEnvelope.fieldUpdatedAt)
        let reopened = ExperimentalPreferenceCloudSync(settings: first.sync.settings, stores: first.sync.stores,
            defaults: first.defaults, cloudStore: first.cloud, notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        #expect(reopened.settings.galleryHiddenUserIDs == [42])
        #expect(reopened.settings.galleryHideAnonymousContent)
    }

    @Test func offlineFilterChangesPreserveTermsAndSorting() async throws {
        let first = try device("BIT101Tests.filter-merge.first")
        let second = try device("BIT101Tests.filter-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.stores.scoreFilterPreferences.save(selectedTerms: ["term"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        second.sync.stores.scoreFilterPreferences.save(selectedTerms: [], selectedCourseTypes: ["必修"], sortIndex: .score, sortOrder: .descending)
        let firstValue = try #require(first.cloud.data(forKey: first.record(.scoreFilters)))
        let secondValue = try #require(second.cloud.data(forKey: second.record(.scoreFilters)))
        first.cloud.set(secondValue, forKey: first.record(.scoreFilters))
        second.cloud.set(firstValue, forKey: second.record(.scoreFilters))
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
        #expect(first.sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["term"])
        #expect(first.sync.stores.scoreFilterPreferences.load()?.selectedCourseTypes == ["必修"])
        #expect(first.sync.stores.scoreFilterPreferences.load() == second.sync.stores.scoreFilterPreferences.load())
    }

    @Test func offlineReadsMergeAcrossCategoriesAndKeepLocalCandidates() async throws {
        let first = try device("BIT101Tests.read-merge.first")
        let second = try device("BIT101Tests.read-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.stores.communityMessages.replaceLatestIDs([1, 2], unreadCount: 2, for: .comment)
        second.sync.stores.communityMessages.replaceLatestIDs([2, 3], unreadCount: 2, for: .comment)
        first.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
        second.sync.stores.communityMessages.markSeen(ids: [2], for: .comment)
        second.sync.stores.communityMessages.markSeen(ids: [8], for: .like)
        let firstValue = try #require(first.cloud.data(forKey: first.record(.galleryMessageRead)))
        let secondValue = try #require(second.cloud.data(forKey: second.record(.galleryMessageRead)))
        first.cloud.set(secondValue, forKey: first.record(.galleryMessageRead))
        second.cloud.set(firstValue, forKey: second.record(.galleryMessageRead))
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
        #expect(first.sync.stores.communityMessages.unreadCount(for: .comment) == 0)
        #expect(second.sync.stores.communityMessages.unreadCount(for: .comment) == 1)
        #expect(first.sync.stores.communityMessages.syncSnapshot().seenIDsByType == ["comment": [1, 2], "like": [8]])
        #expect(first.sync.stores.communityMessages.syncSnapshot() == second.sync.stores.communityMessages.syncSnapshot())
        first.sync.stores.communityMessages.replaceLatestIDs([3], unreadCount: 1, for: .comment)
        first.sync.stores.communityMessages.replaceLatestIDs([1, 3], unreadCount: 2, for: .comment)
        #expect(first.sync.stores.communityMessages.isUnread(id: 1, for: .comment) == false)
    }

    @Test func equalFieldVersionsAndOptionalRemovalConvergeInEitherOrder() throws {
        let time = Date(timeIntervalSince1970: 100)
        let old = ScoreFilterPreferenceSnapshot(selectedTerms: [], selectedCourseTypes: [], sortIndex: "score", sortOrder: "ascending")
        let local = ExperimentalPreferenceSyncEnvelope(updatedAt: time, payload: old, fieldUpdatedAt: ["sortOrder": time])
        var changed = old
        changed.sortOrder = nil
        let remote = try PreferenceFieldMerge.recording(changed, previous: local, at: time.addingTimeInterval(1))
        let forward = try PreferenceFieldMerge.merging(local, remote)
        let backward = try PreferenceFieldMerge.merging(remote, local)
        #expect(forward.payload.sortOrder == nil)
        #expect(forward.payload == backward.payload)
        #expect(forward.fieldUpdatedAt == backward.fieldUpdatedAt)
        var conflict = old
        conflict.sortOrder = "descending"
        let sameVersion = ExperimentalPreferenceSyncEnvelope(updatedAt: time, payload: conflict, fieldUpdatedAt: ["sortOrder": time])
        #expect(try PreferenceFieldMerge.merging(local, sameVersion).payload == PreferenceFieldMerge.merging(sameVersion, local).payload)
    }

    @Test func disabledEditsAndLegacyRemoteFieldsKeepTheirOwnership() async throws {
        let value = try device("BIT101Tests.preference-merge.disabled")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.setEnabled(false)
        value.sync.settings.updateGallerySettings(useWebView: true)
        #expect(value.cloud.dictionaryRepresentation.isEmpty)
        var remote = AppSettingsSnapshot()
        remote.galleryHiddenUserIDs = [99]
        value.cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: Date(timeIntervalSince1970: 100),
            payload: AppSettingsSyncPayload(snapshot: remote))), forKey: value.record(.appSettings))
        value.sync.setEnabled(true)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryUseWebView)
        #expect(value.sync.settings.galleryHiddenUserIDs == [99])
    }
    @Test func invalidAndFutureCloudRecordsKeepTheirBytesAcrossLocalEdits() async throws {
        let value = try device("BIT101Tests.preference-protection")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        for domain in ExperimentalPreferenceSyncDomain.allCases {
            let bytes = Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8)
            value.cloud.set(bytes, forKey: value.record(domain))
            if domain == .scoreCache { _ = await value.sync.stores.scoreCache.save(rows: []) }
            value.sync.localValueDidChange(in: domain)
            await value.sync.refreshFromCloudIfNeeded()?.value
            #expect(value.cloud.data(forKey: value.record(domain)) == bytes)
            #expect(value.sync.syncIssue != nil)
        }
        let key = value.record(.appSettings)
        for raw in [Data("broken".utf8), Data("{\"payload\":null}".utf8)] {
            value.cloud.set(raw, forKey: key)
            value.sync.settings.updateGallerySettings(useWebView: true)
            await value.sync.refreshFromCloudIfNeeded()?.value
            #expect(value.cloud.data(forKey: key) == raw)
        }
        value.cloud.set("invalid stored type", forKey: key)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.cloud.dictionaryRepresentation[key] as? String == "invalid stored type")
    }

    @Test func additiveFieldsAndTheirVersionsSurviveMergeAndReopen() async throws {
        let value = try device("BIT101Tests.preference-additive-fields")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let timestamp = Date(timeIntervalSince1970: 100)
        let extra: PreferenceJSONValue = .object(["ids": .array([.number(9_007_199_254_740_993)]), "enabled": .bool(true)])
        let remote = ExperimentalPreferenceSyncEnvelope(updatedAt: timestamp,
            payload: AppSettingsSyncPayload(snapshot: AppSettingsSnapshot()),
            fieldUpdatedAt: ["futureSetting": timestamp], additionalFields: ["futureSetting": extra])
        let key = value.record(.appSettings)
        value.cloud.set(try JSONEncoder().encode(remote), forKey: key)
        await value.sync.refreshFromCloudIfNeeded()?.value
        value.sync.settings.updateGallerySettings(useWebView: true)
        let reopened = ExperimentalPreferenceCloudSync(settings: value.sync.settings, stores: value.sync.stores,
            defaults: value.defaults, cloudStore: value.cloud, notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields["futureSetting"] == extra)
        #expect(restored.fieldUpdatedAt?["futureSetting"] == timestamp)
        #expect(restored.payload.galleryUseWebView)
    }

    @Test func legacyMigrationUsesTheVersionedRecordAndKeepsItsSource() async throws {
        let value = try device("BIT101Tests.preference-record-migration")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        let legacyKey = key.replacingOccurrences(of: "preference-sync.v2.", with: "preference-sync.v1.")
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [42]
        let envelope = ExperimentalPreferenceSyncEnvelope(updatedAt: Date(timeIntervalSince1970: 100),
            payload: AppSettingsSyncPayload(snapshot: snapshot))
        var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        raw.removeValue(forKey: "schemaVersion")
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        value.cloud.set(legacy, forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        value.sync.settings.updateGallerySettings(useWebView: true)
        #expect(value.cloud.data(forKey: legacyKey) == legacy)
        #expect(value.cloud.data(forKey: key) != nil)
        value.cloud.set(Data("older client rewrite".utf8), forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [42])
        #expect(value.sync.settings.galleryUseWebView)
    }

}
