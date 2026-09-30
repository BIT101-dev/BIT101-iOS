import Foundation
import GalleryFeature
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct SuggestionDependencyTests {
    private func store(_ files: PreferenceMemoryFiles) -> ComposerDraftStore {
        ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/preference-sync"),
                           session: { AppStorageSession(accountIdentifier: "suggestion-test") })
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
        var session = AppStorageSession(accountIdentifier: "A")
        let drafts = ComposerDraftStore(files: PreferenceMemoryFiles(), applicationSupport: URL(fileURLWithPath: "/preference-sync"), session: { session })
        #expect(await drafts.saveSuggestion(.init(text: "A draft", images: [])))
        session = AppStorageSession(accountIdentifier: "B")
        #expect(await drafts.saveSuggestion(.init(text: "B draft", images: [])))
        session = AppStorageSession(accountIdentifier: "A")
        let dependencies = DeveloperSuggestionDependencies(drafts: drafts, submit: { _ in
            session = AppStorageSession(accountIdentifier: "B")
        })
        try await dependencies.submitAndClear(payload())
        #expect(await drafts.loadSuggestion()?.text == "B draft")
        session = AppStorageSession(accountIdentifier: "A")
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
