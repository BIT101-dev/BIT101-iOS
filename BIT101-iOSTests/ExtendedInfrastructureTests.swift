import CommunityPersistence
import Combine
import ClientCore
import ScoreDomain
@testable import ScoreInfrastructure
import CommunityTransport
@testable import GalleryFeature
@testable import CommunityUI
@testable import MediaKit
import StorageCore
import Foundation
import Testing
@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import TransportCore
import ScheduleDomain
#if EXTENDED_AUTOMATION

@Suite("Extended infrastructure contracts")
struct ExtendedInfrastructureTests {
    @Test("Forced redaction handles nested credentials")
    func nestedCredentialRedaction() {
        let value = #"{"profile":{"name":"张三"},"auth":{"password":"secret","access_token":"abc"}}"#
        let result = ErrorReportRedactor.forced(value)

        #expect(result.contains("张三"))
        #expect(!result.contains("secret"))
        #expect(!result.contains("abc"))
        #expect(result.contains("[REDACTED]"))
    }

    @Test("Sanitized redaction hides numeric student identifiers")
    func numericIdentifierRedaction() {
        let result = ErrorReportRedactor.sanitized("student_id=1120260001&status=401")

        #expect(!result.contains("1120260001"))
        #expect(result.contains("401"))
    }

    @Test("Cancellation detection recognizes wrapped URL errors")
    func wrappedCancellation() {
        let wrapped = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]
        )

        #expect(TaskCancellation.matches(wrapped))
    }

    @Test("Host resolution detection recognizes nested DNS errors")
    func nestedHostResolution() {
        let wrapped = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)]
        )

        #expect(isHostResolutionError(wrapped))
    }

    @Test("Non-DNS network errors are not reported as host resolution")
    func nonDNSError() {
        #expect(!isHostResolutionError(URLError(.timedOut)))
        #expect(!isHostResolutionError(URLError(.notConnectedToInternet)))
    }

    @Test("HTTPS upgrade preserves path query and fragment")
    func httpsUpgradePreservesComponents() throws {
        let source = try #require(URL(string: "http://example.com/a/b?q=1#fragment"))
        let upgraded = HTTPSURLUpgrade.upgradedURL(from: source)

        #expect(upgraded.absoluteString == "https://example.com/a/b?q=1#fragment")
    }

    @Test("Time slots clamp negative formatting values")
    func timeSlotFormatting() {
        #expect(TimeSlot.parseMinutes("08:30") == 510)
        #expect(TimeSlot.formatMinutes(-1) == "00:00")
        #expect(TimeSlot.formatMinutes(510) == "08:30")
    }

    @Test("DDL editor toggles completion and preserves missing ID")
    func ddlCompletionState() {
        let event = DDLEventRecord(
            id: "event",
            group: "main",
            title: "任务",
            text: "说明",
            dueAt: Date(timeIntervalSince1970: 100),
            done: false
        )

        let toggled = ScheduleDDLEditor.togglingDone(id: event.id, in: [event])
        #expect(toggled.first?.done == true)
        #expect(ScheduleDDLEditor.togglingDone(id: "missing", in: toggled) == toggled)
    }
}
#endif

@MainActor
@Suite("Experimental preference iCloud sync", .serialized)
struct ExperimentalPreferenceCloudSyncTests {
    private let preferenceDomain = "BIT101Tests.preference-sync"

    private final class Account {
        var session = AppStorageSession(accountIdentifier: "preference-account") {
            didSet { generation &+= 1; changes.send(identity) }
        }
        private var generation = 0
        let changes = PassthroughSubject<CommunitySessionIdentity, Never>()
        var identity: CommunitySessionIdentity { .init(accountIdentifier: session.accountIdentifier, generation: generation) }
    }

    private final class MemoryCloud: PreferenceCloudStoring {
        var dictionaryRepresentation: [String: Any] = [:]
        var onSet: ((String) -> Void)?
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
        func set(_ value: Any?, forKey key: String) {
            dictionaryRepresentation[key] = value
            waiters.removeValue(forKey: key)?.resume()
            onSet?(key)
        }
        func synchronize() -> Bool { true }
        func waitForWrite(to key: String) async {
            if dictionaryRepresentation[key] != nil { return }
            await withCheckedContinuation { waiters[key] = $0 }
        }
    }

