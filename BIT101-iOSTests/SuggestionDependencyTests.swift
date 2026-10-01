import CommunityUI
import ScheduleDomain
import ScheduleFeature
import CommunityTransport
import MediaKit
import TransportCore
import Foundation
import GalleryFeature
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct SuggestionDependencyTests {
    private final class Account {
        var session = AppStorageSession(accountIdentifier: "A")
    }
    private func store(_ files: PreferenceMemoryFiles) -> ComposerDraftStore {
        ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                           session: { AppStorageSession(accountIdentifier: "suggestion-test") }, prepareImageData: ComposerDraftImageCompressor.compress)
    }

    private func payload() -> DeveloperSuggestionPayload {
        let context = FeedbackDeviceContext.current
        return DeveloperSuggestionPayload(comment: "injected suggestion", contact: "fixture", appVersion: "test", build: "test",
            systemVersion: "test", deviceModel: "test", networkStatus: context.networkStatus,
            submittedAt: Date(timeIntervalSince1970: 0), context: context, attachments: [])
    }

    @Test func successfulSubmissionUsesTheChosenDraftAndDeliveryOwner() async throws {
        let first = store(PreferenceMemoryFiles())
        let second = store(PreferenceMemoryFiles())
        #expect(await first.saveSuggestion(.init(text: "first draft", images: [])))
        #expect(await second.saveSuggestion(.init(text: "second draft", images: [])))
        var delivered: [String] = []
        let dependencies = DeveloperSuggestionDependencies(drafts: first, submit: { delivered.append($0.comment) })
        let page = DeveloperSuggestionPage(dependencies: dependencies)
        #expect(await page.dependencies.drafts.loadSuggestion()?.text == "first draft")
        try await page.dependencies.submitAndClear(payload())
        #expect(delivered == ["injected suggestion"])
        #expect(await first.loadSuggestion() == nil)
        #expect(await second.loadSuggestion()?.text == "second draft")
    }

    @Test func deliveryFailurePreservesTheOwnedDraft() async {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "retained draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await dependencies.submitAndClear(payload()) }
        #expect(await drafts.loadSuggestion()?.text == "retained draft")
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
        #expect(await drafts.loadSuggestion()?.text == "B draft")
        account.session = AppStorageSession(accountIdentifier: "A")
        #expect(await drafts.loadSuggestion() == nil)
    }

    @Test func aFreshDraftRevisionSurvivesAnEarlierSubmissionCleanup() async throws {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "submitted draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            #expect(await drafts.saveSuggestion(.init(text: "continued edit", images: [])))
        })
        try await dependencies.submitAndClear(payload())
        #expect(await drafts.loadSuggestion()?.text == "continued edit")
    }

}

@MainActor
final class LocalDataActionsSpy {
    var events: [String] = []
    var succeeds = true
    var actions: AppLocalDataActions {
        AppLocalDataActions(
            clearLogin: { self.events.append("login"); return self.succeeds },
            clearSchedule: { self.events.append("schedule"); return self.succeeds },
            clearSharedSnapshot: { self.events.append("shared"); return self.succeeds },
            clearReports: { self.events.append("reports"); return self.succeeds },
            clearPreferences: { self.events.append("preferences") },
            clearURLCache: { self.events.append("url-cache") },
            clearWebData: { self.events.append("web-data") },
            clearMedia: { self.events.append("media") },
            resetSettings: { self.events.append("settings") }
        )
    }
}

@MainActor
struct AppLocalDataOwnershipTests {
    @Test func resetUsesEverySelectedActionAndAggregatesFailure() async throws {
        let selected = LocalDataActionsSpy(), surrounding = LocalDataActionsSpy()
        selected.succeeds = false
        let files = PreferenceMemoryFiles(), surroundingFiles = PreferenceMemoryFiles()
        let url = files.temporaryDirectoryURL.appending(path: "owned.dat")
        try files.writeData(Data([1, 2, 3]), to: url, options: [])
        try surroundingFiles.writeData(Data([4]), to: url, options: [])
        let service = AppLocalDataService(files: files, actions: selected.actions)
        #expect(await service.resetAllLocalData { selected.events.append("logout") } == false)
        #expect(selected.events == ["login", "logout", "schedule", "shared", "reports", "preferences", "url-cache", "web-data", "media", "settings"])
        #expect(files.fileExists(at: url) == false)
        #expect(try surroundingFiles.readData(at: url) == Data([4]))
        #expect(surrounding.events.isEmpty)
    }

    @Test func cacheCleanupUsesTheSelectedFileAndMediaOwners() async throws {
        let selected = LocalDataActionsSpy(), surrounding = LocalDataActionsSpy()
        let files = PreferenceMemoryFiles()
        try files.writeData(Data([1, 2, 3]), to: files.temporaryDirectoryURL.appending(path: "cache.dat"), options: [])
        let result = await AppLocalDataService(files: files, actions: selected.actions).clearCaches()
        #expect(result.succeeded)
        #expect(result.reclaimedBytes == 3)
        #expect(files.totalRegularFileSize(at: files.temporaryDirectoryURL) == 0)
        #expect(selected.events == ["url-cache", "media"])
        #expect(surrounding.events.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct SettingsDependencyOwnershipTests {
    private struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
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
        let client = HTTPClient(transport: OfflineTransport(), observer: nil)
        func media(_ defaults: UserDefaults) -> MediaEnvironment {
            MediaEnvironment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), defaults: defaults,
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
            submitSuggestion: { _ in }, loadCourseCredits: { [] })
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in })
        let service = SemesterStartDateService()
        let schedule = ScheduleViewModel(service: service, repository: repository, ddlService: service, classroomService: service,
            platformActions: RecordingSchedulePlatformActions(), newCustomScheduleDraft: { CustomScheduleDraft() })
        let destinations = AppCommunityDestinations(dependencies: dependencies, schedule: schedule, media: firstMedia,
            localData: AppLocalDataService(files: PreferenceMemoryFiles(), actions: effects.actions))
        let selected = destinations.settingsDependencies
        #expect(selected.settings === dependencies.settingsStore)
        #expect(selected.schedule === schedule)
        let page = GallerySettingsPage(media: selected.media)
        #expect(page.media === firstMedia)
        page.media.cacheLimitMB = 128
        #expect(firstMedia.cacheLimitMB == 128)
        #expect(secondMedia.cacheLimitMB == originalSecondLimit)
        #expect(selected.account.credentials() == credentials)
        #expect(try await selected.account.service.checkLogin())
        #expect(validationCount == 1)
        #expect(await selected.localData.clearCaches().succeeded)
        #expect(effects.events == ["url-cache", "media"])
    }
}
