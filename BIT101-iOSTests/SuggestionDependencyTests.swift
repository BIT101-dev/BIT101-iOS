import CommunityPersistence
import CommunityCore
import CommunityUI
import ScheduleDomain
import ScheduleContracts
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
import XCTest
import WebKit
@testable import BIT101_iOS

@MainActor
struct ErrorReportURLRedactionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [1_000, 12_000])
    func deeplyNestedURLsStayWithinTheInputBudget(depth: Int) async {
        let input = String(repeating: "https://a.invalid/?x=", count: depth)
            + "https://z.invalid/?ticket=secret"
        for output in [ErrorReportRedactor.forced(input, credentials: []),
                       ErrorReportRedactor.sanitized(input, credentials: [], studentID: "")] {
            #expect(output.utf8.count < input.utf8.count)
            #expect(!output.contains("secret"))
        }
    }

    @Test func encodedCredentialsAreMaskedAcrossURLComponents() throws {
        let credentials = ["a&b", "密 码"]
        for suffix in ["?value=a%26b", "?value=%2561%2526%2562", "?a%26b=ordinary", "?password-a%26b=ordinary",
                       "#a%26b", "#section=a%2526b", "?value=%E5%AF%86%20%E7%A0%81",
                       "?service=https%3A%2F%2Fschool.invalid%2F%3Fvalue%3Da%2526b"] {
            let input = "https://example.invalid/" + suffix
            let outputs = [ErrorReportRedactor.forced(input, credentials: credentials),
                ErrorReportRedactor.sanitized(input, credentials: credentials, studentID: "")]
            for (mode, output) in outputs.enumerated() {
                let decoded = try #require(output.removingPercentEncoding?.removingPercentEncoding)
                for credential in credentials { #expect(!decoded.contains(credential), Comment(rawValue: suffix)) }
                if mode == 0 { #expect(decoded.contains("[REDACTED]"), Comment(rawValue: suffix)) }
                #expect(decoded.contains("example.invalid"), Comment(rawValue: suffix))
            }
        }
        let ordinary = "https://example.invalid/?value=hello%2520world#section"
        #expect(ErrorReportRedactor.forced(ordinary, credentials: credentials) == ordinary)
    }
}

@MainActor
struct SuggestionDependencyTests {
    @Test(.timeLimit(.minutes(1))) func diagnosticPreparationUsesCapturedCredentialsAndKeepsTheMainActorResponsive() async throws {
        let marker = "CAPTURED_FIXTURE_SECRET", context = FeedbackDeviceContext.current
        let body = String(repeating: marker + " ", count: (256 * 1_024) / (marker.utf8.count + 1))
        let diagnostics = (0..<10).map { _ in
            NetworkDiagnosticRecord(id: UUID(), occurredAt: Date(), method: "GET", url: "https://example.invalid/report",
                statusCode: 500, elapsedMilliseconds: 1, error: marker, responseHeaders: [:], responseBody: body)
        }
        let payload = ErrorReportPayload(mode: "raw", isDevelopmentBuild: false, comment: marker, contact: nil,
            errorTitle: "fixture", errorMessage: marker, appVersion: "test", build: "test", systemVersion: "test",
            deviceModel: "test", networkStatus: context.networkStatus, diagnostics: diagnostics, submittedAt: Date(),
            context: context, diagnosticSummary: FeedbackDiagnosticSummary(diagnostics: diagnostics),
            scheduleCacheReadFailure: "decode.invalid:courses \(marker)")
        var heartbeat = false
        let mainActorWork = Task { @MainActor in heartbeat = true }
        defer { mainActorWork.cancel() }
        let prepared = try await payload.preparedForSubmission(credentials: [marker], studentID: "fixture")
        #expect(heartbeat)
        await mainActorWork.value
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(prepared)
        #expect(encoded.count <= 1_024 * 1_024)
        #expect(String(decoding: encoded, as: UTF8.self).contains(marker) == false)
        #expect(prepared.scheduleCacheReadFailure == "decode.invalid:courses [REDACTED]")
        #expect(payload.diagnostics.first?.responseBody == body)
    }

    @MainActor
    private final class SuggestionDraftPort: DeveloperSuggestionDraftStoring {
        var cleanups = 0
        var failsCleanup = false
        var failsSave = false
        var onSave: (() -> Void)?
        func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool { onSave?(); return !failsSave }
        func loadSuggestion() async -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> { .missing }
        func removeSuggestion() async -> Bool { cleanups += 1; return !failsCleanup }
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

    @Test(.timeLimit(.minutes(1))) func suggestionPageAcceptsAnIndependentDraftPort() async throws {
        let drafts = SuggestionDraftPort()
        var delivered: [String] = []
        let page = DeveloperSuggestionPage(dependencies: .init(drafts: drafts, submit: { delivered.append($0.comment) }))
        _ = await (try await page.dependencies.submitAndClear(payload())).value
        #expect(delivered == ["injected suggestion"])
        #expect(drafts.cleanups == 1)
    }

    @Test(.timeLimit(.minutes(1))) func confirmedSuggestionCompletesWhileCleanupFails() async throws {
        let drafts = SuggestionDraftPort()
        drafts.failsCleanup = true
        var deliveries = 0
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in deliveries += 1 })
        let cleanup = try await dependencies.submitAndClear(payload())
        #expect(deliveries == 1)
        #expect(await cleanup.value == false)
        #expect(deliveries == 1 && drafts.cleanups == 1)
    }

    @Test(.timeLimit(.minutes(1))) func successfulSubmissionUsesTheChosenDraftAndDeliveryOwner() async throws {
        let first = store(PreferenceMemoryFiles())
        let second = store(PreferenceMemoryFiles())
        #expect(await first.saveSuggestion(.init(text: "first draft", images: [])))
        #expect(await second.saveSuggestion(.init(text: "second draft", images: [])))
        var delivered: [String] = []
        let dependencies = DeveloperSuggestionDependencies(drafts: first, submit: { delivered.append($0.comment) })
        let page = DeveloperSuggestionPage(dependencies: dependencies)
        #expect(await page.dependencies.drafts.loadSuggestion().snapshot?.text == "first draft")
        _ = await (try await page.dependencies.submitAndClear(payload())).value
        #expect(delivered == ["injected suggestion"])
        #expect(await first.loadSuggestion().snapshot == nil)
        #expect(await second.loadSuggestion().snapshot?.text == "second draft")
    }

    @Test(.timeLimit(.minutes(1))) func deliveryFailurePreservesTheOwnedDraft() async {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "retained draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await dependencies.submitAndClear(payload()) }
        #expect(await drafts.loadSuggestion().snapshot?.text == "retained draft")
    }
    @Test(.timeLimit(.minutes(1))) func lostResponsesKeepTheSuggestionIdentityAndSuccessReleasesTheAttempt() async throws {
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
            _ = await (try await dependencies.submitAndClear(prepared)).value
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
    @Test(.timeLimit(.minutes(1))) func restoredSuggestionKeepsItsFullWireIdentityAndSeparateImageAsset() async throws {
        let files = PreferenceMemoryFiles()
        let drafts = store(files)
        let bytes = Data(repeating: 0xab, count: ComposerDraftImagePolicy.maximumBytes)
        let images = [ComposerImageDraftSnapshot(filename: "suggestion.jpg", previewData: bytes, uploadData: bytes)]
        var original = payload()
        original.isDevelopmentBuild = false
        original.attachments = [.init(filename: "suggestion.jpg", contentType: "image/jpeg", data: bytes.base64EncodedString())]
        let draft = DeveloperSuggestionDraftSnapshot(text: original.comment, images: images, contact: "fixture")
        let metadata = try #require(try original.draftMetadata(matching: draft))
        #expect(metadata.count < ComposerDraftImagePolicy.maximumMetadataBytes)
        let saved = DeveloperSuggestionDraftSnapshot(text: draft.text, images: images, contact: draft.contact,
            pendingSubmissionMetadata: metadata)
        var deliveries: [DeveloperSuggestionPayload] = []
        let failed = DeveloperSuggestionDependencies(drafts: drafts, submit: {
            deliveries.append($0); throw URLError(.timedOut)
        })
        await #expect(throws: URLError.self) { try await failed.submitAndClear(original, persisting: saved) }
        let restored = try #require(await store(files).loadSuggestion().snapshot)
        let attempt = FeedbackSubmissionAttempt<DeveloperSuggestionPayload>()
        attempt.restore(try DeveloperSuggestionPayload.restored(from: restored))
        var candidate = payload(); candidate.attachments = original.attachments
        let retry = attempt.prepare(candidate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        #expect(try encoder.encode(retry) == encoder.encode(original))
        let successful = DeveloperSuggestionDependencies(drafts: drafts, submit: { deliveries.append($0) })
        _ = await (try await successful.submitAndClear(retry)).value
        #expect(deliveries.count == 2 && deliveries[0].requestID == deliveries[1].requestID)
        #expect(await drafts.loadSuggestion().snapshot == nil)
        let edited = DeveloperSuggestionDraftSnapshot(text: "edited", images: images, contact: draft.contact)
        #expect(try original.draftMetadata(matching: edited) == nil)
        #expect(attempt.prepare(payload(comment: "edited")).requestID != original.requestID)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func suggestionPersistenceFailureKeepsDeliveryAvailableAndPreservesTheDraft(readFailure: Bool) async throws {
        let files = PreferenceMemoryFiles()
        let drafts = store(files)
        #expect(await drafts.saveSuggestion(.init(text: "saved content", images: [])))
        files.setFailures(writing: !readFailure, reading: readFailure)
        var deliveries = 0
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in deliveries += 1 })
        let cleanup = try await dependencies.submitAndClear(payload(), persisting: .init(text: "edited content", images: []))
        #expect(deliveries == 1)
        #expect(await cleanup.value == false)
        files.setFailures()
        #expect(await drafts.loadSuggestion().snapshot?.text == "saved content")
    }

    @Test(.timeLimit(.minutes(1))) func accountSwitchDuringSuggestionPersistenceStopsDeliveryAndCleanup() async throws {
        let drafts = SuggestionDraftPort()
        var generation = 0
        var deliveries = 0
        drafts.onSave = { generation += 1 }
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in deliveries += 1 },
            captureSubmissionOwner: { let captured = generation; return { captured == generation } })
        await #expect(throws: CancellationError.self) {
            _ = await (try await dependencies.submitAndClear(payload(), persisting: .init(text: "saved content", images: []))).value
        }
        #expect(deliveries == 0 && drafts.cleanups == 0)
    }

    @Test(.timeLimit(.minutes(1))) func corruptSuggestionIdentityKeepsTheSavedContentForRecovery() async throws {
        let drafts = store(PreferenceMemoryFiles())
        let snapshot = DeveloperSuggestionDraftSnapshot(text: "retained content", images: [],
            pendingSubmissionMetadata: Data("corrupt submission".utf8))
        #expect(await drafts.saveSuggestion(snapshot))
        let restored = try #require(await drafts.loadSuggestion().snapshot)
        #expect(throws: DecodingError.self) { try DeveloperSuggestionPayload.restored(from: restored) }
        #expect(await drafts.loadSuggestion().snapshot?.pendingSubmissionMetadata == snapshot.pendingSubmissionMetadata)
    }

    @Test(.timeLimit(.minutes(1))) func delayedSubmissionCleanupStaysWithTheCapturedAccount() async throws {
        let account = Account()
        let drafts = ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"), session: { account.session }, prepareImageData: ComposerDraftImageCompressor.compress)
        #expect(await drafts.saveSuggestion(.init(text: "A draft", images: [])))
        account.session = AppStorageSession(accountIdentifier: "B")
        #expect(await drafts.saveSuggestion(.init(text: "B draft", images: [])))
        account.session = AppStorageSession(accountIdentifier: "A")
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            account.session = AppStorageSession(accountIdentifier: "B")
        })
        _ = await (try await dependencies.submitAndClear(payload())).value
        #expect(await drafts.loadSuggestion().snapshot?.text == "B draft")
        account.session = AppStorageSession(accountIdentifier: "A")
        #expect(await drafts.loadSuggestion().snapshot == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aFreshDraftRevisionSurvivesAnEarlierSubmissionCleanup() async throws {
        let drafts = store(PreferenceMemoryFiles())
        #expect(await drafts.saveSuggestion(.init(text: "submitted draft", images: [])))
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            #expect(await drafts.saveSuggestion(.init(text: "continued edit", images: [])))
        })
        _ = await (try await dependencies.submitAndClear(payload())).value
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

