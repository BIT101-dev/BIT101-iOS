import Combine
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

    private func device(_ domain: String, localRecords: [ExperimentalPreferenceSyncDomain: Any] = [:], rawSnapshots: [String: Any] = [:]) throws -> Device {
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let session = AppStorageSession(accountIdentifier: "merge-account")
        for (prefix, value) in rawSnapshots { defaults.set(value, forKey: session.key(prefix)) }
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
        for (domain, record) in localRecords {
            defaults.set(record, forKey: "experimental.preference-cloud-sync.local-envelope.\(session.accountStorageIdentifier).\(domain.rawValue)")
        }
        let cloud = Cloud()
        return Device(domain: domain, defaults: defaults, cloud: cloud,
            sync: ExperimentalPreferenceCloudSync(settings: settings, stores: stores, defaults: defaults,
                cloudStore: cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: defaults, credentials: cloud.keys), notificationCenter: NotificationCenter()))
    }

    @Test(arguments: [ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters, .galleryMessageRead])
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
        value.sync.stores.communityMessages.markSeen(ids: [100], for: .comment)
        value.sync.localValueDidChange(in: domain)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let session = AppStorageSession(accountIdentifier: "merge-account")
        #expect(value.defaults.data(forKey: session.key(prefix)) == damaged)
        #expect(value.cloud.data(forKey: value.record(domain)) == nil)
        #expect(value.defaults.data(forKey: "experimental.preference-cloud-sync.local-envelope.\(session.accountStorageIdentifier).\(domain.rawValue)") == nil)
        #expect(value.sync.syncIssue != nil)
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

    @Test func offlineFilterChangesPreserveTermsAndSorting() async throws {
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

    @Test func invalidAndFutureLocalRecordsKeepTheirBytesAcrossLaunchEditsAndReload() async throws {
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
            defaults: value.defaults, cloudStore: value.cloud, scoreEncryption: ScoreCacheSyncEncryption(defaults: value.defaults, credentials: value.cloud.keys), notificationCenter: NotificationCenter())
        await reopened.refreshFromCloudIfNeeded()?.value
        let restored = try JSONDecoder().decode(ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(restored.additionalFields["futureSetting"] == extra)
        #expect(restored.fieldUpdatedAt?["futureSetting"] == timestamp)
        #expect(restored.payload.galleryUseWebView)
    }

    @Test func equalVersionAdditionalFieldConflictsConvergeInCloudAndAfterReopen() async throws {
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

    @Test func settingsReconcileAgainWhenTheCloudChangesAfterTheFirstMerge() async throws {
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

    @Test func filtersReconcileAgainWhenTheCloudChangesAfterTheFirstMerge() async throws {
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

    @Test func messageReadsIncludeTheRecordThatArrivesDuringUpload() async throws {
        let value = try device("BIT101Tests.preference-merge.messages-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
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

    @Test func scoreUploadReevaluatesTheNewerCloudVersion() async throws {
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
        #expect(await value.sync.stores.scoreCache.syncPayload(for: session)?.rows == remoteRows)
    }

    @Test func oneLargeLegacyRecordKeepsSyncingWithinTheExistingQuota() async throws {
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
