import CommunityPersistence
import CommunityCore
import CommunityUI
import ScheduleDomain
import ScheduleFeature
import CommunityTransport
import MediaKit
import TransportCore
import Foundation
import Combine
import GalleryFeature
import StorageCore
import ScorePorts
import ClientCore
import Testing
@testable import BIT101_iOS

@MainActor
struct SuggestionDependencyTests {
    @MainActor
    private final class SuggestionDraftPort: DeveloperSuggestionDraftStoring {
        var cleanups = 0
        func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool { true }
        func loadSuggestion() async -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> { .missing }
        func removeSuggestion() async { cleanups += 1 }
        func captureSuggestionCleanup() async -> ComposerDraftCleanup {
            { await self.removeSuggestion() }
        }
    }

    private final class Account {
        var session = AppStorageSession(accountIdentifier: "A")
    }
    private func store(_ files: PreferenceMemoryFiles) -> ComposerDraftStore {
        ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                           session: { AppStorageSession(accountIdentifier: "suggestion-test") }, prepareImageData: ComposerDraftImageCompressor.compress)
    }

    private func payload(comment: String = "injected suggestion") -> DeveloperSuggestionPayload {
        let context = FeedbackDeviceContext.current
        return DeveloperSuggestionPayload(comment: comment, contact: "fixture", appVersion: "test", build: "test",
            systemVersion: "test", deviceModel: "test", networkStatus: context.networkStatus,
            submittedAt: Date(timeIntervalSince1970: 0), context: context, attachments: [])
    }

    @Test func suggestionPageAcceptsAnIndependentDraftPort() async throws {
        let drafts = SuggestionDraftPort()
        var delivered: [String] = []
        let page = DeveloperSuggestionPage(dependencies: .init(drafts: drafts, submit: { delivered.append($0.comment) }))
        try await page.dependencies.submitAndClear(payload())
        #expect(delivered == ["injected suggestion"])
        #expect(drafts.cleanups == 1)
    }

    @Test func successfulSubmissionUsesTheChosenDraftAndDeliveryOwner() async throws {
        let first = store(PreferenceMemoryFiles())
        let second = store(PreferenceMemoryFiles())
        #expect(await first.saveSuggestion(.init(text: "first draft", images: [])))
        #expect(await second.saveSuggestion(.init(text: "second draft", images: [])))
        var delivered: [String] = []
        let dependencies = DeveloperSuggestionDependencies(drafts: first, submit: { delivered.append($0.comment) })
        let page = DeveloperSuggestionPage(dependencies: dependencies)
        #expect(await page.dependencies.drafts.loadSuggestion().snapshot?.text == "first draft")
        try await page.dependencies.submitAndClear(payload())
        #expect(delivered == ["injected suggestion"])
        #expect(await first.loadSuggestion().snapshot == nil)
        #expect(await second.loadSuggestion().snapshot?.text == "second draft")
    }

    @Test func deliveryFailurePreservesTheOwnedDraft() async {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "retained draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await dependencies.submitAndClear(payload()) }
        #expect(await drafts.loadSuggestion().snapshot?.text == "retained draft")
    }
    @Test func lostResponsesKeepTheSuggestionIdentityAndSuccessReleasesTheAttempt() async throws {
        let drafts = SuggestionDraftPort()
        var delivered: [DeveloperSuggestionPayload] = []
        var fails = true
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: {
            delivered.append($0)
            if fails { throw URLError(.timedOut) }
        })
        let attempt = FeedbackSubmissionAttempt<DeveloperSuggestionPayload>()
        func submit(_ candidate: DeveloperSuggestionPayload) async throws {
            let prepared = attempt.prepare(candidate)
            try await dependencies.submitAndClear(prepared)
            attempt.finish(prepared)
        }
        for _ in 0..<2 { await #expect(throws: URLError.self) { try await submit(payload()) } }
        #expect(delivered[0].requestID == delivered[1].requestID && drafts.cleanups == 0)
        fails = false
        try await submit(payload())
        #expect(delivered[2].requestID == delivered[0].requestID && drafts.cleanups == 1)
        try await submit(payload())
        #expect(delivered[3].requestID != delivered[2].requestID)
        fails = true
        await #expect(throws: URLError.self) { try await submit(payload(comment: "edited")) }
        #expect(delivered[4].requestID != delivered[3].requestID && delivered[4].comment == "edited")
    }
    @Test func delayedSubmissionCleanupStaysWithTheCapturedAccount() async throws {
        let account = Account()
        let drafts = ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"), session: { account.session }, prepareImageData: ComposerDraftImageCompressor.compress)
        #expect(await drafts.saveSuggestion(.init(text: "A draft", images: [])))
        account.session = AppStorageSession(accountIdentifier: "B")
        #expect(await drafts.saveSuggestion(.init(text: "B draft", images: [])))
        account.session = AppStorageSession(accountIdentifier: "A")
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            account.session = AppStorageSession(accountIdentifier: "B")
        })
        try await dependencies.submitAndClear(payload())
        #expect(await drafts.loadSuggestion().snapshot?.text == "B draft")
        account.session = AppStorageSession(accountIdentifier: "A")
        #expect(await drafts.loadSuggestion().snapshot == nil)
    }

    @Test func aFreshDraftRevisionSurvivesAnEarlierSubmissionCleanup() async throws {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "submitted draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            #expect(await drafts.saveSuggestion(.init(text: "continued edit", images: [])))
        })
        try await dependencies.submitAndClear(payload())
        #expect(await drafts.loadSuggestion().snapshot?.text == "continued edit")
    }

}