nonisolated final class AppLocalDataResourceTests: XCTestCase {
    @MainActor
    func testAppCompositionClearsDiskResources() async throws {
        try await verifyAppComposition(storagePolicy: .allowed)
    }

    @MainActor
    func testAppCompositionClearsMemoryResources() async throws {
        try await verifyAppComposition(storagePolicy: .allowedInMemoryOnly)
    }

    @MainActor
    private func verifyAppComposition(storagePolicy: URLCache.StoragePolicy) async throws {
        let files = AppFileDirectories.files, defaults = AppFileDirectories.defaults
        let originalCache = URLCache.shared
        let cacheDirectory = try XCTUnwrap(files.directoryURL(.cachesDirectory)).appending(path: "cleanup-fixture")
        let cache = URLCache(memoryCapacity: storagePolicy == .allowed ? 0 : originalCache.memoryCapacity,
                             diskCapacity: originalCache.diskCapacity, directory: cacheDirectory)
        URLCache.shared = cache
        defer {
            cache.removeAllCachedResponses()
            URLCache.shared = originalCache
        }
        let media = AppMedia.makeEnvironment(previewStorage: MediaPreviewStorage(files: files))
        let settings = AppSettingsStore(defaults: defaults)
        let service = AppLocalDataComposition.appService(settings: settings, media: media)
        let support = AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS").appending(path: "cleanup-fixture.dat")
        let report = try XCTUnwrap(ReleaseNetworkSmokeReportStore.fileURL)
        let mediaCache = try XCTUnwrap(media.cacheDirectories.first).appending(path: "cleanup-fixture.dat")
        for file in [support, report, mediaCache] {
            try files.createDirectory(at: file.deletingLastPathComponent())
            try files.writeData(Data([1, 2, 3]), to: file, options: [.atomic])
        }
        let snapshotStore = PlatformScheduleSnapshotStorage.store
        try snapshotStore.write(ScheduleExternalSnapshot(revision: 1, isLoggedIn: true,
            studentID: "cleanup-fixture", firstDayString: "2026-01-01", timeTable: [], courses: []))
        try AppAccountSession.storage.saveLoginState(studentID: "cleanup-fixture", password: "fixture", fakeCookie: "fixture")
        defaults.set("fixture", forKey: "cleanup-fixture")
        let url = AppURL.required("https://example.invalid/cleanup-fixture")
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "text/plain"]))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2, 3]),
            userInfo: nil, storagePolicy: storagePolicy), for: request)
        let cookies = AppLocalDataComposition.websiteDataStore.httpCookieStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.invalid", .path: "/",
            .name: "cleanup-fixture", .value: "fixture", .expires: Date().addingTimeInterval(3_600)]))
        await cookies.setCookie(cookie)
        let seededCookies = await cookies.allCookies()
        XCTAssertTrue(seededCookies.contains { $0.name == cookie.name })
        try await waitForTestEvent { cache.cachedResponse(for: request)?.data == Data([1, 2, 3]) }
        if storagePolicy == .allowed { XCTAssertGreaterThan(cache.currentDiskUsage, 0) }
        XCTAssertTrue(snapshotStore.load()?.isLoggedIn == true)
        XCTAssertTrue(!AppAccountSession.storage.fakeCookie.isEmpty)
        var loggedOut = false
        let reset = await service.resetAllLocalData { loggedOut = true }
        XCTAssertTrue(reset, service.resetFailureMessage ?? "Local data reset completed")
        XCTAssertTrue(loggedOut && !service.isCleaning)
        for file in [support, report, mediaCache] { XCTAssertTrue(files.fileExists(at: file) == false) }
        XCTAssertTrue(snapshotStore.load() == nil)
        XCTAssertTrue(AppAccountSession.storage.fakeCookie.isEmpty && AppAccountSession.storage.currentStudentID.isEmpty)
        XCTAssertTrue(try AppAccountSession.storage.loadCredentials() == nil)
        XCTAssertTrue(defaults.object(forKey: "cleanup-fixture") == nil)
        XCTAssertTrue(URLCache.shared === cache)
        try await waitForTestEvent { cache.cachedResponse(for: request) == nil }
        let remainingCookies = await cookies.allCookies()
        XCTAssertTrue(remainingCookies.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct AppLocalDataOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func loginChecksPublishTheSharedBusyStateBeforeSchedulingAndReleaseItForProfileEdits() async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        #expect(mutation.start {
            await withCheckedContinuation { pending = $0 }
        })
        #expect(mutation.isBusy && !mutation.isUpdating)
        #expect(mutation.start { writes.append("overlap") } == false)
        try await waitForTestEvent { pending != nil }
        #expect(mutation.isBusy && !mutation.isUpdating)
        pending?.resume()
        try await waitForTestEvent { !mutation.isBusy }
        #expect(mutation.start {
            try? await mutation.perform { writes.append("profile") }
        })
        #expect(mutation.isBusy)
        try await waitForTestEvent { !mutation.isBusy }
        #expect(writes == ["profile"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func pendingOnlineRecoveryProtectsCredentialsAndJournalBeforeReset(legacy: Bool) async throws {
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
        #expect(mutation.isUpdating && mutation.isBusy)
        #expect(mutation.start { writes.append("overlap") } == false)
        try await mutation.perform { writes.append("duplicate") }
        #expect(mutation.isUpdating && writes == ["first"])
        pending?.resume()
        #expect(await first.value)
        #expect(!mutation.isUpdating)
        try await mutation.perform { writes.append("retry") }
        #expect(writes == ["first", "retry"] && !mutation.isUpdating)
    }

    @Test(.timeLimit(.minutes(1))) func leavingAProfilePageCancelsItsTaskAndRetainsTheSharedMutationLock() async throws {
        let mutation = AccountProfileMutation()
        var pending: CheckedContinuation<Void, Never>?
        var finished = false, rebound = false
        mutation.start {
            do {
                try await mutation.perform {
                    await withCheckedContinuation { pending = $0 }
                    try Task.checkCancellation()
                    rebound = true
                }
            } catch { #expect(error is CancellationError) }
            finished = true
        }
        try await waitForTestEvent { pending != nil }
        mutation.cancel()
        mutation.start { rebound = true }
        #expect(mutation.isUpdating)
        pending?.resume()
        try await waitForTestEvent { finished }
        #expect(!mutation.isUpdating && !rebound)
        mutation.start { rebound = true }
        try await waitForTestEvent { rebound }
    }

    @Test(.timeLimit(.minutes(1))) func resetUsesEverySelectedActionAndAggregatesFailure() async throws {
        let selected = LocalDataActionsSpy(), surrounding = LocalDataActionsSpy()
        selected.succeeds = false
        let files = PreferenceMemoryFiles(), surroundingFiles = PreferenceMemoryFiles()
        let url = files.temporaryDirectoryURL.appending(path: "owned.dat")
        try files.writeData(Data([1, 2, 3]), to: url, options: [])
        try surroundingFiles.writeData(Data([4]), to: url, options: [])
        let service = AppLocalDataService(files: files, actions: selected.actions)
        #expect(await service.resetAllLocalData { selected.events.append("logout") } == false)
        #expect(service.resetFailureMessage == "以下本机数据仍待清理：登录凭据、课表缓存、小组件与手表数据、网络验收记录、图片缓存。请稍后重试。")
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
            do { try files.writeData(Data([9]), to: file, options: [.atomic]) } catch { Issue.record(error) }
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func cacheCleanupUsesTheSelectedFileAndMediaOwners(removalFails: Bool) async throws {
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

    @Test(.timeLimit(.minutes(1))) func resettingAccountDataKeepsTemporaryExportsAndOtherCacheOwners() async throws {
        let files = PreferenceMemoryFiles(separatesDirectories: true)
        let actions = LocalDataActionsSpy()
        let support = try #require(files.directoryURL(.applicationSupportDirectory)).appending(path: "BIT101-iOS/account.dat")
        let cache = try #require(files.directoryURL(.cachesDirectory)).appending(path: "other-cache.dat")
        let export = files.temporaryDirectoryURL.appending(path: "active-export.dat")
        for file in [support, cache, export] { try files.writeData(Data([1]), to: file, options: []) }
        #expect(await AppLocalDataService(files: files, actions: actions.actions).resetAllLocalData {})
        #expect(files.fileExists(at: support) == false)
        #expect(try files.readData(at: cache) == Data([1]))
        #expect(try files.readData(at: export) == Data([1]))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func resetClearsOwnedDataAndContentsOfManagedDocumentDirectories(ownedRemovalFails: Bool) async throws {
        let files = PreferenceMemoryFiles(separatesDirectories: true)
        let support = try #require(files.directoryURL(.applicationSupportDirectory))
        let documents = try #require(files.directoryURL(.documentDirectory))
        let account = support.appending(path: "BIT101-iOS")
        let managed = support.appending(path: "com.apple.system")
        let inbox = documents.appending(path: "Inbox")
        let owned = [account.appending(path: "account.dat"), support.appending(path: "ComposerDrafts/draft.dat"),
            support.appending(path: "NetworkSmoke/report.json"), documents.appending(path: "document.dat"),
            inbox.appending(path: "imported.dat")]
        let systemFile = managed.appending(path: "system.dat")
        for file in owned + [systemFile] {
            try files.createDirectory(at: file.deletingLastPathComponent())
            try files.writeData(Data([1]), to: file, options: [])
        }
        files.protectRemoval(of: ownedRemovalFails ? [managed, inbox, account] : [managed, inbox])
        let service = AppLocalDataService(files: files, actions: LocalDataActionsSpy().actions)
        #expect(await service.resetAllLocalData {} == !ownedRemovalFails)
        for file in owned {
            #expect(files.fileExists(at: file) == (ownedRemovalFails && file.deletingLastPathComponent().path == account.path))
        }
        #expect(try files.readData(at: systemFile) == Data([1]))
        #expect(files.fileExists(at: inbox))
        #expect(service.resetFailureMessage == (ownedRemovalFails
            ? "以下本机数据仍待清理：本机文稿与应用数据。请稍后重试。" : nil))
    }
}