    private func context(domain: String? = nil) throws -> (ExperimentalPreferenceCloudSync, UserDefaults, MemoryCloud, Account) {
        let domain = domain ?? preferenceDomain
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let account = Account()
        let center = NotificationCenter()
        let files = PreferenceMemoryFiles()
        let root = URL(fileURLWithPath: "/preference-sync")
        let settings = AppSettingsStore(defaults: defaults, session: { account.session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(defaults: defaults, session: { account.session }),
            composerDrafts: ComposerDraftStore(files: files, applicationSupport: root, session: { account.session }, prepareImageData: ComposerDraftImageCompressor.compress),
            scoreCache: ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { account.session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: defaults, session: { account.session }),
            currentSession: { account.session }, scoreSession: { account.session }
        )
        defaults.set(true, forKey: "experimental.preference-cloud-sync.enabled.\(account.session.accountStorageIdentifier)")
        let cloud = MemoryCloud()
        let sync = ExperimentalPreferenceCloudSync(
            settings: settings, stores: stores, defaults: defaults, cloudStore: cloud, notificationCenter: center
        )
        return (sync, defaults, cloud, account)
    }

    private final class ExternalDisplays: AppExternalDisplayCoordinating {
        var activationCount = 0
        var resetCount = 0
        var refreshes: [(String, AppStorageSession)] = []
        private var waiter: CheckedContinuation<Void, Never>?
        private var expectedCount = 0
        func activate() { activationCount += 1 }
        func resetAccountPresentation() { resetCount += 1 }
        func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async {
            #expect(syncWidgetSnapshot)
            refreshes.append((trigger, session))
            if refreshes.count >= expectedCount { waiter?.resume(); waiter = nil }
        }
        func waitForRefreshes(_ count: Int) async {
            if refreshes.count >= count { return }
            expectedCount = count
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private func lifecycle(sync: ExperimentalPreferenceCloudSync, account: Account, displays: ExternalDisplays, changes: AnyPublisher<AppStorageSession, Never> = Empty().eraseToAnyPublisher(), loadCourses: @escaping @MainActor (AppStorageSession) async -> [String: [ScoreCourseSummary]] = { _ in [:] }) -> AppAccountLifecycle {
        let repository = ScheduleRepository(session: { account.session }, load: { _ in .missing }, save: { _, _, _ in })
        let service = SemesterStartDateService()
        let schedule = ScheduleViewModel(service: service, repository: repository, ddlService: service, classroomService: service, platformActions: RecordingSchedulePlatformActions(), newCustomScheduleDraft: { CustomScheduleDraft() })
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        let media = MediaEnvironment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), defaults: UserDefaults.standard,
            imageHTTPClient: client, avatarHTTPClient: client)
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://example.invalid"),
            credentials: { CommunityCredentials(identity: .init(accountIdentifier: account.session.accountIdentifier), cookie: "fixture") }, refresh: { _ in })
        let community = AppCommunityDependencies(settings: sync.settings, session: session, checkLogin: { true },
            messages: sync.stores.communityMessages, drafts: sync.stores.composerDrafts, submitSuggestion: { _ in }, loadCourseCredits: { [] })
        return AppAccountLifecycle(scheduleViewModel: schedule, community: community, scoreService: OfflineScoreService(),
            transcriptService: OfflineScoreService(), settings: sync.settings, stores: sync.stores, preferenceCloudSync: sync, accountChanges: account.changes.eraseToAnyPublisher(), currentIdentity: { account.identity },
            scheduleChanges: changes, loadScheduleCourses: loadCourses, media: media,
            localData: AppLocalDataService(files: PreferenceMemoryFiles(), actions: LocalDataActionsSpy().actions), externalDisplays: displays)
    }

