import Combine
import CloudKit
import CommunityCore
import CommunityPersistence
import CommunityTransport
import Foundation
import ScheduleSync
import ScoreDomain
import ScorePorts
import ScoreInfrastructure
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
@Suite(.serialized)
struct PreferenceMergeTests {
    private final class Cloud: PreferenceCloudStoring {
        private var values: [String: Any] = [:]
        var onSnapshot: (([String: Any]) -> Void)?
        var dictionaryRepresentation: [String: Any] {
            get { let snapshot = values; onSnapshot?(snapshot); return snapshot }
            set { values = newValue }
        }
        let keys = PreferenceMemoryScoreKeys()
        var rejectedKey: String?
        var rejectedWrites = 0
        var synchronizes = true
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) {
            if let data = value as? Data {
                let bytes = values.reduce(0) { total, entry in
                    total + (entry.key == key ? 0 : (entry.value as? Data)?.count ?? 0)
                }
                guard rejectedKey != key, ExperimentalPreferenceCloudQuotaPolicy.canStore(valueSize: data.count,
                    existingValueBytes: bytes, existingKeyCount: values.count,
                    replacingExistingKey: values[key] != nil, keyUTF16Count: key.utf16.count) else {
                    rejectedWrites += 1
                    return
                }
            }
            values[key] = value
        }
        func synchronize() -> Bool { synchronizes }
    }

    private struct Device {
        let domain: String
        let defaults: UserDefaults
        let cloud: Cloud
        let notifications: NotificationCenter
        let sync: ExperimentalPreferenceCloudSync
        func record(_ domain: ExperimentalPreferenceSyncDomain) -> String {
            "preference-sync.v2.\(AppStorageSession(accountIdentifier: "merge-account").accountDirectoryName).\(domain.rawValue)"
        }
    }

    private func device(_ domain: String, localRecords: [ExperimentalPreferenceSyncDomain: Any] = [:], rawSnapshots: [String: Any] = [:]) throws -> Device {
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let session = AppStorageSession(accountIdentifier: "merge-account")
        for (prefix, value) in rawSnapshots { defaults.set(value, forKey: session.key(prefix)) }
        let files = PreferenceMemoryFiles()
        let root = URL(fileURLWithPath: "/preference-merge")
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(files: files, storageRoot: root, defaults: defaults, session: { session }),
            composerDrafts: ComposerDraftStore(files: files, applicationSupport: root, session: { session }, prepareImageData: { $0 }),
            scoreCache: ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: defaults, session: { session }),
            currentSession: { session }, scoreSession: { session })
        defaults.set(true, forKey: "experimental.preference-cloud-sync.enabled.\(session.accountStorageIdentifier)")
        for (domain, record) in localRecords {
            defaults.set(record, forKey: "experimental.preference-cloud-sync.local-envelope.\(session.accountStorageIdentifier).\(domain.rawValue)")
        }
        let cloud = Cloud(), notifications = NotificationCenter()
        return Device(domain: domain, defaults: defaults, cloud: cloud, notifications: notifications,
            sync: ExperimentalPreferenceCloudSync(settings: settings, stores: stores, defaults: defaults,
                cloudStore: cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: defaults, credentials: cloud.keys), notificationCenter: notifications))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["v1", "v2"])
    func externalNotificationsReconcileBothCloudRecordVersions(version: String) async throws {
        let value = try device("BIT101Tests.preference-merge.external-notification")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        await value.sync.refreshFromCloudIfNeeded()?.value
        var snapshot = AppSettingsSnapshot(); snapshot.galleryHiddenUserIDs = [185]
        let time = Date().addingTimeInterval(100)
        let key = value.record(.appSettings).replacingOccurrences(of: ".v2.", with: ".\(version).")
        value.cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: time,
            payload: AppSettingsSyncPayload(snapshot: snapshot))), forKey: key)
        value.notifications.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: value.cloud,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [key],
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange])
        try await waitForTestEvent { value.sync.settings.galleryHiddenUserIDs == [185] }
        #expect(value.cloud.data(forKey: value.record(.appSettings)) != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["kvs", "cloudKit"])
    func appleAccountChangesCancelThePreviousTaskAndReloadEveryDomain(notification: String) async throws {
        let value = try device("BIT101Tests.preference-merge.apple-account")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        var snapshot = AppSettingsSnapshot(); snapshot.galleryHiddenUserIDs = [207]
        let key = value.record(.appSettings)
        value.cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: Date().addingTimeInterval(100),
            payload: AppSettingsSyncPayload(snapshot: snapshot))), forKey: key)
        var delivered = false
        value.cloud.onSnapshot = { _ in
            guard !delivered else { return }
            delivered = true
            value.cloud.onSnapshot = nil
            if notification == "kvs" {
                value.notifications.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: value.cloud,
                    userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [String](),
                        NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreAccountChange])
            } else { value.notifications.post(name: .CKAccountChanged, object: nil) }
        }
        let previous = try #require(value.sync.refreshFromCloudIfNeeded())
        try await waitForTestEvent { delivered && previous.isCancelled && value.sync.settings.galleryHiddenUserIDs == [207] }
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.syncIssue == nil)
        #expect(value.cloud.data(forKey: value.record(.scoreFilters)) != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ExperimentalPreferenceCloudSync.RecordCleanupScope.currentAccount, .otherAccounts])
    func explicitCloudCleanupPausesWritesAndKeepsLocalAndUnselectedRecords(scope: ExperimentalPreferenceCloudSync.RecordCleanupScope) async throws {
        let value = try device("BIT101Tests.preference-cleanup")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        let snapshot = value.sync.settings.snapshot
        let current = value.record(.appSettings)
        let other = "preference-sync.v2.other-account.app-settings"
        let records = [current, current.replacingOccurrences(of: ".v2.", with: ".v1."),
            other, other.replacingOccurrences(of: ".v2.", with: ".v1."),
            "preference-sync.v3.other-account.app-settings", "preference-sync.v2.other-account.future-domain", "unrelated"]
        for key in records { value.cloud.set(Data(key.utf8), forKey: key) }
        let pending = value.sync.refreshFromCloudIfNeeded()
        #expect(value.sync.removeCloudRecords(in: scope))
        await pending?.value
        #expect(!value.sync.isEnabled)
        #expect(value.sync.settings.snapshot == snapshot)
        for key in records {
            let selected = scope == .currentAccount ? key == current || key == records[1] : key == other || key == records[3]
            #expect(value.cloud.data(forKey: key) == (selected ? nil : Data(key.utf8)))
        }
    }

    @Test func cloudCleanupReportsSynchronizationFailureAndSupportsRetry() throws {
        let value = try device("BIT101Tests.preference-cleanup")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.cloud.set(Data("record".utf8), forKey: value.record(.appSettings))
        value.cloud.synchronizes = false
        #expect(!value.sync.removeCloudRecords(in: .currentAccount))
        #expect(value.sync.syncIssue?.contains("清理暂时失败") == true)
        #expect(!value.sync.isEnabled)
        value.cloud.synchronizes = true
        #expect(value.sync.removeCloudRecords(in: .currentAccount))
        #expect(value.sync.syncIssue == nil)
    }

    @Test(.timeLimit(.minutes(1))) func removingOtherAccountRecordsRestoresCapacityForLocalPreferences() async throws {
        let value = try device("BIT101Tests.preference-cleanup")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.cloud.set(Data(count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize),
            forKey: "preference-sync.v2.other-account.score-cache")
        value.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.cloud.data(forKey: value.record(.appSettings)) == nil)
        #expect(value.sync.syncIssue?.contains("容量上限") == true)
        #expect(value.sync.removeCloudRecords(in: .otherAccounts))
        value.sync.setEnabled(true)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: value.record(.appSettings))))
        #expect(restored.payload.galleryHiddenUserIDs == [42])
        #expect(value.sync.syncIssue == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters, .galleryMessageRead])
    func damagedLocalSnapshotsPreserveBytesAndPauseTheirCloudDomain(_ domain: ExperimentalPreferenceSyncDomain) async throws {
        let prefix: String
        switch domain {
        case .appSettings: prefix = AppSettingsStore.storageKeyPrefix
        case .scoreFilters: prefix = "score.filter.preferences"
        case .galleryMessageRead: prefix = "gallery.message.read.snapshot"
        case .scoreCache: return
        }
        let damaged = Data("damaged-local-snapshot".utf8)
        let value = try device("BIT101Tests.preference-merge.corruption", rawSnapshots: [prefix: damaged])
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(hideAnonymousContent: true)
        value.sync.stores.scoreFilterPreferences.save(selectedTerms: ["test"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        await value.sync.stores.communityMessages.markSeen(ids: [100], for: .comment)
        value.sync.localValueDidChange(in: domain)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let session = AppStorageSession(accountIdentifier: "merge-account")
        #expect(value.defaults.data(forKey: session.key(prefix)) == damaged)
        #expect(value.cloud.data(forKey: value.record(domain)) == nil)
        #expect(value.defaults.data(forKey: "experimental.preference-cloud-sync.local-envelope.\(session.accountStorageIdentifier).\(domain.rawValue)") == nil)
        #expect(value.sync.syncIssue != nil)
    }

    @Test(.timeLimit(.minutes(1))) func twoOfflineDevicesKeepIndependentSettingsAndConvergeAfterReload() async throws {
        let first = try device("BIT101Tests.preference-merge.first")
        let second = try device("BIT101Tests.preference-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        second.sync.settings.updateGallerySettings(hideAnonymousContent: true)
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
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
            defaults: first.defaults, cloudStore: first.cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: first.defaults, credentials: first.cloud.keys), notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        #expect(reopened.settings.galleryHiddenUserIDs == [42])
        #expect(reopened.settings.galleryHideAnonymousContent)
    }

    @Test(.timeLimit(.minutes(1))) func offlineFilterChangesPreserveTermsAndSorting() async throws {
        let first = try device("BIT101Tests.filter-merge.first")
        let second = try device("BIT101Tests.filter-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.stores.scoreFilterPreferences.save(selectedTerms: ["term"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        second.sync.stores.scoreFilterPreferences.save(selectedTerms: [], selectedCourseTypes: ["必修"], sortIndex: .score, sortOrder: .descending)
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
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

    @Test(.timeLimit(.minutes(1))) func offlineReadsMergeAcrossCategoriesAndKeepLocalCandidates() async throws {
        let first = try device("BIT101Tests.read-merge.first")
        let second = try device("BIT101Tests.read-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        await first.sync.stores.communityMessages.replaceLatestIDs([1, 2], unreadCount: 2, for: .comment)
        await second.sync.stores.communityMessages.replaceLatestIDs([2, 3], unreadCount: 2, for: .comment)
        await first.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
        await second.sync.stores.communityMessages.markSeen(ids: [2], for: .comment)
        await second.sync.stores.communityMessages.markSeen(ids: [8], for: .like)
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
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
        await first.sync.stores.communityMessages.replaceLatestIDs([3], unreadCount: 1, for: .comment)
        await first.sync.stores.communityMessages.replaceLatestIDs([1, 3], unreadCount: 2, for: .comment)
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

    @Test(.timeLimit(.minutes(1))) func disabledEditsAndLegacyRemoteFieldsKeepTheirOwnership() async throws {
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
    @Test(.timeLimit(.minutes(1))) func invalidAndFutureCloudRecordsKeepTheirBytesAcrossLocalEdits() async throws {
        let value = try device("BIT101Tests.preference-protection")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        for domain in ExperimentalPreferenceSyncDomain.allCases {
            let bytes = Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8)
            value.cloud.set(bytes, forKey: value.record(domain))
            if domain == .scoreCache { _ = await value.sync.stores.scoreCache.save(rows: [], for: nil) }
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

    @Test(.timeLimit(.minutes(1))) func invalidAndFutureLocalRecordsKeepTheirBytesAcrossLaunchEditsAndReload() async throws {
        let invalidRecords: [Any] = [Data("broken".utf8),
            Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8), "invalid stored type"]
        for record in invalidRecords {
            let value = try device("BIT101Tests.local-preference-protection",
                localRecords: [.appSettings: record, .scoreFilters: record])
            defer { value.defaults.removePersistentDomain(forName: value.domain) }
            #expect(value.sync.syncIssue != nil)
            value.sync.setEnabled(false)
            value.sync.settings.updateGallerySettings(useWebView: true)
            value.sync.stores.scoreFilterPreferences.save(selectedTerms: ["term"], selectedCourseTypes: [],
                sortIndex: .score, sortOrder: .descending)
            value.sync.setEnabled(true)
            await value.sync.refreshFromCloudIfNeeded()?.value
            let reopened = ExperimentalPreferenceCloudSync(settings: value.sync.settings, stores: value.sync.stores,
                defaults: value.defaults, cloudStore: value.cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: value.defaults, credentials: value.cloud.keys), notificationCenter: NotificationCenter())
            reopened.reloadForCurrentAccount()
            await reopened.refreshFromCloudIfNeeded()?.value
            #expect(reopened.syncIssue != nil)
            #expect(value.cloud.data(forKey: value.record(.appSettings)) == nil)
            #expect(value.cloud.data(forKey: value.record(.scoreFilters)) == nil)
            for domain in [ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters] {
                let key = "experimental.preference-cloud-sync.local-envelope.\(AppStorageSession(accountIdentifier: "merge-account").accountStorageIdentifier).\(domain.rawValue)"
                if let bytes = record as? Data { #expect(value.defaults.data(forKey: key) == bytes) }
                else { #expect(value.defaults.string(forKey: key) == record as? String) }
            }
            #expect(value.sync.settings.galleryUseWebView)
            #expect(value.sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["term"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func additiveFieldsAndTheirVersionsSurviveMergeAndReopen() async throws {
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
            defaults: value.defaults, cloudStore: value.cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: value.defaults, credentials: value.cloud.keys), notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields["futureSetting"] == extra)
        #expect(restored.fieldUpdatedAt?["futureSetting"] == timestamp)
        #expect(restored.payload.galleryUseWebView)
    }

    @Test(.timeLimit(.minutes(1))) func equalVersionAdditionalFieldConflictsConvergeInCloudAndAfterReopen() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let payload = AppSettingsSyncPayload(snapshot: AppSettingsSnapshot())
        var versions = try PreferenceFieldMerge.recording(payload,
            previous: Optional<ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>>.none,
            at: timestamp).fieldUpdatedAt ?? [:]
        versions["futureSetting"] = timestamp
        let local = ExperimentalPreferenceSyncEnvelope(updatedAt: timestamp, payload: payload,
            fieldUpdatedAt: versions, additionalFields: ["futureSetting": .string("z")])
        let remote = ExperimentalPreferenceSyncEnvelope(updatedAt: timestamp, payload: payload,
            fieldUpdatedAt: local.fieldUpdatedAt, additionalFields: ["futureSetting": .string("a")])
        let value = try device("BIT101Tests.preference-additional-field-conflict",
            localRecords: [.appSettings: JSONEncoder().encode(local)])
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        value.cloud.set(try JSONEncoder().encode(remote), forKey: key)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let cloud = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(cloud.additionalFields == local.additionalFields)
        #expect(cloud.fieldUpdatedAt == local.fieldUpdatedAt)
        let reopened = ExperimentalPreferenceCloudSync(settings: value.sync.settings, stores: value.sync.stores,
            defaults: value.defaults, cloudStore: value.cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: value.defaults, credentials: value.cloud.keys), notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields == local.additionalFields)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func legacyMigrationRetainsItsSourceUntilTheReplacementFitsAndIsStored(rejectWrite: Bool) async throws {
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
        let availableBytes = try JSONEncoder().encode(envelope).count - 1
        value.cloud.set(legacy, forKey: legacyKey)
        if rejectWrite { value.cloud.rejectedKey = key }
        else { value.cloud.set(Data(count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize - legacy.count - availableBytes), forKey: "other-account") }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let retained = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: legacyKey)))
        #expect(retained.payload.galleryHiddenUserIDs == [42])
        #expect(value.cloud.data(forKey: key) == nil)
        #expect(value.sync.settings.galleryHiddenUserIDs == [42])
        #expect(rejectWrite ? value.cloud.rejectedWrites > 0 : value.cloud.rejectedWrites == 0)
        value.cloud.rejectedKey = nil
        value.cloud.set(nil, forKey: "other-account")
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.cloud.data(forKey: legacyKey) == nil)
        value.sync.settings.updateGallerySettings(useWebView: true)
        #expect(value.cloud.data(forKey: legacyKey) == nil)
        #expect(value.cloud.data(forKey: key) != nil)
        value.cloud.set(Data("older client rewrite".utf8), forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [42])
        #expect(value.sync.settings.galleryUseWebView)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func coexistingLegacySettingsMergeFieldVersionsBeforeCleanup(rejectWrite: Bool) async throws {
        let value = try device("BIT101Tests.preference-merge.coexisting-settings")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings), legacyKey = key.replacingOccurrences(of: ".v2.", with: ".v1.")
        let currentTime = Date(timeIntervalSince1970: 300), legacyTime = Date(timeIntervalSince1970: 200)
        var current = AppSettingsSnapshot(); current.galleryHiddenUserIDs = [42]; current.galleryUseWebView = true
        var legacy = AppSettingsSnapshot(); legacy.galleryHiddenUserIDs = [99]; legacy.galleryHideAnonymousContent = true
        let currentData = try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: currentTime,
            payload: AppSettingsSyncPayload(snapshot: current), fieldUpdatedAt: ["galleryHiddenUserIDs": currentTime,
                "galleryUseWebView": currentTime, "galleryStrictUserFilter": Date(timeIntervalSince1970: 100)]))
        func legacyData(at time: Date) throws -> Data {
            let encoded = try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: time,
                payload: AppSettingsSyncPayload(snapshot: legacy)))
            var raw = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            raw.removeValue(forKey: "schemaVersion")
            return try JSONSerialization.data(withJSONObject: raw)
        }
        value.cloud.set(currentData, forKey: key)
        value.cloud.set(try legacyData(at: legacyTime), forKey: legacyKey)
        if rejectWrite { value.cloud.rejectedKey = key }
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [42])
        #expect(value.sync.settings.galleryUseWebView && value.sync.settings.galleryHideAnonymousContent)
        if rejectWrite {
            #expect(value.cloud.data(forKey: legacyKey) != nil && value.cloud.data(forKey: key) == currentData)
            value.cloud.rejectedKey = nil
            await value.sync.refreshFromCloudIfNeeded()?.value
        }
        let merged = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(merged.payload.galleryHiddenUserIDs == [42] && merged.payload.galleryUseWebView && merged.payload.galleryHideAnonymousContent)
        #expect(value.cloud.data(forKey: legacyKey) == nil)
        value.cloud.set(try legacyData(at: currentTime.addingTimeInterval(100)), forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [99])
        #expect(!value.sync.settings.galleryUseWebView && value.sync.settings.galleryHideAnonymousContent)
        #expect(value.cloud.data(forKey: legacyKey) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func coexistingLegacyRecordsPreserveFiltersReadIDsAndNewerScores() async throws {
        let value = try device("BIT101Tests.preference-merge.coexisting-domains")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let currentTime = Date(timeIntervalSince1970: 300), legacyTime = Date(timeIntervalSince1970: 200)
        func store<Payload: Codable>(_ current: ExperimentalPreferenceSyncEnvelope<Payload>,
                                    _ legacy: ExperimentalPreferenceSyncEnvelope<Payload>, domain: ExperimentalPreferenceSyncDomain) throws {
            let key = value.record(domain)
            value.cloud.set(try JSONEncoder().encode(current), forKey: key)
            var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            raw.removeValue(forKey: "schemaVersion")
            value.cloud.set(try JSONSerialization.data(withJSONObject: raw), forKey: key.replacingOccurrences(of: ".v2.", with: ".v1."))
        }
        try store(ExperimentalPreferenceSyncEnvelope(updatedAt: currentTime,
            payload: ScoreFilterPreferenceSnapshot(selectedTerms: ["current"], selectedCourseTypes: [], sortIndex: nil, sortOrder: nil),
            fieldUpdatedAt: ["selectedTerms": currentTime, "selectedCourseTypes": Date(timeIntervalSince1970: 100)]),
            ExperimentalPreferenceSyncEnvelope(updatedAt: legacyTime,
                payload: ScoreFilterPreferenceSnapshot(selectedTerms: ["legacy"], selectedCourseTypes: ["required"], sortIndex: nil, sortOrder: nil)), domain: .scoreFilters)
        var currentReads = GalleryMessageReadSnapshot(); currentReads.seenIDsByType = ["comment": [1]]
        var legacyReads = GalleryMessageReadSnapshot(); legacyReads.seenIDsByType = ["comment": [2]]
        try store(ExperimentalPreferenceSyncEnvelope(updatedAt: currentTime, payload: currentReads),
            ExperimentalPreferenceSyncEnvelope(updatedAt: legacyTime, payload: legacyReads), domain: .galleryMessageRead)
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        try store(ExperimentalPreferenceSyncEnvelope(updatedAt: legacyTime,
            payload: ScoreCacheSyncPayload(rows: [], updatedAt: legacyTime, detailedUpdatedAt: nil)),
            ExperimentalPreferenceSyncEnvelope(updatedAt: currentTime,
                payload: ScoreCacheSyncPayload(rows: rows, updatedAt: currentTime, detailedUpdatedAt: nil)), domain: .scoreCache)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["current"])
        #expect(value.sync.stores.scoreFilterPreferences.load()?.selectedCourseTypes == ["required"])
        #expect(value.sync.stores.communityMessages.syncSnapshot().seenIDsByType["comment"] == [1, 2])
        #expect(try await value.sync.stores.scoreCache.syncPayload(for: AppStorageSession(accountIdentifier: "merge-account"))?.rows == rows)
        let scoreData = try #require(value.cloud.data(forKey: value.record(.scoreCache)))
        #expect(ScoreCacheSyncEncryption.isEncrypted(scoreData))
        #expect(try value.sync.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: scoreData).payload.rows == rows)
        for domain in [ExperimentalPreferenceSyncDomain.scoreFilters, .galleryMessageRead, .scoreCache] {
            #expect(value.cloud.data(forKey: value.record(domain).replacingOccurrences(of: ".v2.", with: ".v1.")) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func settingsReconcileAgainWhenTheCloudChangesAfterTheFirstMerge() async throws {
        let value = try device("BIT101Tests.preference-merge.settings-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(useWebView: true)
        let time = Date().addingTimeInterval(100)
        func record(_ ids: [Int], at version: Date) throws -> Data {
            var snapshot = AppSettingsSnapshot(); snapshot.galleryHiddenUserIDs = ids
            return try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: version,
                payload: AppSettingsSyncPayload(snapshot: snapshot), fieldUpdatedAt: ["galleryHiddenUserIDs": version]))
        }
        let key = value.record(.appSettings), first = try record([1], at: time), second = try record([2], at: time.addingTimeInterval(100))
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first, value.sync.settings.galleryHiddenUserIDs == [1] else { return }
            changed = true; value.cloud.onSnapshot = nil; value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && value.sync.settings.galleryUseWebView)
        #expect(value.sync.settings.galleryHiddenUserIDs == [2])
        #expect(uploaded.payload.galleryHiddenUserIDs == [2] && uploaded.payload.galleryUseWebView)
    }

    @Test(.timeLimit(.minutes(1))) func filtersReconcileAgainWhenTheCloudChangesAfterTheFirstMerge() async throws {
        let value = try device("BIT101Tests.preference-merge.filters-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.stores.scoreFilterPreferences.save(selectedTerms: ["local"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .ascending)
        let time = Date().addingTimeInterval(100)
        func record(_ type: String, at version: Date) throws -> Data {
            let payload = ScoreFilterPreferenceSnapshot(selectedTerms: [], selectedCourseTypes: [type], sortIndex: nil, sortOrder: nil)
            return try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: version, payload: payload,
                fieldUpdatedAt: ["selectedCourseTypes": version]))
        }
        let key = value.record(.scoreFilters), first = try record("first", at: time), second = try record("second", at: time.addingTimeInterval(100))
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                  value.sync.stores.scoreFilterPreferences.load()?.selectedCourseTypes == ["first"] else { return }
            changed = true; value.cloud.onSnapshot = nil; value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.selectedTerms == ["local"])
        #expect(uploaded.payload.selectedCourseTypes == ["second"])
        #expect(value.sync.stores.scoreFilterPreferences.load() == uploaded.payload)
    }

    @Test(.timeLimit(.minutes(1))) func messageReadsIncludeTheRecordThatArrivesDuringUpload() async throws {
        let value = try device("BIT101Tests.preference-merge.messages-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        await value.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
        func record(_ id: Int) throws -> Data {
            var snapshot = GalleryMessageReadSnapshot(); snapshot.seenIDsByType = ["comment": [id]]
            return try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: Date(), payload: snapshot))
        }
        let key = value.record(.galleryMessageRead), first = try record(2), second = try record(3)
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                  value.sync.stores.communityMessages.syncSnapshot().seenIDsByType["comment"] == [1, 2] else { return }
            changed = true; value.cloud.onSnapshot = nil; value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<GalleryMessageReadSnapshot>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.seenIDsByType["comment"] == [1, 2, 3])
        #expect(value.sync.stores.communityMessages.syncSnapshot() == uploaded.payload)
    }

    @Test(.timeLimit(.minutes(1))) func scoreUploadReevaluatesTheNewerCloudVersion() async throws {
        let value = try device("BIT101Tests.preference-merge.score-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let session = AppStorageSession(accountIdentifier: "merge-account")
        let seal = try ScoreCacheSyncEncryption(defaults: value.defaults, credentials: value.cloud.keys).prepareSeal(account: session.accountDirectoryName)
        let time = Date().addingTimeInterval(100)
        let remoteRows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["remote", "95"])]
        let first = try await PreferenceCloudPayloadCodec.encode(ExperimentalPreferenceSyncEnvelope(updatedAt: time,
            payload: ScoreCacheSyncPayload(rows: [], updatedAt: time, detailedUpdatedAt: nil)), seal: seal)
        let second = try await PreferenceCloudPayloadCodec.encode(ExperimentalPreferenceSyncEnvelope(updatedAt: time.addingTimeInterval(100),
            payload: ScoreCacheSyncPayload(rows: remoteRows, updatedAt: time, detailedUpdatedAt: nil)), seal: seal)
        let key = value.record(.scoreCache)
        value.cloud.set(first, forKey: key)
        let versionKey = "experimental.preference-cloud-sync.local-updated.\(session.accountStorageIdentifier).score-cache"
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                  (value.defaults.object(forKey: versionKey) as? Date ?? .distantPast) > time else { return }
            changed = true; value.cloud.onSnapshot = nil; value.cloud.set(second, forKey: key)
        }
        _ = await value.sync.stores.scoreCache.save(rows: [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["local", "80"])], for: nil)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try value.sync.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.rows == remoteRows)
        #expect(try await value.sync.stores.scoreCache.syncPayload(for: session)?.rows == remoteRows)
    }

    @Test(.timeLimit(.minutes(1))) func oneLargeLegacyRecordKeepsSyncingWithinTheExistingQuota() async throws {
        let value = try device("BIT101Tests.preference-merge.large-legacy")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings), legacy = key.replacingOccurrences(of: "preference-sync.v2.", with: "preference-sync.v1.")
        let extra = PreferenceJSONValue.string(String(repeating: "x", count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize * 3 / 4))
        value.cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(updatedAt: Date(timeIntervalSince1970: 100),
            payload: AppSettingsSyncPayload(snapshot: AppSettingsSnapshot()), additionalFields: ["futureSetting": extra])), forKey: legacy)
        #expect(value.cloud.dictionaryRepresentation.count == 1)
        for enabled in [true, false] {
            value.sync.settings.updateGallerySettings(useWebView: enabled)
            await value.sync.refreshFromCloudIfNeeded()?.value
            let data = try #require(value.cloud.data(forKey: legacy))
            let uploaded = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self, from: data)
            #expect(uploaded.payload.galleryUseWebView == enabled && uploaded.additionalFields["futureSetting"] == extra)
            #expect(value.cloud.data(forKey: key) == nil)
            let totalBytes = value.cloud.dictionaryRepresentation.values.compactMap { $0 as? Data }.reduce(0) { $0 + $1.count }
            #expect(totalBytes <= ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize)
            #expect(data.count <= ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize && value.sync.syncIssue == nil)
        }
    }
}