@MainActor
final class LocalDataActionsSpy {
    var events: [String] = []
    var succeeds = true
    var hasPendingRecovery: () -> Bool = { false }
    var suspendedAction: String?
    var pending: CheckedContinuation<Void, Never>?
    var mediaCleanup: (() async -> Bool)?
    private func record(_ action: String) async {
        events.append(action)
        if suspendedAction == action { await withCheckedContinuation { pending = $0 } }
    }
    var actions: AppLocalDataActions {
        AppLocalDataActions(
            hasPendingRecovery: { self.hasPendingRecovery() },
            clearLogin: { self.events.append("login"); return self.succeeds },
            suspendStorageOperations: { await self.record("storage") },
            resumeStorageOperations: { self.events.append("storage-resume") },
            clearSchedule: { await self.record("schedule"); return self.succeeds },
            clearSharedSnapshot: { await self.record("shared"); return self.succeeds },
            clearReports: { self.events.append("reports"); return self.succeeds },
            clearDiagnostics: { await self.record("diagnostics") },
            clearPreferences: { self.events.append("preferences") },
            clearURLCache: { self.events.append("url-cache") },
            clearWebData: { await self.record("web-data") },
            clearMedia: { await self.record("media"); return await self.mediaCleanup?() ?? self.succeeds },
            resetSettings: { self.events.append("settings") }
        )
    }
}

