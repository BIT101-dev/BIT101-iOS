import CloudKit
import CommunityCore
import CommunityPersistence
import CommunityTransport
import Foundation
import ScheduleSync
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import StorageCore
import Testing

@testable import BIT101_iOS

@MainActor
@Suite(.serialized)
struct PreferenceMergeTests {
    final class Cloud: PreferenceCloudStoring {
        var values: [String: Any] = [:]
        var onSnapshot: (([String: Any]) -> Void)?
        var dictionaryRepresentation: [String: Any] {
            get {
                let snapshot = values
                onSnapshot?(snapshot)
                return snapshot
            }
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
                guard rejectedKey != key,
                    ExperimentalPreferenceCloudQuotaPolicy.canStore(
                        valueSize: data.count,
                        existingValueBytes: bytes, existingKeyCount: values.count,
                        replacingExistingKey: values[key] != nil, keyUTF16Count: key.utf16.count)
                else {
                    rejectedWrites += 1
                    return
                }
            }
            values[key] = value
        }
        func synchronize() -> Bool { synchronizes }
    }

    struct Device {
        let domain: String
        let defaults: UserDefaults
        let cloud: Cloud
        let notifications: NotificationCenter
        let sync: ExperimentalPreferenceCloudSync
        func record(_ domain: ExperimentalPreferenceSyncDomain) -> String {
            """
            preference-sync.v2.\
            \(AppStorageSession(accountIdentifier: "merge-account").accountDirectoryName).\
            \(domain.rawValue)
            """
        }
    }

    func device(
        _ domain: String, localRecords: [ExperimentalPreferenceSyncDomain: Any] = [:],
        rawSnapshots: [String: Any] = [:]
    ) throws -> Device {
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let session = AppStorageSession(accountIdentifier: "merge-account")
        for (prefix, value) in rawSnapshots { defaults.set(value, forKey: session.key(prefix)) }
        let files = PreferenceMemoryFiles()
        let root = URL(fileURLWithPath: "/preference-merge")
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(
                files: files, storageRoot: root, defaults: defaults, session: { session }),
            composerDrafts: ComposerDraftStore(
                files: files, applicationSupport: root, session: { session },
                prepareImageData: { $0 }),
            scoreCache: ScoreCacheStore(
                files: files, storageRoot: root, defaults: defaults, session: { session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(
                defaults: defaults, session: { session }),
            currentSession: { session }, scoreSession: { session })
        defaults.set(
            true,
            forKey: "experimental.preference-cloud-sync.enabled.\(session.accountStorageIdentifier)"
        )
        for (domain, record) in localRecords {
            defaults.set(
                record,
                forKey:
                    """
                    experimental.preference-cloud-sync.local-envelope.\
                    \(session.accountStorageIdentifier).\(domain.rawValue)
                    """
            )
        }
        let cloud = Cloud()
        let notifications = NotificationCenter()
        return Device(
            domain: domain, defaults: defaults, cloud: cloud, notifications: notifications,
            sync: ExperimentalPreferenceCloudSync(
                settings: settings, stores: stores, defaults: defaults,
                cloudStore: cloud,
                scoreEncryption: ScoreCacheSyncEncryption(
                    defaults: defaults, credentials: cloud.keys), notificationCenter: notifications)
        )
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["v1", "v2"])
    func externalNoticesReconcileVersions(version: String) async throws {
        let value = try device("BIT101Tests.preference-merge.external-notification")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        await value.sync.refreshFromCloudIfNeeded()?.value
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [185]
        let time = Date().addingTimeInterval(100)
        let key = value.record(.appSettings).replacingOccurrences(of: ".v2.", with: ".\(version).")
        value.cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: time,
                    payload: AppSettingsSyncPayload(snapshot: snapshot))), forKey: key)
        value.notifications.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: value.cloud,
            userInfo: [
                NSUbiquitousKeyValueStoreChangedKeysKey: [key],
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
            ])
        try await waitForTestEvent { value.sync.settings.galleryHiddenUserIDs == [185] }
        #expect(value.cloud.data(forKey: value.record(.appSettings)) != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["kvs", "cloudKit"])
    func appleAccountChangesCancelPreviousTask(notification: String) async throws {
        let value = try device("BIT101Tests.preference-merge.apple-account")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [207]
        let key = value.record(.appSettings)
        value.cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: Date().addingTimeInterval(100),
                    payload: AppSettingsSyncPayload(snapshot: snapshot))), forKey: key)
        var delivered = false
        value.cloud.onSnapshot = { _ in
            guard !delivered else { return }
            delivered = true
            value.cloud.onSnapshot = nil
            if notification == "kvs" {
                value.notifications.post(
                    name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: value.cloud,
                    userInfo: [
                        NSUbiquitousKeyValueStoreChangedKeysKey: [String](),
                        NSUbiquitousKeyValueStoreChangeReasonKey:
                            NSUbiquitousKeyValueStoreAccountChange,
                    ])
            } else {
                value.notifications.post(name: .CKAccountChanged, object: nil)
            }
        }
        let previous = try #require(value.sync.refreshFromCloudIfNeeded())
        try await waitForTestEvent {
            delivered && previous.isCancelled && value.sync.settings.galleryHiddenUserIDs == [207]
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.syncIssue == nil)
        #expect(value.cloud.data(forKey: value.record(.scoreFilters)) != nil)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            ExperimentalPreferenceCloudSync.RecordCleanupScope.currentAccount, .otherAccounts,
        ])
    func explicitCloudCleanupPausesWrites(scope: ExperimentalPreferenceCloudSync.RecordCleanupScope)
        async throws
    {
        let value = try device("BIT101Tests.preference-cleanup")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        let snapshot = value.sync.settings.snapshot
        let current = value.record(.appSettings)
        let other = "preference-sync.v2.other-account.app-settings"
        let records = [
            current, current.replacingOccurrences(of: ".v2.", with: ".v1."),
            other, other.replacingOccurrences(of: ".v2.", with: ".v1."),
            "preference-sync.v3.other-account.app-settings",
            "preference-sync.v2.other-account.future-domain", "unrelated",
        ]
        for key in records { value.cloud.set(Data(key.utf8), forKey: key) }
        let pending = value.sync.refreshFromCloudIfNeeded()
        #expect(value.sync.removeCloudRecords(in: scope))
        await pending?.value
        #expect(!value.sync.isEnabled)
        #expect(value.sync.settings.snapshot == snapshot)
        for key in records {
            let selected =
                scope == .currentAccount
                ? key == current || key == records[1] : key == other || key == records[3]
            #expect(value.cloud.data(forKey: key) == (selected ? nil : Data(key.utf8)))
        }
    }

    @Test func cloudCleanupReportsSynchronizationFailure() throws {
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

    @Test(.timeLimit(.minutes(1))) func removingAccountRecordsRestoresPrefs() async throws {
        let value = try device("BIT101Tests.preference-cleanup")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.cloud.set(
            Data(count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize),
            forKey: "preference-sync.v2.other-account.score-cache")
        value.sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.cloud.data(forKey: value.record(.appSettings)) == nil)
        #expect(value.sync.syncIssue?.contains("容量上限") == true)
        #expect(value.sync.removeCloudRecords(in: .otherAccounts))
        value.sync.setEnabled(true)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: value.record(.appSettings))))
        #expect(restored.payload.galleryHiddenUserIDs == [42])
        #expect(value.sync.syncIssue == nil)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters, .galleryMessageRead,
        ])
    func damagedLocalSnapshotsPreserveBytes(_ domain: ExperimentalPreferenceSyncDomain) async throws
    {
        let prefix: String
        switch domain {
        case .appSettings: prefix = AppSettingsStore.storageKeyPrefix
        case .scoreFilters: prefix = "score.filter.preferences"
        case .galleryMessageRead: prefix = "gallery.message.read.snapshot"
        case .scoreCache: return
        }
        let damaged = Data("damaged-local-snapshot".utf8)
        let value = try device(
            "BIT101Tests.preference-merge.corruption", rawSnapshots: [prefix: damaged])
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(hideAnonymousContent: true)
        value.sync.stores.scoreFilterPreferences.save(
            selectedTerms: ["test"], selectedCourseTypes: [], sortIndex: .score,
            sortOrder: .descending)
        await value.sync.stores.communityMessages.markSeen(ids: [100], for: .comment)
        value.sync.localValueDidChange(in: domain)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let session = AppStorageSession(accountIdentifier: "merge-account")
        #expect(value.defaults.data(forKey: session.key(prefix)) == damaged)
        #expect(value.cloud.data(forKey: value.record(domain)) == nil)
        #expect(
            value.defaults.data(
                forKey:
                    """
                    experimental.preference-cloud-sync.local-envelope.\
                    \(session.accountStorageIdentifier).\(domain.rawValue)
                    """
            ) == nil)
        #expect(value.sync.syncIssue != nil)
    }

    @Test(.timeLimit(.minutes(1))) func twoOfflineDevicesKeepIndependentSettings() async throws {
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
        #expect(
            AppSettingsSyncPayload(snapshot: second.sync.settings.snapshot)
                == AppSettingsSyncPayload(snapshot: first.sync.settings.snapshot))
        let firstEnvelope = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(first.cloud.data(forKey: first.record(.appSettings))))
        let secondEnvelope = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(second.cloud.data(forKey: second.record(.appSettings))))
        #expect(firstEnvelope.payload == secondEnvelope.payload)
        #expect(firstEnvelope.fieldUpdatedAt == secondEnvelope.fieldUpdatedAt)
        let reopened = ExperimentalPreferenceCloudSync(
            settings: first.sync.settings, stores: first.sync.stores,
            defaults: first.defaults, cloudStore: first.cloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: first.defaults, credentials: first.cloud.keys),
            notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        #expect(reopened.settings.galleryHiddenUserIDs == [42])
        #expect(reopened.settings.galleryHideAnonymousContent)
    }

    @Test(.timeLimit(.minutes(1))) func offlineFilterChangesPreserveTerms() async throws {
        let first = try device("BIT101Tests.filter-merge.first")
        let second = try device("BIT101Tests.filter-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        first.sync.stores.scoreFilterPreferences.save(
            selectedTerms: ["term"], selectedCourseTypes: [], sortIndex: .score,
            sortOrder: .descending)
        second.sync.stores.scoreFilterPreferences.save(
            selectedTerms: [], selectedCourseTypes: ["必修"], sortIndex: .score,
            sortOrder: .descending)
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
        #expect(
            first.sync.stores.scoreFilterPreferences.load()
                == second.sync.stores.scoreFilterPreferences.load())
    }

    @Test(.timeLimit(.minutes(1))) func offlineReadsMergeAcrossCategories() async throws {
        let first = try device("BIT101Tests.read-merge.first")
        let second = try device("BIT101Tests.read-merge.second")
        defer {
            first.defaults.removePersistentDomain(forName: first.domain)
            second.defaults.removePersistentDomain(forName: second.domain)
        }
        await first.sync.stores.communityMessages.replaceLatestIDs(
            [1, 2], unreadCount: 2, for: .comment)
        await second.sync.stores.communityMessages.replaceLatestIDs(
            [2, 3], unreadCount: 2, for: .comment)
        await first.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
        await second.sync.stores.communityMessages.markSeen(ids: [2], for: .comment)
        await second.sync.stores.communityMessages.markSeen(ids: [8], for: .like)
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
        let firstValue = try #require(first.cloud.data(forKey: first.record(.galleryMessageRead)))
        let secondValue = try #require(
            second.cloud.data(forKey: second.record(.galleryMessageRead)))
        first.cloud.set(secondValue, forKey: first.record(.galleryMessageRead))
        second.cloud.set(firstValue, forKey: second.record(.galleryMessageRead))
        await first.sync.refreshFromCloudIfNeeded()?.value
        await second.sync.refreshFromCloudIfNeeded()?.value
        #expect(first.sync.stores.communityMessages.unreadCount(for: .comment) == 0)
        #expect(second.sync.stores.communityMessages.unreadCount(for: .comment) == 1)
        #expect(
            first.sync.stores.communityMessages.syncSnapshot().seenIDsByType == [
                "comment": [1, 2], "like": [8],
            ])
        #expect(
            first.sync.stores.communityMessages.syncSnapshot()
                == second.sync.stores.communityMessages.syncSnapshot())
        await first.sync.stores.communityMessages.replaceLatestIDs(
            [3], unreadCount: 1, for: .comment)
        await first.sync.stores.communityMessages.replaceLatestIDs(
            [1, 3], unreadCount: 2, for: .comment)
        #expect(first.sync.stores.communityMessages.isUnread(id: 1, for: .comment) == false)
    }

    @Test func equalFieldVersions() throws {
        let time = Date(timeIntervalSince1970: 100)
        let old = ScoreFilterPreferenceSnapshot(
            selectedTerms: [], selectedCourseTypes: [], sortIndex: "score", sortOrder: "ascending")
        let local = ExperimentalPreferenceSyncEnvelope(
            updatedAt: time, payload: old, fieldUpdatedAt: ["sortOrder": time])
        var changed = old
        changed.sortOrder = nil
        let remote = try PreferenceFieldMerge.recording(
            changed, previous: local, at: time.addingTimeInterval(1))
        let forward = try PreferenceFieldMerge.merging(local, remote)
        let backward = try PreferenceFieldMerge.merging(remote, local)
        #expect(forward.payload.sortOrder == nil)
        #expect(forward.payload == backward.payload)
        #expect(forward.fieldUpdatedAt == backward.fieldUpdatedAt)
        var conflict = old
        conflict.sortOrder = "descending"
        let sameVersion = ExperimentalPreferenceSyncEnvelope(
            updatedAt: time, payload: conflict, fieldUpdatedAt: ["sortOrder": time])
        #expect(
            try PreferenceFieldMerge.merging(local, sameVersion).payload
                == PreferenceFieldMerge.merging(sameVersion, local).payload)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters])
    func explicitPrefRecoveryRebuildsOnlyAccount(_ domain: ExperimentalPreferenceSyncDomain)
        async throws
    {
        for record in [
            Data("broken".utf8),
            Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8), "invalid type",
        ] as [Any] {
            let prefix =
                domain == .appSettings
                ? AppSettingsStore.storageKeyPrefix : "score.filter.preferences"
            let value = try device(
                "BIT101Tests.preference-merge.explicit-recovery",
                localRecords: [.appSettings: record, .scoreFilters: record],
                rawSnapshots: [prefix: Data("broken snapshot".utf8)])
            defer { value.defaults.removePersistentDomain(forName: value.domain) }
            let other: ExperimentalPreferenceSyncDomain =
                domain == .appSettings ? .scoreFilters : .appSettings
            let session = AppStorageSession(accountIdentifier: "merge-account")
            let key =
                """
                experimental.preference-cloud-sync.local-envelope.\
                \(session.accountStorageIdentifier).\(domain.rawValue)
                """
            let otherKey =
                """
                experimental.preference-cloud-sync.local-envelope.\
                \(session.accountStorageIdentifier).\(other.rawValue)
                """
            let anotherAccountKey =
                "experimental.preference-cloud-sync.local-envelope.other-account.\(domain.rawValue)"
            value.defaults.set(Data("other account".utf8), forKey: anotherAccountKey)
            let otherCloud = Data("other domain".utf8)
            value.cloud.set(otherCloud, forKey: value.record(other))
            if domain == .appSettings {
                value.sync.settings.restoreAccountPreferences()
            } else {
                value.sync.stores.scoreFilterPreferences.reset()
            }
            let repaired = try #require(value.defaults.data(forKey: key))
            if domain == .appSettings {
                _ = try JSONDecoder().decode(
                    ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self, from: repaired)
                value.sync.settings.updateGallerySettings(useWebView: true)
            } else {
                _ = try JSONDecoder().decode(
                    ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
                    from: repaired)
                value.sync.stores.scoreFilterPreferences.save(
                    selectedTerms: ["recovered"], selectedCourseTypes: [], sortIndex: .score,
                    sortOrder: .ascending)
            }
            await value.sync.refreshFromCloudIfNeeded()?.value
            let uploaded = try #require(value.cloud.data(forKey: value.record(domain)))
            if domain == .appSettings {
                #expect(
                    try JSONDecoder().decode(
                        ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
                        from: uploaded
                    ).payload.galleryUseWebView)
            } else {
                #expect(
                    try JSONDecoder().decode(
                        ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
                        from: uploaded
                    ).payload.selectedTerms == ["recovered"])
            }
            if let bytes = record as? Data {
                #expect(value.defaults.data(forKey: otherKey) == bytes)
            } else {
                #expect(value.defaults.string(forKey: otherKey) == record as? String)
            }
            #expect(value.defaults.data(forKey: anotherAccountKey) == Data("other account".utf8))
            #expect(value.cloud.data(forKey: value.record(other)) == otherCloud)
        }
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: [false, true],
        ["malformed", "missingKey", "invalidType"])
    func unreadableLegacyScoresRetainTheirRawRecord(encryptedCurrent: Bool, legacyDefect: String)
        async throws
    {
        let value = try device("BIT101Tests.preference-merge.legacy-score-recovery")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let account = AppStorageSession(accountIdentifier: "merge-account").accountDirectoryName
        let key = value.record(.scoreCache)
        let legacyKey = key.replacingOccurrences(of: ".v2.", with: ".v1.")
        let encryption = ScoreCacheSyncEncryption(
            defaults: value.defaults, credentials: value.cloud.keys)
        let time = Date(timeIntervalSince1970: 300)
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        let payload = try JSONEncoder().encode(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: time,
                payload: ScoreCacheSyncPayload(rows: rows, updatedAt: time, detailedUpdatedAt: nil))
        )
        let legacy: Any
        if legacyDefect == "missingKey" {
            let oldEncryption = ScoreCacheSyncEncryption(
                defaults: value.defaults, credentials: PreferenceMemoryScoreKeys())
            legacy = try oldEncryption.seal(payload, account: account)
            value.defaults.removeObject(
                forKey: "experimental.preference-cloud-sync.score-key.\(account)")
        } else {
            legacy = legacyDefect == "malformed" ? Data("broken".utf8) : "invalid type"
        }
        value.cloud.set(legacy, forKey: legacyKey)
        value.cloud.set(
            encryptedCurrent ? try encryption.seal(payload, account: account) : payload, forKey: key
        )
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(try await value.sync.stores.scoreCache.syncPayload(for: nil)?.rows == rows)
        #expect(value.sync.syncIssue?.contains("历史记录") == true)
        #expect(ScoreCacheSyncEncryption.isEncrypted(try #require(value.cloud.data(forKey: key))))
        let editedRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["98"])]
        #expect(await value.sync.stores.scoreCache.save(rows: editedRows, for: nil) != nil)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let current = try await PreferenceCloudPayloadCodec.decode(
            ScoreCacheSyncPayload.self,
            open: encryption.prepareOpen(#require(value.cloud.data(forKey: key)), account: account))
        #expect(current.payload.rows == editedRows)
        if let bytes = legacy as? Data {
            #expect(value.cloud.data(forKey: legacyKey) == bytes)
        } else {
            #expect(value.cloud.dictionaryRepresentation[legacyKey] as? String == legacy as? String)
        }
        let recoveredTime = Date().addingTimeInterval(100)
        value.cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: recoveredTime,
                    payload: ScoreCacheSyncPayload(
                        rows: rows, updatedAt: recoveredTime, detailedUpdatedAt: nil))),
            forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.cloud.data(forKey: legacyKey) == nil)
        #expect(value.sync.syncIssue == nil)
        #expect(try await value.sync.stores.scoreCache.syncPayload(for: nil)?.rows == rows)
    }

    @Test(.timeLimit(.minutes(1))) func disabledEdits() async throws {
        let value = try device("BIT101Tests.preference-merge.disabled")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.setEnabled(false)
        value.sync.settings.updateGallerySettings(useWebView: true)
        #expect(value.cloud.dictionaryRepresentation.isEmpty)
        var remote = AppSettingsSnapshot()
        remote.galleryHiddenUserIDs = [99]
        value.cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: Date(timeIntervalSince1970: 100),
                    payload: AppSettingsSyncPayload(snapshot: remote))),
            forKey: value.record(.appSettings))
        value.sync.setEnabled(true)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryUseWebView)
        #expect(value.sync.settings.galleryHiddenUserIDs == [99])
    }
    @Test(.timeLimit(.minutes(1))) func invalid() async throws {
        let value = try device("BIT101Tests.preference-protection")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        for domain in ExperimentalPreferenceSyncDomain.allCases {
            let bytes = Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8)
            value.cloud.set(bytes, forKey: value.record(domain))
            if domain == .scoreCache {
                _ = await value.sync.stores.scoreCache.save(rows: [], for: nil)
            }
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

    @Test(.timeLimit(.minutes(1))) func invalidAnd() async throws {
        let invalidRecords: [Any] = [
            Data("broken".utf8),
            Data("{\"schemaVersion\":99,\"updatedAt\":100,\"payload\":{}}".utf8),
            "invalid stored type",
        ]
        for record in invalidRecords {
            let value = try device(
                "BIT101Tests.local-preference-protection",
                localRecords: [.appSettings: record, .scoreFilters: record])
            defer { value.defaults.removePersistentDomain(forName: value.domain) }
            #expect(value.sync.syncIssue != nil)
            value.sync.setEnabled(false)
            value.sync.settings.updateGallerySettings(useWebView: true)
            value.sync.stores.scoreFilterPreferences.save(
                selectedTerms: ["term"], selectedCourseTypes: [],
                sortIndex: .score, sortOrder: .descending)
            value.sync.setEnabled(true)
            await value.sync.refreshFromCloudIfNeeded()?.value
            let reopened = ExperimentalPreferenceCloudSync(
                settings: value.sync.settings, stores: value.sync.stores,
                defaults: value.defaults, cloudStore: value.cloud,
                scoreEncryption: ScoreCacheSyncEncryption(
                    defaults: value.defaults, credentials: value.cloud.keys),
                notificationCenter: NotificationCenter())
            reopened.reloadForCurrentAccount()
            await reopened.refreshFromCloudIfNeeded()?.value
            #expect(reopened.syncIssue != nil)
            #expect(value.cloud.data(forKey: value.record(.appSettings)) == nil)
            #expect(value.cloud.data(forKey: value.record(.scoreFilters)) == nil)
            let account = AppStorageSession(accountIdentifier: "merge-account")
            let owner = account.accountStorageIdentifier
            for domain in [ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters] {
                let key =
                    "experimental.preference-cloud-sync.local-envelope.\(owner).\(domain.rawValue)"
                if let bytes = record as? Data {
                    #expect(value.defaults.data(forKey: key) == bytes)
                } else {
                    #expect(value.defaults.string(forKey: key) == record as? String)
                }
            }
            #expect(value.sync.settings.galleryUseWebView)
            #expect(value.sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["term"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func additiveFieldsAndTheirVersionsSurviveMerge() async throws {
        let value = try device("BIT101Tests.preference-additive-fields")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let timestamp = Date(timeIntervalSince1970: 100)
        let extra: PreferenceJSONValue = .object([
            "ids": .array([.number(9_007_199_254_740_993)]), "enabled": .bool(true),
        ])
        let remote = ExperimentalPreferenceSyncEnvelope(
            updatedAt: timestamp,
            payload: AppSettingsSyncPayload(snapshot: AppSettingsSnapshot()),
            fieldUpdatedAt: ["futureSetting": timestamp], additionalFields: ["futureSetting": extra]
        )
        let key = value.record(.appSettings)
        value.cloud.set(try JSONEncoder().encode(remote), forKey: key)
        await value.sync.refreshFromCloudIfNeeded()?.value
        value.sync.settings.updateGallerySettings(useWebView: true)
        let reopened = ExperimentalPreferenceCloudSync(
            settings: value.sync.settings, stores: value.sync.stores,
            defaults: value.defaults, cloudStore: value.cloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: value.defaults, credentials: value.cloud.keys),
            notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields["futureSetting"] == extra)
        #expect(restored.fieldUpdatedAt?["futureSetting"] == timestamp)
        #expect(restored.payload.galleryUseWebView)
    }

    @Test(.timeLimit(.minutes(1))) func equalVersionAdditionalCloud() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let payload = AppSettingsSyncPayload(snapshot: AppSettingsSnapshot())
        var versions =
            try PreferenceFieldMerge.recording(
                payload,
                previous: Optional<ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>>.none,
                at: timestamp
            ).fieldUpdatedAt ?? [:]
        versions["futureSetting"] = timestamp
        let local = ExperimentalPreferenceSyncEnvelope(
            updatedAt: timestamp, payload: payload,
            fieldUpdatedAt: versions, additionalFields: ["futureSetting": .string("z")])
        let remote = ExperimentalPreferenceSyncEnvelope(
            updatedAt: timestamp, payload: payload,
            fieldUpdatedAt: local.fieldUpdatedAt, additionalFields: ["futureSetting": .string("a")])
        let value = try device(
            "BIT101Tests.preference-additional-field-conflict",
            localRecords: [.appSettings: JSONEncoder().encode(local)])
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        value.cloud.set(try JSONEncoder().encode(remote), forKey: key)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let cloud = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(cloud.additionalFields == local.additionalFields)
        #expect(cloud.fieldUpdatedAt == local.fieldUpdatedAt)
        let reopened = ExperimentalPreferenceCloudSync(
            settings: value.sync.settings, stores: value.sync.stores,
            defaults: value.defaults, cloudStore: value.cloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: value.defaults, credentials: value.cloud.keys),
            notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields == local.additionalFields)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func legacyMigrationRetainsSourceUntilFits(rejectWrite: Bool) async throws {
        let value = try device("BIT101Tests.preference-record-migration")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        let legacyKey = key.replacingOccurrences(
            of: "preference-sync.v2.", with: "preference-sync.v1.")
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [42]
        let envelope = ExperimentalPreferenceSyncEnvelope(
            updatedAt: Date(timeIntervalSince1970: 100),
            payload: AppSettingsSyncPayload(snapshot: snapshot))
        var raw = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        raw.removeValue(forKey: "schemaVersion")
        let legacy = try JSONSerialization.data(withJSONObject: raw)
        let availableBytes = try JSONEncoder().encode(envelope).count - 1
        value.cloud.set(legacy, forKey: legacyKey)
        if rejectWrite {
            value.cloud.rejectedKey = key
        } else {
            value.cloud.set(
                Data(
                    count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize - legacy.count
                        - availableBytes), forKey: "other-account")
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let retained = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
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
    func coexistingLegacySettingsMergeFieldVersions(rejectWrite: Bool) async throws {
        let value = try device("BIT101Tests.preference-merge.coexisting-settings")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        let legacyKey = key.replacingOccurrences(of: ".v2.", with: ".v1.")
        let currentTime = Date(timeIntervalSince1970: 300)
        let legacyTime = Date(timeIntervalSince1970: 200)
        var current = AppSettingsSnapshot()
        current.galleryHiddenUserIDs = [42]
        current.galleryUseWebView = true
        var legacy = AppSettingsSnapshot()
        legacy.galleryHiddenUserIDs = [99]
        legacy.galleryHideAnonymousContent = true
        let currentData = try JSONEncoder().encode(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: currentTime,
                payload: AppSettingsSyncPayload(snapshot: current),
                fieldUpdatedAt: [
                    "galleryHiddenUserIDs": currentTime,
                    "galleryUseWebView": currentTime,
                    "galleryStrictUserFilter": Date(timeIntervalSince1970: 100),
                ]))
        func legacyData(at time: Date) throws -> Data {
            let encoded = try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: time,
                    payload: AppSettingsSyncPayload(snapshot: legacy)))
            var raw = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            raw.removeValue(forKey: "schemaVersion")
            return try JSONSerialization.data(withJSONObject: raw)
        }
        value.cloud.set(currentData, forKey: key)
        value.cloud.set(try legacyData(at: legacyTime), forKey: legacyKey)
        if rejectWrite { value.cloud.rejectedKey = key }
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [42])
        #expect(
            value.sync.settings.galleryUseWebView && value.sync.settings.galleryHideAnonymousContent
        )
        if rejectWrite {
            #expect(
                value.cloud.data(forKey: legacyKey) != nil
                    && value.cloud.data(forKey: key) == currentData)
            value.cloud.rejectedKey = nil
            await value.sync.refreshFromCloudIfNeeded()?.value
        }
        let merged = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(
            merged.payload.galleryHiddenUserIDs == [42] && merged.payload.galleryUseWebView
                && merged.payload.galleryHideAnonymousContent)
        #expect(value.cloud.data(forKey: legacyKey) == nil)
        value.cloud.set(try legacyData(at: currentTime.addingTimeInterval(100)), forKey: legacyKey)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.settings.galleryHiddenUserIDs == [99])
        #expect(
            !value.sync.settings.galleryUseWebView
                && value.sync.settings.galleryHideAnonymousContent)
        #expect(value.cloud.data(forKey: legacyKey) == nil)
    }

}