    private struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    }
    private struct OfflineScoreService: ScoreListServicing, TrustedTranscriptServicing {
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
        func fetchTrustedTranscriptPages() async throws -> [Data] { [] }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { [] }
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleForwardsItsSelectedCourseSourceToScores() async throws {
        let (sync, defaults, _, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let changes = PassthroughSubject<AppStorageSession, Never>()
        let displays = ExternalDisplays()
        var loadedSessions: [AppStorageSession] = []
        var waiter: CheckedContinuation<Void, Never>?
        let owner = lifecycle(sync: sync, account: account, displays: displays,
            changes: changes.eraseToAnyPublisher(), loadCourses: { session in
                loadedSessions.append(session)
                waiter?.resume(); waiter = nil
                return [:]
            })
        changes.send(AppStorageSession(accountIdentifier: "other"))
        changes.send(account.session)
        if loadedSessions.isEmpty { await withCheckedContinuation { waiter = $0 } }
        #expect(loadedSessions == [account.session])
        #expect(owner.communityDestinations.settingsDependencies.media === owner.communityDestinations.media)
        withExtendedLifetime(owner) {}
    }

    @Test func lifecycleInstancesOwnTheirAccountEventsSettingsAndPlatformEffects() async throws {
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
        let first = lifecycle(sync: firstSync, account: firstAccount, displays: firstDisplays, changes: changes.eraseToAnyPublisher())
        let second = lifecycle(sync: secondSync, account: secondAccount, displays: secondDisplays)
        first.start()
        second.start()
        await firstDisplays.waitForRefreshes(1)
        await secondDisplays.waitForRefreshes(1)
        #expect(first.settings === firstSync.settings)
        #expect(second.settings === secondSync.settings)
        #expect(firstDisplays.activationCount == 1)
        #expect(secondDisplays.activationCount == 1)
        first.settings.updateGallerySettings(useWebView: true)
        #expect(first.community.preferences.galleryUseWebView)
        #expect(second.community.preferences.galleryUseWebView == false)
        firstAccount.session = AppStorageSession(accountIdentifier: "changed-account")
        await firstDisplays.waitForRefreshes(2)
        #expect(firstDisplays.resetCount == 1)
        firstAccount.changes.send(.init(accountIdentifier: "stale", generation: 0))
        #expect(firstDisplays.resetCount == 1)
        #expect(secondDisplays.resetCount == 0)
        #expect(firstDisplays.refreshes.last?.1 == firstAccount.session)
        #expect(secondDisplays.refreshes.count == 1)
        changes.send(firstAccount.session)
        await firstDisplays.waitForRefreshes(3)
        #expect(firstDisplays.refreshes.last?.0 == "schedule_cache_changed")
        #expect(secondDisplays.refreshes.count == 1)
    }

    private func key(_ domain: ExperimentalPreferenceSyncDomain, account: Account) -> String {
        "preference-sync.v2.\(account.session.accountDirectoryName).\(domain.rawValue)"
    }

    @Test(.timeLimit(.minutes(1))) func guestPreferenceSwitchAndRevisionSurviveReload() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        account.session = AppStorageSession(accountIdentifier: "")
        sync.reloadForCurrentAccount()
        sync.setEnabled(true)
        sync.localValueDidChange(in: .appSettings)
        let recordKey = key(.appSettings, account: account)
        let envelopeType = ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self
        let revision = try JSONDecoder().decode(envelopeType, from: #require(cloud.data(forKey: recordKey))).updatedAt
        cloud.set(nil, forKey: recordKey)

        sync.reloadForCurrentAccount()
        await cloud.waitForWrite(to: recordKey)

        #expect(sync.isEnabled)
        let restored = try JSONDecoder().decode(envelopeType, from: #require(cloud.data(forKey: recordKey)))
        #expect(restored.updatedAt == revision)
        sync.setEnabled(false)
        sync.reloadForCurrentAccount()
        #expect(sync.isEnabled == false)
    }

    @Test func sharedStoreSaveEventsReachEveryActiveCoordinator() async throws {
        let (first, defaults, firstCloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let secondCloud = MemoryCloud()
        let second = ExperimentalPreferenceCloudSync(settings: first.settings, stores: first.stores,
            defaults: defaults, cloudStore: secondCloud, notificationCenter: NotificationCenter())
        first.settings.updateGallerySettings(hiddenUserIDs: [42])
        let recordKey = key(.appSettings, account: account)
        #expect(firstCloud.data(forKey: recordKey) != nil)
        #expect(secondCloud.data(forKey: recordKey) != nil)
        withExtendedLifetime(second) {}
    }

    @Test func localCallbacksUploadInjectedSettingsAndStores() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        sync.settings.updateGallerySettings(hideBotPosterInSearch: false, hiddenUserIDs: [42], useWebView: true)
        let settings = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<AppSettingsSyncPayload>.self,
            from: try #require(cloud.data(forKey: key(.appSettings, account: account)))
        )
        #expect(settings.payload.galleryHiddenUserIDs == [42])
        #expect(settings.payload.galleryHideBotPosterInSearch == false)
        #expect(settings.payload.galleryUseWebView)
        sync.stores.scoreFilterPreferences.save(selectedTerms: ["2026-2027-1"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        let filters = try JSONDecoder().decode(
            ExperimentalPreferenceSyncEnvelope<ScoreFilterPreferenceSnapshot>.self,
            from: try #require(cloud.data(forKey: key(.scoreFilters, account: account)))
        )
        #expect(filters.payload.selectedTerms == ["2026-2027-1"])
        sync.stores.communityMessages.markSeen(ids: [42], for: .comment)
        #expect(cloud.data(forKey: key(.galleryMessageRead, account: account)) != nil)
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["注入课程", "95"])]
        _ = try #require(await sync.stores.scoreCache.save(rows: rows))
        await cloud.waitForWrite(to: key(.scoreCache, account: account))
        let scores = try ScoreCacheSyncPayloadCodec.decode(
            ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: try #require(cloud.data(forKey: key(.scoreCache, account: account)))
        )
        #expect(scores.payload.rows.map(\.id) == rows.map(\.id))
        #expect(scores.payload.rows.map { $0.values.map(\.key) } == rows.map { $0.values.map(\.key) })
        #expect(scores.payload.rows.map { $0.values.map(\.value) } == rows.map { $0.values.map(\.value) })
    }

    @Test func remoteSettingsApplyToTheInjectedInstance() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [73]
        snapshot.galleryHideAnonymousContent = true
        cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(
            updatedAt: Date(timeIntervalSince1970: 200), payload: AppSettingsSyncPayload(snapshot: snapshot)
        )), forKey: key(.appSettings, account: account))
        sync.refreshFromCloudIfNeeded()
        await cloud.waitForWrite(to: key(.galleryMessageRead, account: account))
        #expect(sync.settings.galleryHiddenUserIDs == [73])
        #expect(sync.settings.galleryHideAnonymousContent)
        let restored = AppSettingsStore(defaults: defaults, session: { account.session })
        #expect(restored.galleryHiddenUserIDs == [73])
    }

    @Test(.timeLimit(.minutes(1))) func cancelledReconciliationPreservesTheNewAccountQueue() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer {
            cloud.onSet = nil
            defaults.removePersistentDomain(forName: preferenceDomain)
        }
        let nextAccount = Account()
        nextAccount.session = AppStorageSession(accountIdentifier: "preference-account-next")
        defaults.set(true, forKey: "experimental.preference-cloud-sync.enabled.\(nextAccount.session.accountStorageIdentifier)")
        var snapshot = AppSettingsSnapshot()
        snapshot.galleryHiddenUserIDs = [73]
        cloud.set(try JSONEncoder().encode(ExperimentalPreferenceSyncEnvelope(
            updatedAt: Date(timeIntervalSince1970: 200), payload: AppSettingsSyncPayload(snapshot: snapshot)
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
        await cloud.waitForWrite(to: key(.galleryMessageRead, account: nextAccount))
        #expect(account.session == nextAccount.session)
        #expect(sync.settings.galleryHiddenUserIDs == [73])
    }

    @Test func accountReloadAndStaleScoreCallbacksUseInjectedIdentity() async throws {
        let (sync, defaults, cloud, account) = try context()
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        _ = await sync.stores.scoreCache.save(rows: [], for: AppStorageSession(accountIdentifier: "stale-account"))
        #expect(cloud.dictionaryRepresentation.isEmpty)
        sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        let firstKey = key(.appSettings, account: account)
        let firstValue = cloud.data(forKey: firstKey)
        account.session = AppStorageSession(accountIdentifier: "preference-account-other")
        sync.settings.reloadForCurrentAccount()
        sync.reloadForCurrentAccount()
        #expect(sync.isEnabled == false)
        #expect(sync.settings.galleryHiddenUserIDs.isEmpty)
        sync.settings.updateGallerySettings(hiddenUserIDs: [99])
        #expect(cloud.data(forKey: firstKey) == firstValue)
        #expect(cloud.data(forKey: key(.appSettings, account: account)) == nil)
        let restored = AppSettingsStore(defaults: defaults, session: { account.session })
        #expect(restored.galleryHiddenUserIDs == [99])
    }

    @Test("Independent domain timestamps choose the newest value")
    func reconciliationPolicy() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)

        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: nil, remoteUpdatedAt: nil) == .noChange)
        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: nil, remoteUpdatedAt: new) == .applyRemote)
        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: nil) == .uploadLocal)
        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: old, remoteUpdatedAt: new) == .applyRemote)
        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: old) == .uploadLocal)
        #expect(ExperimentalPreferenceSyncPolicy.decision(localUpdatedAt: new, remoteUpdatedAt: new) == .noChange)
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

        #expect(ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: 64,
            existingValueBytes: maximum - 64,
            existingKeyCount: 1_023,
            replacingExistingKey: false,
            keyUTF16Count: 128
        ))
        #expect(!ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: maximum + 1,
            existingValueBytes: 0,
            existingKeyCount: 0,
            replacingExistingKey: false,
            keyUTF16Count: 1
        ))
        #expect(!ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: 2,
            existingValueBytes: maximum - 1,
            existingKeyCount: 0,
            replacingExistingKey: false,
            keyUTF16Count: 1
        ))
        #expect(!ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: 1,
            existingValueBytes: 0,
            existingKeyCount: 1_024,
            replacingExistingKey: false,
            keyUTF16Count: 1
        ))
        #expect(ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: 1,
            existingValueBytes: 0,
            existingKeyCount: 1_024,
            replacingExistingKey: true,
            keyUTF16Count: 1
        ))
        #expect(!ExperimentalPreferenceCloudQuotaPolicy.canStore(
            valueSize: 1,
            existingValueBytes: 0,
            existingKeyCount: 0,
            replacingExistingKey: false,
            keyUTF16Count: 129
        ))
    }
}

