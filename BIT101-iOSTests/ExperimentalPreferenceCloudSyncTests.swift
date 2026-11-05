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

@MainActor
final class PreferenceMemoryScoreKeys: LoginCredentialsStoring {
    var values: [String: String] = [:]
    var allowsDeletion = true
    func read(account: String) throws -> String { values[account] ?? "" }
    func save(_ value: String, account: String) throws { values[account] = value }
    func delete(account: String) -> Bool {
        guard allowsDeletion else { return false }
        values[account] = nil
        return true
    }
}

@MainActor
@Suite("Experimental preference iCloud sync", .serialized)
struct ExperimentalPreferenceCloudSyncTests {
    let preferenceDomain = "BIT101Tests.preference-sync"

    final class Account {
        var session = AppStorageSession(accountIdentifier: "preference-account") {
            didSet {
                generation &+= 1
                changes.send(identity)
            }
        }
        private var generation = 0
        let changes = PassthroughSubject<CommunitySessionIdentity, Never>()
        var identity: CommunitySessionIdentity {
            .init(accountIdentifier: session.accountIdentifier, generation: generation)
        }
    }

    final class MemoryCloud: PreferenceCloudStoring {
        var values: [String: Any] = [:]
        var dictionaryRepresentation: [String: Any] {
            get {
                beforeSnapshotRead?()
                return values
            }
            set { values = newValue }
        }
        let scoreKeys = PreferenceMemoryScoreKeys()
        var synchronizationSucceeds = true
        var synchronizationCalls = 0
        var onSet: ((String) -> Void)?
        var beforeSnapshotRead: (() -> Void)?
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) {
            values[key] = value
            onSet?(key)
        }
        func synchronize() -> Bool {
            synchronizationCalls += 1
            return synchronizationSucceeds
        }
        func waitForWrite(to key: String) async throws {
            try await waitForTestEvent { dictionaryRepresentation[key] != nil }
        }
    }

    final class SuspendedScoreCache: ScoreCacheSynchronizing {
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? { nil }
        let saves = PassthroughSubject<AppStorageSession, Never>()
        var localSaves: AnyPublisher<AppStorageSession, Never> { saves.eraseToAnyPublisher() }
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var payload = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])], updatedAt: nil,
            detailedUpdatedAt: nil)
        var read: CheckedContinuation<ScoreCacheSyncPayload?, Never>?
        var apply: CheckedContinuation<Void, Never>?
        var suspendRead = true
        var suspendApply = false
        var applied = 0
        var failsRead = false
        var failsApply = false
        func syncPayload(for session: AppStorageSession?) async throws -> ScoreCacheSyncPayload? {
            if failsRead { throw ScoreCacheReadError.unreadable }
            if suspendRead {
                suspendRead = false
                return await withCheckedContinuation { read = $0 }
            }
            return payload
        }
        func applySynced(
            _ remote: ScoreCacheSyncPayload, for session: AppStorageSession?,
            replacing expected: ScoreCacheSyncPayload?
        ) async throws -> Bool {
            if failsApply { throw ScoreCacheWriteError.failed }
            if suspendApply {
                suspendApply = false
                await withCheckedContinuation { apply = $0 }
            }
            guard payload == expected else { return false }
            payload = remote
            applied += 1
            return true
        }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? { nil }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreReconcilePreservesSavesDuringReads(remoteApply: Bool) async throws {
        let cache = SuspendedScoreCache()
        cache.suspendRead = !remoteApply
        cache.suspendApply = remoteApply
        let (sync, defaults, cloud, account) = try context(
            scoreCache: cache, synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let old = cache.payload
        let recordKey = key(.scoreCache, account: account)
        if remoteApply {
            cloud.set(
                try ScoreCacheSyncPayloadCodec.encode(
                    ExperimentalPreferenceSyncEnvelope(
                        updatedAt: Date(timeIntervalSince1970: 200), payload: old)),
                forKey: recordKey)
        }
        sync.localValueDidChange(in: .scoreCache)
        if remoteApply {
            // 远端版本高于已记录的本地版本，协调进入挂起的应用阶段。
            cloud.set(
                try ScoreCacheSyncPayloadCodec.encode(
                    ExperimentalPreferenceSyncEnvelope(
                        updatedAt: Date.distantFuture, payload: old)), forKey: recordKey)
        }
        let task = sync.refreshFromCloudIfNeeded()
        try await waitForTestEvent { remoteApply ? cache.apply != nil : cache.read != nil }
        cache.payload = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(), detailedUpdatedAt: nil)
        cache.saves.send(account.session)
        if remoteApply { cache.apply?.resume() } else { cache.read?.resume(returning: old) }
        await task?.value
        let uploaded = try sync.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(cloud.data(forKey: recordKey)))
        #expect(uploaded.payload == cache.payload)
        #expect(uploaded.payload.rows.first?.values.first?.value == "95")
        #expect(cache.applied == 0)
        let versionKey =
            """
            experimental.preference-cloud-sync.local-updated.\
            \(account.session.accountStorageIdentifier).\
            \(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)
            """
        let recordedVersion = try #require(defaults.object(forKey: versionKey) as? Date)
        #expect(uploaded.updatedAt == recordedVersion)
    }

    func context(
        domain: String? = nil, files: PreferenceMemoryFiles = PreferenceMemoryFiles(),
        scoreCache: (any ScoreCacheSynchronizing)? = nil,
        notificationCenter center: NotificationCenter = NotificationCenter(),
        synchronizedDomains: Set<ExperimentalPreferenceSyncDomain> = Set(
            ExperimentalPreferenceSyncDomain.allCases)
    ) throws -> (ExperimentalPreferenceCloudSync, UserDefaults, MemoryCloud, Account) {
        let domain = domain ?? preferenceDomain
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let account = Account()
        let root = URL(fileURLWithPath: "/preference-sync")
        let settings = AppSettingsStore(defaults: defaults, session: { account.session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(
                files: files, storageRoot: root, defaults: defaults, session: { account.session }),
            composerDrafts: ComposerDraftStore(
                files: files, applicationSupport: root, session: { account.session },
                prepareImageData: ComposerDraftImageCompressor.compress),
            scoreCache: scoreCache
                ?? ScoreCacheStore(
                    files: files, storageRoot: root, defaults: defaults,
                    session: { account.session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(
                defaults: defaults, session: { account.session }),
            currentSession: { account.session }, scoreSession: { account.session }
        )
        defaults.set(
            true,
            forKey:
                """
                experimental.preference-cloud-sync.enabled.\
                \(account.session.accountStorageIdentifier)
                """
        )
        let cloud = MemoryCloud()
        let sync = ExperimentalPreferenceCloudSync(
            settings: settings, stores: stores, defaults: defaults, cloudStore: cloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: defaults, credentials: cloud.scoreKeys),
            synchronizedDomains: synchronizedDomains, notificationCenter: center
        )
        return (sync, defaults, cloud, account)
    }

    @Test(.timeLimit(.minutes(1))) func cloudNoticesCanArriveOnBackgroundThreads() async throws {
        let center = NotificationCenter()
        let (sync, defaults, _, _) = try context(notificationCenter: center)
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        await Task.detached {
            center.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil,
                userInfo: [
                    NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange
                ])
        }.value
        #expect(sync.isEnabled)
        #expect(sync.settings.galleryHiddenUserIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func unreadableScoresReportRecoveryReason(applyFailure: Bool) async throws {
        let cache = SuspendedScoreCache()
        cache.suspendRead = false
        cache.failsRead = !applyFailure
        cache.failsApply = applyFailure
        let (sync, defaults, cloud, account) = try context(
            scoreCache: cache, synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let remote = ScoreCacheSyncPayload(
            rows: cache.payload.rows, updatedAt: Date(timeIntervalSince1970: 200),
            detailedUpdatedAt: nil)
        if applyFailure {
            cloud.set(
                try ScoreCacheSyncPayloadCodec.encode(
                    ExperimentalPreferenceSyncEnvelope(
                        updatedAt: Date.distantFuture, payload: remote)),
                forKey: key(.scoreCache, account: account))
        }
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(
            sync.syncIssue
                == (applyFailure
                    ? ScoreCacheWriteError.failed.localizedDescription
                    : ScoreCacheReadError.unreadable.localizedDescription))
        #expect((cloud.data(forKey: key(.scoreCache, account: account)) != nil) == applyFailure)
        if applyFailure {
            #expect(
                cache.payload != remote
                    && defaults.object(
                        forKey:
                            """
                            experimental.preference-cloud-sync.local-updated.\
                            \(account.session.accountStorageIdentifier).\
                            \(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)
                            """
                    ) == nil)
        }
        cache.failsRead = false
        cache.failsApply = false
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(
            sync.syncIssue == nil && cloud.data(forKey: key(.scoreCache, account: account)) != nil)
        if applyFailure { #expect(cache.payload == remote) }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            ExperimentalPreferenceSyncDomain.appSettings, .scoreFilters, .galleryMessageRead,
        ])
    func failedPrefApplyPreservesMergeMetadata(domain: ExperimentalPreferenceSyncDomain)
        async throws
    {
        let files = PreferenceMemoryFiles()
        let (sync, defaults, cloud, account) = try context(
            files: files, synchronizedDomains: [domain])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let date = Date.distantFuture
        let data: Data
        let prefix: String
        switch domain {
        case .appSettings:
            var payload = AppSettingsSyncPayload(snapshot: AppSettingsSnapshot())
            payload.galleryHideAnonymousContent = true
            data = try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(updatedAt: date, payload: payload))
            prefix = AppSettingsStore.storageKeyPrefix
        case .scoreFilters:
            var payload = ScoreFilterPreferenceSnapshot()
            payload.selectedTerms = ["remote"]
            data = try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(updatedAt: date, payload: payload))
            prefix = "score.filter.preferences"
        case .galleryMessageRead:
            var payload = GalleryMessageReadSnapshot()
            payload.seenIDsByType = [GalleryMessageType.comment.rawValue: [1]]
            data = try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(updatedAt: date, payload: payload))
            prefix = "gallery.message.read.snapshot"
        case .scoreCache: return
        }
        let cloudKey = key(domain, account: account)
        let versionKey =
            """
            experimental.preference-cloud-sync.local-updated.\
            \(account.session.accountStorageIdentifier).\(domain.rawValue)
            """
        let envelopeKey =
            """
            experimental.preference-cloud-sync.local-envelope.\
            \(account.session.accountStorageIdentifier).\(domain.rawValue)
            """
        let version = defaults.object(forKey: versionKey) as? Date
        let envelope = defaults.data(forKey: envelopeKey)
        cloud.set(data, forKey: cloudKey)
        cloud.beforeSnapshotRead = {
            cloud.beforeSnapshotRead = nil
            defaults.set("damaged", forKey: account.session.key(prefix))
            files.setFailures(writing: domain == .galleryMessageRead)
        }
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue == PreferenceSyncRecordError.localWriteFailed.localizedDescription)
        #expect(
            defaults.object(forKey: versionKey) as? Date == version
                && defaults.data(forKey: envelopeKey) == envelope)
        #expect(
            cloud.data(forKey: cloudKey) == data
                && defaults.string(forKey: account.session.key(prefix)) == "damaged")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreMutationKeepsObservedRemoteBoundary(newRemote: Bool) async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        sync.setEnabled(false)
        let remoteDate = Date().addingTimeInterval(600)
        let row = ScoreRow(index: 0, headers: ["成绩"], values: ["80"])
        let remote = ScoreCacheSyncPayload(
            rows: [row], updatedAt: remoteDate, detailedUpdatedAt: nil)
        let cloudKey = key(.scoreCache, account: account)
        cloud.set(
            try ScoreCacheSyncPayloadCodec.encode(
                ExperimentalPreferenceSyncEnvelope(updatedAt: remoteDate, payload: remote)),
            forKey: cloudKey)
        let localRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await sync.stores.scoreCache.save(rows: localRows, for: account.session) != nil)
        if newRemote {
            var newer = remote
            newer.rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["99"])]
            cloud.set(
                try ScoreCacheSyncPayloadCodec.encode(
                    ExperimentalPreferenceSyncEnvelope(
                        updatedAt: remoteDate.addingTimeInterval(600), payload: newer)),
                forKey: cloudKey)
        }
        let restored = ExperimentalPreferenceCloudSync(
            settings: sync.settings, stores: sync.stores,
            defaults: defaults, cloudStore: cloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: defaults, credentials: cloud.scoreKeys),
            synchronizedDomains: [.scoreCache])
        restored.setEnabled(true)
        await restored.refreshFromCloudIfNeeded()?.value
        let payload = try #require(
            try await restored.stores.scoreCache.syncPayload(for: account.session))
        #expect(payload.rows.first?.values.first?.value == (newRemote ? "99" : "95"))
        let published = try restored.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(cloud.data(forKey: cloudKey)))
        if !newRemote {
            #expect(published.updatedAt > remoteDate && published.payload.rows == localRows)
        }
        #expect(
            defaults.object(
                forKey:
                    """
                    experimental.preference-cloud-sync.pending-score.\
                    \(account.session.accountStorageIdentifier)
                    """
            ) == nil)
    }

    func lifecycle(
        sync: ExperimentalPreferenceCloudSync, account: Account, displays: ExternalDisplays,
        changes: AnyPublisher<AppStorageSession, Never> = Empty().eraseToAnyPublisher(),
        prompts: AppPromptCoordinator = AppPromptCoordinator(),
        loadCourses:
            @escaping @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]] = {
                _ in [:]
            }, refreshCloud: @escaping @MainActor () async -> Void = {}
    ) -> AppAccountLifecycle {
        let repository = ScheduleRepository(
            session: { account.session }, load: { _ in .missing }, save: { _, _, _ in })
        let service = SemesterStartDateService()
        let schedule = ScheduleViewModel(
            service: service, repository: repository, ddlService: service,
            classroomService: service, platformActions: RecordingSchedulePlatformActions(),
            newCustomScheduleDraft: { CustomScheduleDraft() })
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        let media = AppMedia.makeEnvironment(
            files: PreferenceMemoryFiles(),
            previewStorage: MediaPreviewStorage(files: PreferenceMemoryFiles()),
            defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        let session = CommunitySession(
            httpClient: client, baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                CommunityCredentials(
                    identity: .init(accountIdentifier: account.session.accountIdentifier),
                    cookie: "fixture")
            }, refresh: { _ in })
        let community = AppCommunityDependencies(
            settings: sync.settings, session: session, checkLogin: { true },
            messages: sync.stores.communityMessages, drafts: sync.stores.composerDrafts,
            submitSuggestion: { _ in }, loadCourseCredits: { [] })
        return AppAccountLifecycle(
            scheduleViewModel: schedule, community: community, scoreService: OfflineScoreService(),
            transcriptService: OfflineScoreService(),
            diagnosisSchool: NetworkDiagnosisSchool(
                identity: {
                    .init(accountIdentifier: account.session.accountIdentifier, generation: 0)
                },
                currentTerm: { "fixture" }, syncCourses: { _ in },
                ddl: { DDLSyncPayload(url: "", events: []) }), settings: sync.settings,
            stores: sync.stores, preferenceCloudSync: sync,
            accountChanges: account.changes.eraseToAnyPublisher(),
            currentIdentity: { account.identity },
            scheduleChanges: changes,
            scheduleCloudSync: ScheduleCloudSyncPresentation(
                currentAccount: { nil }, accountChanges: account.changes.eraseToAnyPublisher()),
            refreshScheduleCloud: refreshCloud,
            isNotificationPermissionDenied: { false }, loadScheduleCourses: loadCourses,
            media: media,
            localData: AppLocalDataService(
                files: PreferenceMemoryFiles(), actions: LocalDataActionsSpy().actions),
            externalDisplays: displays, prompts: prompts)
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleForwardsCourseSourceScores() async throws {
        let (sync, defaults, _, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let changes = PassthroughSubject<AppStorageSession, Never>()
        let displays = ExternalDisplays()
        var loadedSessions: [AppStorageSession] = []
        let owner = lifecycle(
            sync: sync, account: account, displays: displays,
            changes: changes.eraseToAnyPublisher(),
            loadCourses: { session in
                loadedSessions.append(session)
                return [:]
            })
        changes.send(AppStorageSession(accountIdentifier: "other"))
        changes.send(account.session)
        try await waitForTestEvent { loadedSessions.isEmpty == false }
        #expect(loadedSessions == [account.session])
        #expect(
            owner.communityDestinations.settingsDependencies.media
                === owner.communityDestinations.media)
        withExtendedLifetime(owner) {}
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleInstancesOwnSettings() async throws {
        let firstDomain = preferenceDomain + ".first"
        let secondDomain = preferenceDomain + ".second"
        let (firstSync, firstDefaults, _, firstAccount) = try context(domain: firstDomain)
        let (secondSync, secondDefaults, _, secondAccount) = try context(domain: secondDomain)
        defer {
            firstDefaults.removePersistentDomain(forName: firstDomain)
            secondDefaults.removePersistentDomain(forName: secondDomain)
        }
        let changes = PassthroughSubject<AppStorageSession, Never>()
        let firstDisplays = ExternalDisplays()
        let secondDisplays = ExternalDisplays()
        let firstPrompts = AppPromptCoordinator(advanceDelay: .zero)
        let secondPrompts = AppPromptCoordinator(advanceDelay: .zero)
        firstPrompts.enqueue(
            AppPrompt(
                id: "thanks", title: "fixture", message: "fixture", actions: [],
                account: firstAccount.identity))
        secondPrompts.enqueue(
            AppPrompt(
                id: "thanks", title: "fixture", message: "fixture", actions: [],
                account: secondAccount.identity))
        let first = lifecycle(
            sync: firstSync, account: firstAccount, displays: firstDisplays,
            changes: changes.eraseToAnyPublisher(), prompts: firstPrompts)
        let second = lifecycle(
            sync: secondSync, account: secondAccount, displays: secondDisplays,
            prompts: secondPrompts)
        first.start()
        second.start()
        try await firstDisplays.waitForRefreshes(1)
        try await secondDisplays.waitForRefreshes(1)
        #expect(first.settings === firstSync.settings)
        #expect(second.settings === secondSync.settings)
        #expect(firstDisplays.activationCount == 1)
        #expect(secondDisplays.activationCount == 1)
        first.settings.updateGallerySettings(useWebView: true)
        #expect(first.community.preferences.galleryUseWebView)
        #expect(second.community.preferences.galleryUseWebView == false)
        firstAccount.session = AppStorageSession(accountIdentifier: "changed-account")
        try await firstDisplays.waitForRefreshes(2)
        #expect(firstDisplays.resetCount == 1)
        #expect(firstPrompts.activePrompt == nil)
        #expect(secondPrompts.activePrompt?.account == secondAccount.identity)
        firstAccount.changes.send(.init(accountIdentifier: "stale", generation: 0))
        #expect(firstDisplays.resetCount == 1)
        #expect(secondDisplays.resetCount == 0)
        #expect(firstDisplays.refreshes.last?.1 == firstAccount.session)
        #expect(secondDisplays.refreshes.count == 1)
        changes.send(firstAccount.session)
        try await firstDisplays.waitForRefreshes(3)
        #expect(firstDisplays.refreshes.last?.0 == "schedule_cache_changed")
        #expect(secondDisplays.refreshes.count == 1)
    }

    func key(_ domain: ExperimentalPreferenceSyncDomain, account: Account) -> String {
        "preference-sync.v2.\(account.session.accountDirectoryName).\(domain.rawValue)"
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleRestoresEnabledPrefsAtLaunch() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.appSettings])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        var schedulePulls: [CommunitySessionIdentity] = []
        let owner = lifecycle(
            sync: sync, account: account, displays: ExternalDisplays(),
            refreshCloud: { schedulePulls.append(account.identity) })
        let recordKey = key(.appSettings, account: account)
        owner.start()
        #expect(cloud.synchronizationCalls == 1)
        try await waitForTestEvent { schedulePulls.count == 1 }
        try await cloud.waitForWrite(to: recordKey)
        #expect(cloud.data(forKey: recordKey) != nil)
        cloud.set(nil, forKey: recordKey)
        let foregroundCalls = cloud.synchronizationCalls
        owner.sceneBecameActive()
        #expect(cloud.synchronizationCalls == foregroundCalls + 1)
        try await waitForTestEvent { schedulePulls.count == 2 }
        try await cloud.waitForWrite(to: recordKey)
        #expect(cloud.synchronizationCalls == foregroundCalls + 2)
        #expect(cloud.data(forKey: recordKey) != nil)
        sync.setEnabled(false)
        let calls = cloud.synchronizationCalls
        owner.sceneBecameActive()
        try await waitForTestEvent { schedulePulls.count == 3 }
        #expect(cloud.synchronizationCalls == calls)
        #expect(schedulePulls == Array(repeating: account.identity, count: 3))
        account.session = AppStorageSession(accountIdentifier: "another-account")
        try await waitForTestEvent { schedulePulls.count == 4 }
        #expect(schedulePulls.last == account.identity)
    }

    @Test(.timeLimit(.minutes(1))) func guestPrefSwitchAndRevisionSurviveReload() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        account.session = AppStorageSession(accountIdentifier: "")
        sync.reloadForCurrentAccount()
        sync.setEnabled(true)
        sync.localValueDidChange(in: .appSettings)
        let recordKey = key(.appSettings, account: account)
        let envelopeType = ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self
        await sync.refreshFromCloudIfNeeded()?.value
        let revision = try JSONDecoder().decode(
            envelopeType, from: #require(cloud.data(forKey: recordKey))
        ).updatedAt
        cloud.set(nil, forKey: recordKey)

        sync.reloadForCurrentAccount()
        try await cloud.waitForWrite(to: recordKey)

        #expect(sync.isEnabled)
        let restored = try JSONDecoder().decode(
            envelopeType, from: #require(cloud.data(forKey: recordKey)))
        #expect(restored.updatedAt == revision)
        sync.setEnabled(false)
        sync.reloadForCurrentAccount()
        #expect(sync.isEnabled == false)
    }

    @Test(.timeLimit(.minutes(1))) func storeSaveEventsReachEveryActiveCoordinator() async throws {
        let (first, defaults, firstCloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let secondCloud = MemoryCloud()
        let second = ExperimentalPreferenceCloudSync(
            settings: first.settings, stores: first.stores,
            defaults: defaults, cloudStore: secondCloud,
            scoreEncryption: ScoreCacheSyncEncryption(
                defaults: defaults, credentials: secondCloud.scoreKeys),
            notificationCenter: NotificationCenter())
        first.settings.updateGallerySettings(hiddenUserIDs: [42])
        let recordKey = key(.appSettings, account: account)
        await first.refreshFromCloudIfNeeded()?.value
        await second.refreshFromCloudIfNeeded()?.value
        #expect(firstCloud.data(forKey: recordKey) != nil)
        #expect(secondCloud.data(forKey: recordKey) != nil)
        withExtendedLifetime(second) {}
    }

    @Test(.timeLimit(.minutes(1))) func localCallbacksUploadInjectedSettings() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        sync.settings.updateGallerySettings(
            hideBotPosterInSearch: false, hiddenUserIDs: [42], useWebView: true)
        await sync.refreshFromCloudIfNeeded()?.value
        let settings = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: try #require(cloud.data(forKey: key(.appSettings, account: account)))
        )
        #expect(settings.payload.galleryHiddenUserIDs == [42])
        #expect(settings.payload.galleryHideBotPosterInSearch == false)
        #expect(settings.payload.galleryUseWebView)
        sync.stores.scoreFilterPreferences.save(
            selectedTerms: ["2026-2027-1"], selectedCourseTypes: [], sortIndex: .score,
            sortOrder: .descending)
        await sync.refreshFromCloudIfNeeded()?.value
        let filters = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
            from: try #require(cloud.data(forKey: key(.scoreFilters, account: account)))
        )
        #expect(filters.payload.selectedTerms == ["2026-2027-1"])
        await sync.stores.communityMessages.markSeen(ids: [42], for: .comment)
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(cloud.data(forKey: key(.galleryMessageRead, account: account)) != nil)
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["注入课程", "95"])]
        _ = try #require(await sync.stores.scoreCache.save(rows: rows, for: nil))
        await sync.refreshFromCloudIfNeeded()?.value
        let scores = try sync.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: try #require(cloud.data(forKey: key(.scoreCache, account: account)))
        )
        #expect(scores.payload.rows.map(\.id) == rows.map(\.id))
        #expect(
            scores.payload.rows.map { $0.values.map(\.key) } == rows.map { $0.values.map(\.key) })
        #expect(
            scores.payload.rows.map { $0.values.map(\.value) }
                == rows.map { $0.values.map(\.value) })
    }

    @Test(.timeLimit(.minutes(1))) func remoteSettingsApplyToTheInjectedInstance() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [73]
        snapshot.galleryHideAnonymousContent = true
        cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: Date(timeIntervalSince1970: 200),
                    payload: AppSettingsSyncPayload(snapshot: snapshot)
                )), forKey: key(.appSettings, account: account))
        sync.refreshFromCloudIfNeeded()
        try await cloud.waitForWrite(to: key(.galleryMessageRead, account: account))
        #expect(sync.settings.galleryHiddenUserIDs == [73])
        #expect(sync.settings.galleryHideAnonymousContent)
        let restored = AppSettingsStore(defaults: defaults, session: { account.session })
        #expect(restored.galleryHiddenUserIDs == [73])
    }

    @Test(.timeLimit(.minutes(1))) func disablingSyncKeepsCloudRecordUnchanged() async throws {
        let files = PreferenceMemoryFiles()
        let (sync, defaults, cloud, account) = try context(files: files)
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["课程", "95"])]
        _ = try #require(await sync.stores.scoreCache.save(rows: rows, for: nil))
        await sync.refreshFromCloudIfNeeded()?.value
        let recordKey = key(.scoreCache, account: account)
        let original = try #require(cloud.data(forKey: recordKey))
        let release = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: false)
        defer { release.signal() }
        files.interceptNextRead {
            entered.withLock { $0 = true }
            release.wait()
        }
        sync.localValueDidChange(in: .scoreCache)
        let task = sync.refreshFromCloudIfNeeded()
        try await waitForTestEvent { entered.withLock { $0 } }
        sync.setEnabled(false)
        release.signal()
        await task?.value
        #expect(cloud.data(forKey: recordKey) == original)
        #expect(sync.isEnabled == false)
        sync.setEnabled(true)
        await sync.refreshFromCloudIfNeeded()?.value
        let restored = try sync.decodeScoreCloudEnvelope(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(cloud.data(forKey: recordKey)))
        #expect(restored.payload.rows.map(\.id) == rows.map(\.id))
    }

    @Test func rawCourseCaptureBelongsSmokeService() {
        let smoke = ScheduleServiceFactory.make(rawCourseResponseHandler: { _ in })
        #expect(smoke.rawCourseResponseHandler != nil)
        #expect(ScheduleServiceFactory.make().rawCourseResponseHandler == nil)
    }

    @Test(.timeLimit(.minutes(1))) func selectedScoreDomainOwnsAllSyncWrites() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        sync.stores.scoreFilterPreferences.save(
            selectedTerms: ["term"], selectedCourseTypes: [], sortIndex: .score,
            sortOrder: .descending)
        await sync.stores.communityMessages.markSeen(ids: [42], for: .comment)
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(Set(cloud.dictionaryRepresentation.keys) == [key(.scoreCache, account: account)])
        #expect(
            defaults.object(
                forKey:
                    """
                    experimental.preference-cloud-sync.local-envelope.\
                    \(account.session.accountStorageIdentifier).app-settings
                    """
            ) == nil)
        #expect(sync.settings.galleryHiddenUserIDs == [42])
        #expect(sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["term"])
    }

    @Test(.timeLimit(.minutes(1))) func cancelledReconcilePreservesNewAccountQueue() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer {
            cloud.onSet = nil
            defaults.removePersistentDomain(forName: preferenceDomain)
        }
        let nextAccount = Account()
        nextAccount.session = AppStorageSession(accountIdentifier: "preference-account-next")
        defaults.set(
            true,
            forKey:
                """
                experimental.preference-cloud-sync.enabled.\
                \(nextAccount.session.accountStorageIdentifier)
                """
        )
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [73]
        cloud.set(
            try JSONEncoder().encode(
                ExperimentalPreferenceSyncEnvelope(
                    updatedAt: Date(timeIntervalSince1970: 200),
                    payload: AppSettingsSyncPayload(snapshot: snapshot)
                )), forKey: key(.appSettings, account: nextAccount))

        let previousBatchCompletionKey = key(.galleryMessageRead, account: account)
        cloud.onSet = { changedKey in
            guard changedKey == previousBatchCompletionKey else { return }
            cloud.onSet = nil
            account.session = nextAccount.session
            sync.settings.reloadForCurrentAccount()
            sync.reloadForCurrentAccount()
        }

        sync.refreshFromCloudIfNeeded()
        try await cloud.waitForWrite(to: key(.galleryMessageRead, account: nextAccount))
        #expect(account.session == nextAccount.session)
        #expect(sync.settings.galleryHiddenUserIDs == [73])
    }

    @Test(.timeLimit(.minutes(1))) func accountReloadAndUseInjectedIdentity() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        _ = await sync.stores.scoreCache.save(
            rows: [], for: AppStorageSession(accountIdentifier: "stale-account"))
        #expect(cloud.dictionaryRepresentation.isEmpty)
        sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        let firstKey = key(.appSettings, account: account)
        let firstValue = cloud.data(forKey: firstKey)
        let capturedOwner = account.session
        account.session = AppStorageSession(accountIdentifier: "preference-account-other")
        sync.settings.reloadForCurrentAccount()
        sync.reloadForCurrentAccount()
        #expect(sync.isEnabled == false)
        #expect(sync.settings.galleryHiddenUserIDs.isEmpty)
        sync.localValueDidChange(in: .scoreCache, for: capturedOwner)
        let ownerKey =
            """
            experimental.preference-cloud-sync.local-updated.\
            \(capturedOwner.accountStorageIdentifier).score-cache
            """
        #expect(defaults.object(forKey: ownerKey) is Date)
        #expect(
            defaults.dictionary(
                forKey:
                    """
                    experimental.preference-cloud-sync.pending-score.\
                    \(capturedOwner.accountStorageIdentifier)
                    """
            )?["remoteSnapshot"] is Data)
        sync.localValueDidChange(in: .galleryMessageRead, for: capturedOwner)
        #expect(
            defaults.object(
                forKey: ownerKey.replacingOccurrences(
                    of: "score-cache", with: "gallery-message-read")) is Date)
        sync.settings.updateGallerySettings(hiddenUserIDs: [99])
        #expect(cloud.data(forKey: firstKey) == firstValue)
        #expect(cloud.data(forKey: key(.appSettings, account: account)) == nil)
        let restored = AppSettingsStore(defaults: defaults, session: { account.session })
        #expect(restored.galleryHiddenUserIDs == [99])
    }

    @Test func scoreEncryptionSurvivesWritersWriters() throws {
        let first = try #require(UserDefaults(suiteName: preferenceDomain))
        let secondDomain = preferenceDomain + ".keys"
        let second = try #require(UserDefaults(suiteName: secondDomain))
        first.removePersistentDomain(forName: preferenceDomain)
        second.removePersistentDomain(forName: secondDomain)
        defer {
            first.removePersistentDomain(forName: preferenceDomain)
            second.removePersistentDomain(forName: secondDomain)
        }
        let keys = PreferenceMemoryScoreKeys()
        let phone = ScoreCacheSyncEncryption(defaults: first, credentials: keys)
        let mac = ScoreCacheSyncEncryption(defaults: second, credentials: keys)
        let clear = Data("课程名称：功能验收；成绩：95".utf8)
        let phoneRecord = try phone.seal(clear, account: "account")
        let macRecord = try mac.seal(clear, account: "account")
        #expect(ScoreCacheSyncEncryption.isEncrypted(phoneRecord))
        #expect(phoneRecord.range(of: clear) == nil)
        #expect(keys.values.count == 2)
        #expect(try mac.open(phoneRecord, account: "account") == clear)
        #expect(try phone.open(macRecord, account: "account") == clear)
        var damaged = phoneRecord
        damaged[damaged.count - 1] ^= 1
        #expect(throws: (any Error).self) { try mac.open(damaged, account: "account") }
        #expect(throws: (any Error).self) { try mac.open(phoneRecord, account: "other-account") }
        #expect(throws: (any Error).self) {
            try mac.open(Data(phoneRecord.prefix(20)), account: "account")
        }
        keys.allowsDeletion = false
        #expect(phone.removeActiveKey(account: "account") == false)
        #expect(keys.values.count == 2)
        #expect(try mac.open(phoneRecord, account: "account") == clear)
        _ = try phone.seal(clear, account: "account")
        #expect(keys.values.count == 2)
        keys.allowsDeletion = true
        #expect(phone.removeActiveKey(account: "account"))
        #expect(keys.values.count == 1)
        #expect(throws: ScoreSyncEncryptionError.self) {
            try mac.open(phoneRecord, account: "account")
        }
        #expect(try phone.open(macRecord, account: "account") == clear)
    }

}
