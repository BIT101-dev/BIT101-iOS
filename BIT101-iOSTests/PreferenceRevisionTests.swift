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

extension PreferenceMergeTests {
    @Test(.timeLimit(.minutes(1))) func coexistingLegacyRecordsPreserveFiltersDs() async throws {
        let value = try device("BIT101Tests.preference-merge.coexisting-domains")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let currentTime = Date(timeIntervalSince1970: 300)
        let legacyTime = Date(timeIntervalSince1970: 200)
        func store<Payload: Codable>(
            _ current: ExperimentalPreferenceSyncEnvelope<Payload>,
            _ legacy: ExperimentalPreferenceSyncEnvelope<Payload>,
            domain: ExperimentalPreferenceSyncDomain
        ) throws {
            let key = value.record(domain)
            value.cloud.set(try JSONEncoder().encode(current), forKey: key)
            var raw = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
                    as? [String: Any])
            raw.removeValue(forKey: "schemaVersion")
            value.cloud.set(
                try JSONSerialization.data(withJSONObject: raw),
                forKey: key.replacingOccurrences(of: ".v2.", with: ".v1."))
        }
        try store(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: currentTime,
                payload: ScoreFilterPreferenceSnapshot(
                    selectedTerms: ["current"], selectedCourseTypes: [], sortIndex: nil,
                    sortOrder: nil),
                fieldUpdatedAt: [
                    "selectedTerms": currentTime,
                    "selectedCourseTypes": Date(timeIntervalSince1970: 100),
                ]),
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: legacyTime,
                payload: ScoreFilterPreferenceSnapshot(
                    selectedTerms: ["legacy"], selectedCourseTypes: ["required"], sortIndex: nil,
                    sortOrder: nil)), domain: .scoreFilters)
        var currentReads = GalleryMessageReadSnapshot()
        currentReads.seenIDsByType = ["comment": [1]]
        var legacyReads = GalleryMessageReadSnapshot()
        legacyReads.seenIDsByType = ["comment": [2]]
        try store(
            ExperimentalPreferenceSyncEnvelope(updatedAt: currentTime, payload: currentReads),
            ExperimentalPreferenceSyncEnvelope(updatedAt: legacyTime, payload: legacyReads),
            domain: .galleryMessageRead)
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        try store(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: legacyTime,
                payload: ScoreCacheSyncPayload(
                    rows: [], updatedAt: legacyTime, detailedUpdatedAt: nil)),
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: currentTime,
                payload: ScoreCacheSyncPayload(
                    rows: rows, updatedAt: currentTime, detailedUpdatedAt: nil)),
            domain: .scoreCache)
        await value.sync.refreshFromCloudIfNeeded()?.value
        #expect(value.sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["current"])
        #expect(
            value.sync.stores.scoreFilterPreferences.load()?.selectedCourseTypes == ["required"])
        #expect(
            value.sync.stores.communityMessages.syncSnapshot().seenIDsByType["comment"] == [1, 2])
        #expect(
            try await value.sync.stores.scoreCache.syncPayload(
                for: AppStorageSession(accountIdentifier: "merge-account"))?.rows == rows)
        let scoreData = try #require(value.cloud.data(forKey: value.record(.scoreCache)))
        #expect(ScoreCacheSyncEncryption.isEncrypted(scoreData))
        #expect(
            try value.sync.decodeScoreCloudEnvelope(
                ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: scoreData
            ).payload.rows == rows)
        for domain in [
            ExperimentalPreferenceSyncDomain.scoreFilters, .galleryMessageRead, .scoreCache,
        ] {
            #expect(
                value.cloud.data(
                    forKey: value.record(domain).replacingOccurrences(of: ".v2.", with: ".v1."))
                    == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func settingsReconcileAgainMerge() async throws {
        let value = try device("BIT101Tests.preference-merge.settings-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.settings.updateGallerySettings(useWebView: true)
        let time = Date().addingTimeInterval(100)
        func record(_ ids: [Int], at version: Date) throws -> Data {
            var snapshot = AppSettingsSnapshot()
            snapshot.galleryHiddenUserIDs = ids
            return try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: version,
                    payload: AppSettingsSyncPayload(snapshot: snapshot),
                    fieldUpdatedAt: ["galleryHiddenUserIDs": version]))
        }
        let key = value.record(.appSettings)
        let first = try record([1], at: time)
        let second = try record([2], at: time.addingTimeInterval(100))
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                value.sync.settings.galleryHiddenUserIDs == [1]
            else { return }
            changed = true
            value.cloud.onSnapshot = nil
            value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && value.sync.settings.galleryUseWebView)
        #expect(value.sync.settings.galleryHiddenUserIDs == [2])
        #expect(uploaded.payload.galleryHiddenUserIDs == [2] && uploaded.payload.galleryUseWebView)
    }

    @Test(.timeLimit(.minutes(1))) func filtersReconcileAgainMerge() async throws {
        let value = try device("BIT101Tests.preference-merge.filters-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        value.sync.stores.scoreFilterPreferences.save(
            selectedTerms: ["local"], selectedCourseTypes: [], sortIndex: .score,
            sortOrder: .ascending)
        let time = Date().addingTimeInterval(100)
        func record(_ type: String, at version: Date) throws -> Data {
            let payload = ScoreFilterPreferenceSnapshot(
                selectedTerms: [], selectedCourseTypes: [type], sortIndex: nil, sortOrder: nil)
            return try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: version, payload: payload,
                    fieldUpdatedAt: ["selectedCourseTypes": version]))
        }
        let key = value.record(.scoreFilters)
        let first = try record("first", at: time)
        let second = try record("second", at: time.addingTimeInterval(100))
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                value.sync.stores.scoreFilterPreferences.load()?.selectedCourseTypes == ["first"]
            else { return }
            changed = true
            value.cloud.onSnapshot = nil
            value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.selectedTerms == ["local"])
        #expect(uploaded.payload.selectedCourseTypes == ["second"])
        #expect(value.sync.stores.scoreFilterPreferences.load() == uploaded.payload)
    }

    @Test(.timeLimit(.minutes(1))) func messageReadsIncludeUpload() async throws {
        let value = try device("BIT101Tests.preference-merge.messages-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        await value.sync.stores.communityMessages.markSeen(ids: [1], for: .comment)
        func record(_ id: Int) throws -> Data {
            var snapshot = GalleryMessageReadSnapshot()
            snapshot.seenIDsByType = ["comment": [id]]
            return try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(updatedAt: Date(), payload: snapshot))
        }
        let key = value.record(.galleryMessageRead)
        let first = try record(2)
        let second = try record(3)
        value.cloud.set(first, forKey: key)
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                value.sync.stores.communityMessages.syncSnapshot().seenIDsByType["comment"] == [
                    1, 2,
                ]
            else { return }
            changed = true
            value.cloud.onSnapshot = nil
            value.cloud.set(second, forKey: key)
        }
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<GalleryMessageReadSnapshot>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.seenIDsByType["comment"] == [1, 2, 3])
        #expect(value.sync.stores.communityMessages.syncSnapshot() == uploaded.payload)
    }

    @Test(.timeLimit(.minutes(1))) func scoreUploadReevaluatesTheNewerCloudVersion() async throws {
        let value = try device("BIT101Tests.preference-merge.score-race")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let session = AppStorageSession(accountIdentifier: "merge-account")
        let seal = try ScoreCacheSyncEncryption(
            defaults: value.defaults, credentials: value.cloud.keys
        ).prepareSeal(account: session.accountDirectoryName)
        let time = Date().addingTimeInterval(100)
        let remoteRows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["remote", "95"])]
        let first = try await PreferenceCloudPayloadCodec.encode(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: time,
                payload: ScoreCacheSyncPayload(rows: [], updatedAt: time, detailedUpdatedAt: nil)),
            seal: seal)
        let second = try await PreferenceCloudPayloadCodec.encode(
            ExperimentalPreferenceSyncEnvelope(
                updatedAt: time.addingTimeInterval(100),
                payload: ScoreCacheSyncPayload(
                    rows: remoteRows, updatedAt: time, detailedUpdatedAt: nil)), seal: seal)
        let key = value.record(.scoreCache)
        value.cloud.set(first, forKey: key)
        let versionKey =
            """
            experimental.preference-cloud-sync.local-updated.\
            \(session.accountStorageIdentifier).score-cache
            """
        var changed = false
        value.cloud.onSnapshot = { snapshot in
            guard !changed, snapshot[key] as? Data == first,
                (value.defaults.object(forKey: versionKey) as? Date ?? .distantPast) > time
            else { return }
            changed = true
            value.cloud.onSnapshot = nil
            value.cloud.set(second, forKey: key)
        }
        _ = await value.sync.stores.scoreCache.save(
            rows: [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["local", "80"])], for: nil)
        await value.sync.refreshFromCloudIfNeeded()?.value
        let uploaded = try value.sync.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(value.cloud.data(forKey: key)))
        #expect(changed && uploaded.payload.rows == remoteRows)
        #expect(
            try await value.sync.stores.scoreCache.syncPayload(for: session)?.rows == remoteRows)
    }

    @Test(.timeLimit(.minutes(1))) func oneLargeLegacyKeepsSyncingWithinQuota() async throws {
        let value = try device("BIT101Tests.preference-merge.large-legacy")
        defer { value.defaults.removePersistentDomain(forName: value.domain) }
        let key = value.record(.appSettings)
        let legacy = key.replacingOccurrences(
            of: "preference-sync.v2.", with: "preference-sync.v1.")
        let extra = PreferenceJSONValue.string(
            String(
                repeating: "x",
                count: ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize * 3 / 4))
        value.cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: Date(timeIntervalSince1970: 100),
                    payload: AppSettingsSyncPayload(snapshot: AppSettingsSnapshot()),
                    additionalFields: ["futureSetting": extra])), forKey: legacy)
        #expect(value.cloud.dictionaryRepresentation.count == 1)
        for enabled in [true, false] {
            value.sync.settings.updateGallerySettings(useWebView: enabled)
            await value.sync.refreshFromCloudIfNeeded()?.value
            let data = try #require(value.cloud.data(forKey: legacy))
            let uploaded = try JSONDecoder().decode(
                ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self, from: data)
            #expect(
                uploaded.payload.galleryUseWebView == enabled
                    && uploaded.additionalFields["futureSetting"] == extra)
            #expect(value.cloud.data(forKey: key) == nil)
            let totalBytes = value.cloud.dictionaryRepresentation.values.compactMap { $0 as? Data }
                .reduce(0) { $0 + $1.count }
            #expect(totalBytes <= ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize)
            #expect(
                data.count <= ExperimentalPreferenceCloudQuotaPolicy.maximumValueSize
                    && value.sync.syncIssue == nil)
        }
    }
}