@MainActor
struct AppLocalDataOwnershipTests {
    @Test(arguments: [false, true]) func pendingOnlineRecoveryProtectsCredentialsAndJournalBeforeReset(legacy: Bool) async throws {
        let selected = LocalDataActionsSpy(), files = PreferenceMemoryFiles()
        let journal = Data("pending recovery".utf8)
        let directory = files.temporaryDirectoryURL.appendingPathComponent("NetworkSmoke", isDirectory: true)
        let url = directory.appendingPathComponent(ReleaseNetworkSmokeReportStore.communityJournalFileName)
        if !legacy { try files.createDirectory(at: directory); try files.writeData(journal, to: url, options: [.atomic]) }
        var legacyData: Data? = legacy ? journal : nil
        selected.hasPendingRecovery = { ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites(files: files, directory: directory, legacyData: legacyData) }
        let service = AppLocalDataService(files: files, actions: selected.actions)
        #expect(await service.resetAllLocalData { Issue.record("Pending recovery cleared the login") } == false)
        #expect(selected.events.isEmpty && !service.isCleaning && service.resetFailureMessage != nil)
        if !legacy { #expect(try files.readData(at: url) == journal); try files.removeItem(at: url) }
        legacyData = nil
        #expect(await service.resetAllLocalData { selected.events.append("logout") })
        #expect(service.resetFailureMessage == nil && selected.events.last == "logout")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func profileMutationsKeepOneOwnerThroughSuccessFailureAndRetry(fails: Bool) async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        let first = Task {
            do {
                try await mutation.perform {
                    writes.append("first")
                    await withCheckedContinuation { pending = $0 }
                    if fails { throw URLError(.timedOut) }
                }
                return !fails
            } catch { return fails && (error as? URLError)?.code == .timedOut }
        }
        try await waitForTestEvent { !(pending == nil) }
        #expect(mutation.isUpdating)
        try await mutation.perform { writes.append("duplicate") }
        #expect(mutation.isUpdating && writes == ["first"])
        pending?.resume()
        #expect(await first.value)
        #expect(!mutation.isUpdating)
        try await mutation.perform { writes.append("retry") }
        #expect(writes == ["first", "retry"] && !mutation.isUpdating)
    }

    @Test func resetUsesEverySelectedActionAndAggregatesFailure() async throws {
        let selected = LocalDataActionsSpy(), surrounding = LocalDataActionsSpy()
        selected.succeeds = false
        let files = PreferenceMemoryFiles(), surroundingFiles = PreferenceMemoryFiles()
        let url = files.temporaryDirectoryURL.appending(path: "owned.dat")
        try files.writeData(Data([1, 2, 3]), to: url, options: [])
        try surroundingFiles.writeData(Data([4]), to: url, options: [])
        let service = AppLocalDataService(files: files, actions: selected.actions)
        #expect(await service.resetAllLocalData { selected.events.append("logout") } == false)
        #expect(selected.events == ["login", "storage", "schedule", "shared", "reports", "diagnostics", "preferences", "media", "url-cache", "web-data", "settings", "storage-resume", "logout"])
        #expect(files.fileExists(at: url) == false)
        #expect(try surroundingFiles.readData(at: url) == Data([4]))
        #expect(surrounding.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["storage", "schedule", "shared", "diagnostics", "media", "web-data"])
    func resetRetainsItsAppOwnerAndOpensTheNextSessionAfterEveryCleanup(stage: String) async throws {
        let actions = LocalDataActionsSpy()
        actions.suspendedAction = stage
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "next-session.dat")
        let service = AppLocalDataService(files: files, actions: actions.actions)
        var loggedOut = false
        let task = Task { await service.resetAllLocalData {
            loggedOut = true
            actions.events.append("logout")
            try? files.writeData(Data([9]), to: file, options: [.atomic])
        } }
        try await waitForTestEvent { !(actions.pending == nil) }
        #expect(service.isCleaning && !loggedOut)
        let previous = actions.events
        #expect(await service.resetAllLocalData { Issue.record("Concurrent reset changed the session") } == false)
        #expect(await service.clearCaches().succeeded == false)
        #expect(actions.events == previous)
        actions.pending?.resume()
        #expect(await task.value)
        #expect(!service.isCleaning && loggedOut)
        #expect(try files.readData(at: file) == Data([9]))
        #expect(actions.events.suffix(2) == ["storage-resume", "logout"])
    }