@MainActor
struct AppExternalDisplayTests {
    private final class Context {
        var session = AppStorageSession(accountIdentifier: "selected-display")
        var signedIn = true
        var events: [String] = []
        var exportAction: (() async -> Void)?
        let refreshDate = Date(timeIntervalSince1970: 100)

        func adapter() -> AppExternalDisplayCoordinator {
            AppExternalDisplayCoordinator(currentSession: { self.session }, isSignedIn: { self.signedIn },
                activateWatch: { self.events.append("activate") }, resetPresentation: { self.events.append("reset") },
                exportWidget: { self.events.append("widget"); await self.exportAction?() },
                nextReminderRefresh: { self.events.append("next"); return self.refreshDate },
                scheduleBackgroundRefresh: { self.events.append($0 == self.refreshDate ? "schedule" : "clear") },
                endActivities: { self.events.append("end") }, refreshActivities: { self.events.append($0) })
        }
    }

    @Test func selectedCapabilitiesOwnSignedInAndSignedOutRefreshes() async {
        let context = Context()
        let adapter = context.adapter()
        adapter.activate()
        adapter.resetAccountPresentation()
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: context.session)
        #expect(context.events == ["activate", "reset", "widget", "next", "schedule", "refresh"])
        context.events = []
        context.signedIn = false
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: false, session: context.session)
        #expect(context.events == ["clear", "end"])
    }

    @Test func suspendedRefreshChecksAccountAndCancellationBeforeSystemEffects() async {
        for cancel in [false, true] {
            let context = Context()
            var resume: CheckedContinuation<Void, Never>?
            var started: CheckedContinuation<Void, Never>?
            context.exportAction = {
                await withCheckedContinuation {
                    resume = $0
                    started?.resume()
                    started = nil
                }
            }
            let adapter = context.adapter()
            let owner = context.session
            let task = Task { await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: owner) }
            if resume == nil { await withCheckedContinuation { started = $0 } }
            if cancel { task.cancel() } else { context.session = AppStorageSession(accountIdentifier: "changed") }
            resume?.resume()
            await task.value
            #expect(context.events == ["widget"])
        }
    }
}