@MainActor
@Suite(.serialized)
struct SettingsDependencyOwnershipTests {
    private final class DiagnosisTranscript: TrustedTranscriptServicing {
        var calls = 0
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { calls += 1; return .init([]) }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init([]) }
    }

    private final class OfflineTransport: HTTPTransport {
        var requests: [URL] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let url = request.url { requests.append(url) }
            throw URLError(.notConnectedToInternet)
        }
    }

    @Test(.timeLimit(.minutes(1))) func settingsDestinationsPreserveTheirSelectedMediaAccountAndCleanupOwners() async throws {
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
            AppMedia.makeEnvironment(files: PreferenceMemoryFiles(), previewStorage: MediaPreviewStorage(files: PreferenceMemoryFiles()), defaults: defaults,
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
            messages: GalleryMessageReadStore(files: PreferenceMemoryFiles(), storageRoot: URL(fileURLWithPath: "/preference-sync"), defaults: firstDefaults, session: { account }),
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
        let updates = AppUpdatePromptCoordinator(settings: dependencies.settingsStore)
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        let destinations = AppCommunityDestinations(dependencies: dependencies, schedule: schedule, scheduleCloudSync: cloud, media: firstMedia,
            localData: AppLocalDataService(files: PreferenceMemoryFiles(), actions: effects.actions),
            school: NetworkDiagnosisSchool(identity: { .init(accountIdentifier: account.accountIdentifier, generation: 0) },
                currentTerm: { schoolCalls.append("term"); return "fixture" },
                syncCourses: { schoolCalls.append($0) }, ddl: { schoolCalls.append("ddl") }), transcript: transcript,
            updates: updates, prompts: prompts)
        let selected = destinations.settingsDependencies
        #expect(selected.settings === dependencies.settingsStore)
        #expect(selected.updates === updates && selected.prompts === prompts)
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