    @Test(arguments: [false, true]) func cacheCleanupUsesTheSelectedFileAndMediaOwners(removalFails: Bool) async throws {
        let selected = LocalDataActionsSpy(), surrounding = LocalDataActionsSpy()
        let files = PreferenceMemoryFiles()
        let cache = files.temporaryDirectoryURL.appending(path: "owned-cache")
        let export = files.temporaryDirectoryURL.appending(path: "active-export.dat")
        try files.createDirectory(at: cache)
        try files.writeData(Data([1, 2, 3]), to: cache.appending(path: "cache.dat"), options: [])
        try files.writeData(Data([4, 5]), to: export, options: [])
        selected.mediaCleanup = { files.removeContents(of: cache) }
        files.setFailures(removal: removalFails)
        let result = await AppLocalDataService(files: files, actions: selected.actions, cacheDirectories: [cache]).clearCaches()
        #expect(result.succeeded == !removalFails)
        #expect(result.reclaimedBytes == (removalFails ? 0 : 3))
        #expect(files.totalRegularFileSize(at: cache) == (removalFails ? 3 : 0))
        #expect(try files.readData(at: export) == Data([4, 5]))
        #expect(selected.events == ["media", "url-cache"])
        #expect(surrounding.events.isEmpty)
    }

    @Test func resettingAccountDataKeepsTemporaryExportsAndOtherCacheOwners() async throws {
        let files = PreferenceMemoryFiles(separatesDirectories: true)
        let actions = LocalDataActionsSpy()
        let support = try #require(files.directoryURL(.applicationSupportDirectory)).appending(path: "account.dat")
        let cache = try #require(files.directoryURL(.cachesDirectory)).appending(path: "other-cache.dat")
        let export = files.temporaryDirectoryURL.appending(path: "active-export.dat")
        for file in [support, cache, export] { try files.writeData(Data([1]), to: file, options: []) }
        #expect(await AppLocalDataService(files: files, actions: actions.actions).resetAllLocalData {})
        #expect(files.fileExists(at: support) == false)
        #expect(try files.readData(at: cache) == Data([1]))
        #expect(try files.readData(at: export) == Data([1]))
    }
}

@MainActor
@Suite(.serialized)
struct SettingsDependencyOwnershipTests {
    private final class DiagnosisTranscript: TrustedTranscriptServicing {
        var calls = 0
        func fetchTrustedTranscriptPages() async throws -> [Data] { calls += 1; return [] }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { [] }
    }

