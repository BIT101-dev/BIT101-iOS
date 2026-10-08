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

    @Test(arguments: [
        #"<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">"#,
        #"<input id="login-croypto" value='SENSITIVE_VALUE'>"#,
        #"<input name=execution value=SENSITIVE_VALUE>"#,
        #"<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">"#,
        #"<input name="execution" value="SENSITIVE_VALUE"#,
        #"<textarea name="password">SENSITIVE_VALUE</textarea>"#,
        #"<textarea name="password">SENSITIVE_VALUE"#,
        #"{"\u0070assword":"SENSITIVE_VALUE"#,
        #"{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}"#,
        #"{"captcha_payload":["SENSITIVE_VALUE"]}"#,
        #"{"cookie_str":{"value":"SENSITIVE_VALUE"#
    ])
    func forcedRedactionCoversHTMLStructuredJSONAndTruncatedBodies(value: String) {
        let result = ErrorReportRedactor.forced(value)
        #expect(result.contains("SENSITIVE_VALUE") == false)
        #expect(result.contains("TAIL_VALUE") == false)
        #expect(result.contains("[REDACTED]"))
        if value.contains("available") { #expect(result.contains("available")) }
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
        let scoreKeys = PreferenceMemoryScoreKeys()
        var synchronizationSucceeds = true
        var synchronizationCalls = 0
        var onSet: ((String) -> Void)?
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        func data(forKey key: String) -> Data? { dictionaryRepresentation[key] as? Data }
        func set(_ value: Any?, forKey key: String) {
            dictionaryRepresentation[key] = value
            waiters.removeValue(forKey: key)?.resume()
            onSet?(key)
        }
        func synchronize() -> Bool { synchronizationCalls += 1; return synchronizationSucceeds }
        func waitForWrite(to key: String) async {
            if dictionaryRepresentation[key] != nil { return }
            await withCheckedContinuation { waiters[key] = $0 }
        }
    }

    private final class SuspendedScoreCache: ScoreCacheSynchronizing {
        let saves = PassthroughSubject<AppStorageSession, Never>()
        var localSaves: AnyPublisher<AppStorageSession, Never> { saves.eraseToAnyPublisher() }
        var changes: AnyPublisher<AppStorageSession, Never> { Empty().eraseToAnyPublisher() }
        var payload = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])], updatedAt: nil, detailedUpdatedAt: nil)
        var read: CheckedContinuation<ScoreCacheSyncPayload?, Never>?
        var apply: CheckedContinuation<Void, Never>?
        var suspendRead = true
        var suspendApply = false
        var applied = 0
        func syncPayload(for session: AppStorageSession?) async -> ScoreCacheSyncPayload? {
            if suspendRead { suspendRead = false; return await withCheckedContinuation { read = $0 } }
            return payload
        }
        func applySynced(_ remote: ScoreCacheSyncPayload, for session: AppStorageSession?, replacing expected: ScoreCacheSyncPayload?) async -> Bool {
            if suspendApply { suspendApply = false; await withCheckedContinuation { apply = $0 } }
            guard payload == expected else { return false }
            payload = remote; applied += 1; return true
        }
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? { nil }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreReconciliationPreservesSavesDuringReadsAndRemoteApplies(remoteApply: Bool) async throws {
        let cache = SuspendedScoreCache()
        cache.suspendRead = !remoteApply
        cache.suspendApply = remoteApply
        let (sync, defaults, cloud, account) = try context(scoreCache: cache, synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let old = cache.payload
        let recordKey = key(.scoreCache, account: account)
        if remoteApply {
            cloud.set(try ScoreCacheSyncPayloadCodec.encode(ExperimentalPreferenceSyncEnvelope(
                updatedAt: Date(timeIntervalSince1970: 200), payload: old)), forKey: recordKey)
        }
        sync.localValueDidChange(in: .scoreCache)
        if remoteApply {
            // 远端版本高于已记录的本地版本，协调进入挂起的应用阶段。
            cloud.set(try ScoreCacheSyncPayloadCodec.encode(ExperimentalPreferenceSyncEnvelope(
                updatedAt: Date.distantFuture, payload: old)), forKey: recordKey)
        }
        let task = sync.refreshFromCloudIfNeeded()
        while remoteApply ? cache.apply == nil : cache.read == nil { await Task.yield() }
        cache.payload = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(), detailedUpdatedAt: nil)
        cache.saves.send(account.session)
        if remoteApply { cache.apply?.resume() } else { cache.read?.resume(returning: old) }
        await task?.value
        let uploaded = try sync.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(cloud.data(forKey: recordKey)))
        #expect(uploaded.payload == cache.payload)
        #expect(uploaded.payload.rows.first?.values.first?.value == "95")
        #expect(cache.applied == 0)
        let versionKey = "experimental.preference-cloud-sync.local-updated.\(account.session.accountStorageIdentifier).\(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)"
        let recordedVersion = try #require(defaults.object(forKey: versionKey) as? Date)
        #expect(uploaded.updatedAt == recordedVersion)
    }

    private func context(domain: String? = nil, files: PreferenceMemoryFiles = PreferenceMemoryFiles(),
        scoreCache: (any ScoreCacheSynchronizing)? = nil,
        synchronizedDomains: Set<ExperimentalPreferenceSyncDomain> = Set(ExperimentalPreferenceSyncDomain.allCases)) throws -> (ExperimentalPreferenceCloudSync, UserDefaults, MemoryCloud, Account) {
        let domain = domain ?? preferenceDomain
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let account = Account()
        let center = NotificationCenter()
        let root = URL(fileURLWithPath: "/preference-sync")
        let settings = AppSettingsStore(defaults: defaults, session: { account.session })
        let stores = AppAccountStores(
            communityMessages: GalleryMessageReadStore(defaults: defaults, session: { account.session }),
            composerDrafts: ComposerDraftStore(files: files, applicationSupport: root, session: { account.session }, prepareImageData: ComposerDraftImageCompressor.compress),
            scoreCache: scoreCache ?? ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { account.session }),
            scoreFilterPreferences: ScoreFilterPreferenceStore(defaults: defaults, session: { account.session }),
            currentSession: { account.session }, scoreSession: { account.session }
        )
        defaults.set(true, forKey: "experimental.preference-cloud-sync.enabled.\(account.session.accountStorageIdentifier)")
        let cloud = MemoryCloud()
        let sync = ExperimentalPreferenceCloudSync(
            settings: settings, stores: stores, defaults: defaults, cloudStore: cloud,
            scoreEncryption: ScoreCacheSyncEncryption(defaults: defaults, credentials: cloud.scoreKeys),
            synchronizedDomains: synchronizedDomains, notificationCenter: center
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
        let transcriptServiceIdentity: AnyHashable = UUID()
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

    @Test(.timeLimit(.minutes(1))) func lifecycleRestoresEnabledPreferencesAtLaunchAndForeground() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.appSettings])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let owner = lifecycle(sync: sync, account: account, displays: ExternalDisplays())
        let recordKey = key(.appSettings, account: account)
        owner.start()
        #expect(cloud.synchronizationCalls == 1)
        await cloud.waitForWrite(to: recordKey)
        #expect(cloud.data(forKey: recordKey) != nil)
        cloud.set(nil, forKey: recordKey)
        let foregroundCalls = cloud.synchronizationCalls
        owner.sceneBecameActive()
        #expect(cloud.synchronizationCalls == foregroundCalls + 1)
        await cloud.waitForWrite(to: recordKey)
        #expect(cloud.data(forKey: recordKey) != nil)
        sync.setEnabled(false)
        let calls = cloud.synchronizationCalls
        owner.sceneBecameActive()
        #expect(cloud.synchronizationCalls == calls)
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
            defaults: defaults, cloudStore: secondCloud,
            scoreEncryption: ScoreCacheSyncEncryption(defaults: defaults, credentials: secondCloud.scoreKeys),
            notificationCenter: NotificationCenter())
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
        _ = try #require(await sync.stores.scoreCache.save(rows: rows, for: nil))
        await cloud.waitForWrite(to: key(.scoreCache, account: account))
        let scores = try sync.decodeScoreCloudEnvelope(
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

    @Test(.timeLimit(.minutes(1))) func disablingSyncDuringScoreReadKeepsTheCloudRecordUnchanged() async throws {
        let files = PreferenceMemoryFiles()
        let (sync, defaults, cloud, account) = try context(files: files)
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let rows = [ScoreRow(index: 0, headers: ["课程名称", "成绩"], values: ["课程", "95"])]
        _ = try #require(await sync.stores.scoreCache.save(rows: rows, for: nil))
        await sync.refreshFromCloudIfNeeded()?.value
        let recordKey = key(.scoreCache, account: account)
        let original = try #require(cloud.data(forKey: recordKey))
        let release = DispatchSemaphore(value: 0)
        var task: Task<Void, Never>?
        await withCheckedContinuation { started in
            files.interceptNextRead { started.resume(); release.wait() }
            sync.localValueDidChange(in: .scoreCache)
            task = sync.refreshFromCloudIfNeeded()
        }
        sync.setEnabled(false)
        release.signal()
        await task?.value
        #expect(cloud.data(forKey: recordKey) == original)
        #expect(sync.isEnabled == false)
        sync.setEnabled(true)
        await sync.refreshFromCloudIfNeeded()?.value
        let restored = try sync.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: #require(cloud.data(forKey: recordKey)))
        #expect(restored.payload.rows.map(\.id) == rows.map(\.id))
    }

    @Test func rawCourseCaptureBelongsToTheSelectedSmokeService() {
        let smoke = ScheduleServiceFactory.make(rawCourseResponseHandler: { _ in })
        #expect(smoke.rawCourseResponseHandler != nil)
        #expect(ScheduleServiceFactory.make().rawCourseResponseHandler == nil)
    }

    @Test func selectedScoreDomainOwnsAllSyncWritesAndKeepsOtherPreferencesLocal() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        sync.settings.updateGallerySettings(hiddenUserIDs: [42])
        sync.stores.scoreFilterPreferences.save(selectedTerms: ["term"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .descending)
        sync.stores.communityMessages.markSeen(ids: [42], for: .comment)
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(Set(cloud.dictionaryRepresentation.keys) == [key(.scoreCache, account: account)])
        #expect(defaults.object(forKey: "experimental.preference-cloud-sync.local-envelope.\(account.session.accountStorageIdentifier).app-settings") == nil)
        #expect(sync.settings.galleryHiddenUserIDs == [42])
        #expect(sync.stores.scoreFilterPreferences.load()?.selectedTerms == ["term"])
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

    @Test func scoreEncryptionAuthenticatesAccountAndSurvivesIndependentWriters() throws {
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
        #expect(throws: (any Error).self) { try mac.open(Data(phoneRecord.prefix(20)), account: "account") }
        keys.allowsDeletion = false
        #expect(phone.removeActiveKey(account: "account") == false)
        #expect(keys.values.count == 2)
        #expect(try mac.open(phoneRecord, account: "account") == clear)
        _ = try phone.seal(clear, account: "account")
        #expect(keys.values.count == 2)
        keys.allowsDeletion = true
        #expect(phone.removeActiveKey(account: "account"))
        #expect(keys.values.count == 1)
        #expect(throws: ScoreSyncEncryptionError.self) { try mac.open(phoneRecord, account: "account") }
        #expect(try phone.open(macRecord, account: "account") == clear)
    }

    @Test func authoritativeEmptyScoreQueryClearsTheReceivingStoreAndAdvancesItsCloudVersion() async throws {
        let senderDomain = preferenceDomain + ".sender"
        let (sender, senderDefaults, senderCloud, senderAccount) = try context(domain: senderDomain, synchronizedDomains: [.scoreCache])
        let (receiver, receiverDefaults, receiverCloud, receiverAccount) = try context(synchronizedDomains: [.scoreCache])
        defer {
            senderDefaults.removePersistentDomain(forName: senderDomain)
            receiverDefaults.removePersistentDomain(forName: preferenceDomain)
        }
        let old = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(await receiver.stores.scoreCache.applySynced(old, for: nil, replacing: nil))
        await receiver.refreshFromCloudIfNeeded()?.value
        await sender.refreshFromCloudIfNeeded()?.value
        #expect(await sender.stores.scoreCache.saveDetailed(rows: [], for: nil) != nil)
        await sender.refreshFromCloudIfNeeded()?.value
        let payload = try #require(await sender.stores.scoreCache.syncPayload(for: nil))
        #expect(payload.rows.isEmpty && payload.updatedAt != nil && payload.detailedUpdatedAt != nil)
        let encrypted = try #require(senderCloud.data(forKey: key(.scoreCache, account: senderAccount)))
        #expect(ScoreCacheSyncEncryption.isEncrypted(encrypted))
        receiverCloud.scoreKeys.values = senderCloud.scoreKeys.values
        receiverCloud.set(encrypted, forKey: key(.scoreCache, account: receiverAccount))
        await receiver.refreshFromCloudIfNeeded()?.value
        #expect(await receiver.stores.scoreCache.syncPayload(for: nil) == payload)
        let envelope = try sender.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self, from: encrypted)
        let versionKey = "experimental.preference-cloud-sync.local-updated.\(receiverAccount.session.accountStorageIdentifier).\(ExperimentalPreferenceSyncDomain.scoreCache.rawValue)"
        #expect(receiverDefaults.object(forKey: versionKey) as? Date == envelope.updatedAt)
        await receiver.refreshFromCloudIfNeeded()?.value
        #expect(await receiver.stores.scoreCache.syncPayload(for: nil) == payload)
    }

    @Test func plaintextScoreMigrationAndDelayedKeyKeepPayloadReadable() async throws {
        let (sync, defaults, cloud, account) = try context(synchronizedDomains: [.scoreCache])
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let recordKey = key(.scoreCache, account: account)
        let payload = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        let clear = try ScoreCacheSyncPayloadCodec.encode(ExperimentalPreferenceSyncEnvelope(
            updatedAt: Date(timeIntervalSince1970: 200), payload: payload))
        cloud.set(clear, forKey: recordKey)
        await sync.refreshFromCloudIfNeeded()?.value
        let encrypted = try #require(cloud.data(forKey: recordKey))
        #expect(ScoreCacheSyncEncryption.isEncrypted(encrypted))
        #expect(await sync.stores.scoreCache.syncPayload(for: nil) == payload)
        let savedKeys = cloud.scoreKeys.values
        cloud.scoreKeys.values = [:]
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue?.contains("钥匙串") == true)
        #expect(cloud.data(forKey: recordKey) == encrypted)
        #expect(await sync.stores.scoreCache.syncPayload(for: nil) == payload)
        cloud.scoreKeys.values = savedKeys
        await sync.refreshFromCloudIfNeeded()?.value
        #expect(sync.syncIssue == nil)
        #expect(try sync.decodeScoreCloudEnvelope(ExperimentalPreferenceSyncEnvelope<ScoreCacheSyncPayload>.self,
            from: encrypted).payload == payload)
    }

    @Test func failedCloudSynchronizationRetainsLocalChangesAndReportsUntilRetry() async throws {
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