    private final class OfflineTransport: HTTPTransport {
        var requests: [URL] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let url = request.url { requests.append(url) }
            throw URLError(.notConnectedToInternet)
        }
    }

    @Test func settingsDestinationsPreserveTheirSelectedMediaAccountAndCleanupOwners() async throws {
        let firstDomain = "BIT101Tests.settings-media-A", secondDomain = "BIT101Tests.settings-media-B"
        let firstDefaults = try #require(UserDefaults(suiteName: firstDomain))
        let secondDefaults = try #require(UserDefaults(suiteName: secondDomain))
        firstDefaults.removePersistentDomain(forName: firstDomain)
        secondDefaults.removePersistentDomain(forName: secondDomain)
        defer {
            firstDefaults.removePersistentDomain(forName: firstDomain)
            secondDefaults.removePersistentDomain(forName: secondDomain)
        }
        let transport = OfflineTransport()
        let client = HTTPClient(transport: transport, observer: nil)
        func media(_ defaults: UserDefaults) -> MediaEnvironment {
            MediaEnvironment(files: PreferenceMemoryFiles(), previewStorage: MediaPreviewStorage(files: PreferenceMemoryFiles()), defaults: defaults,
                imageHTTPClient: client, avatarHTTPClient: client)
        }
        let firstMedia = media(firstDefaults), secondMedia = media(secondDefaults)
        let originalSecondLimit = secondMedia.cacheLimitMB
        let account = AppStorageSession(accountIdentifier: "settings-A")
        let credentials = CommunityCredentials(identity: .init(accountIdentifier: account.accountIdentifier, generation: 7), cookie: "fixture-A")
        let session = CommunitySession(httpClient: client, baseURL: AppURL.required("https://example.invalid"),
            credentials: { credentials }, refresh: { _ in })
        let effects = LocalDataActionsSpy()
        var validationCount = 0
        let dependencies = AppCommunityDependencies(settings: AppSettingsStore(defaults: firstDefaults, session: { account }),
            session: session, checkLogin: { validationCount += 1; return true },
            messages: GalleryMessageReadStore(defaults: firstDefaults, session: { account }),
            drafts: ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                session: { account }, prepareImageData: ComposerDraftImageCompressor.compress),
            submitSuggestion: { _ in }, loadCourseCredits: { [] }, networkPath: NetworkPathState(snapshot: .init(status: .disconnected)))
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in })
        let service = SemesterStartDateService()
        let schedule = ScheduleViewModel(service: service, repository: repository, ddlService: service, classroomService: service,
            platformActions: RecordingSchedulePlatformActions(), newCustomScheduleDraft: { CustomScheduleDraft() })
        var schoolCalls: [String] = []
        let transcript = DiagnosisTranscript()
        let cloud = ScheduleCloudSyncPresentation(currentAccount: { nil }, accountChanges: Empty().eraseToAnyPublisher())
        let destinations = AppCommunityDestinations(dependencies: dependencies, schedule: schedule, scheduleCloudSync: cloud, media: firstMedia,
            localData: AppLocalDataService(files: PreferenceMemoryFiles(), actions: effects.actions),
            school: NetworkDiagnosisSchool(identity: { .init(accountIdentifier: account.accountIdentifier, generation: 0) },
                currentTerm: { schoolCalls.append("term"); return "fixture" },
                syncCourses: { schoolCalls.append($0) }, ddl: { schoolCalls.append("ddl") }), transcript: transcript)
        let selected = destinations.settingsDependencies
        #expect(selected.settings === dependencies.settingsStore)
        #expect(selected.schedule === schedule)
        #expect(selected.scheduleCloudSync === cloud)
        let page = GallerySettingsPage(media: selected.media, diagnosis: selected.networkDiagnosis)
        #expect(page.media === firstMedia)
        page.media.cacheLimitMB = 128
        #expect(firstMedia.cacheLimitMB == 128)
        #expect(secondMedia.cacheLimitMB == originalSecondLimit)
        #expect(selected.account.credentials() == credentials)
        let report = await NetworkDiagnosisRunner(dependencies: selected.networkDiagnosis).run()
        let requests = transport.requests
        #expect(report?.results.count == NetworkDiagnosisRunner.Step.allCases.count)
        #expect(report?.summary.contains("网络路径：未连接") == true)
        #expect(selected.networkDiagnosis.identity().community == credentials.identity)
        #expect(requests.filter { $0.host == "example.invalid" }.count == 2)
        #expect(requests.contains { $0.host == "open.aihelpme.dev" })
        #expect(schoolCalls == ["term", "fixture", "ddl"] && transcript.calls == 1)
        var currentCredentials = credentials
        let checks = SettingsAccountDependencies(service: selected.account.service, credentials: { currentCredentials })
        #expect(checks.acceptsLoginCheck(true, for: credentials))
        let renewed = CommunitySessionIdentity(accountIdentifier: credentials.identity.accountIdentifier, generation: credentials.identity.generation + 1)
        currentCredentials = CommunityCredentials(identity: renewed, cookie: "")
        #expect(checks.acceptsLoginCheck(false, for: credentials))
        #expect(!checks.acceptsLoginCheck(true, for: credentials))
        currentCredentials = CommunityCredentials(identity: renewed, cookie: "renewed")
        #expect(!checks.acceptsLoginCheck(false, for: credentials))
        currentCredentials = CommunityCredentials(identity: .init(accountIdentifier: "another-account"), cookie: "")
        #expect(!checks.acceptsLoginCheck(false, for: credentials))
        #expect(try await selected.account.service.checkLogin())
        #expect(validationCount == 1)
        #expect(await selected.localData.clearCaches().succeeded)
        #expect(effects.events == ["media", "url-cache"])
    }
}
