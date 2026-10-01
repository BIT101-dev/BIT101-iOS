import BIT101TestSupport
import CommunityUI
import StorageCore
import CommunityCore
import Foundation
import Testing

@MainActor
struct CommunityCoreTests {
    @Test func communityImageDecodesExistingWireKeys() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let image = try decoder.decode(CommunityImage.self, from: Data(#"{"mid":"image","url":"https://example.invalid/image.gif","low_url":"https://example.invalid/thumbnail.jpg"}"#.utf8))
        #expect(image.id == "image")
        #expect(image.lowUrl.hasSuffix("thumbnail.jpg"))
        #expect(image.isGIF)
    }

    @Test func commentCopiesPreserveIdentityAndReplyTree() {
        let user = CommunityUser.placeholder(id: 42, nickname: "用户")
        let comment = CommunityComment(
            id: 17, obj: "course17", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 2, commentNum: 0,
            own: true, rate: 5, replyUser: user, replyObj: "", text: "评论", sub: []
        )
        let liked = comment.updatingLike(true, likeNum: 3)
        #expect(liked.id == comment.id)
        #expect(liked.obj == comment.obj)
        #expect(liked.text == comment.text)
        #expect(liked.user == user)
        #expect(liked.like && liked.likeNum == 3)
        let thread = comment.replacingSubComments([liked])
        #expect(thread.sub == [liked])
        #expect(thread.like == comment.like)
        var state = CommunityCommentState()
        state.applyFirstPage([thread])
        #expect(state.items == [thread])
        #expect(state.nextPage == 1)
        state.appendPage([])
        #expect(state.canLoadMore == false)
    }

    @Test func accountStorePreservesLegacyKeysAndSeparatesAccounts() throws {
        let suite = "BIT101ModulesTests.storage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var session = AppStorageSession(accountIdentifier: "module-a")
        defaults.set(try JSONEncoder().encode(["old-value"]), forKey: session.legacyKey("module-test"))
        let store = AccountScopedCodableStore<[String]>(keyPrefix: "module-test", defaults: defaults, sessionProvider: { session })
        #expect(store.load() == ["old-value"])
        #expect(defaults.data(forKey: session.legacyKey("module-test")) == nil)
        #expect(defaults.data(forKey: store.storageKey) != nil)
        session = AppStorageSession(accountIdentifier: "module-b")
        #expect(store.load() == nil)
        store.save(["account-b"])
        session = AppStorageSession(accountIdentifier: "module-a")
        #expect(store.load() == ["old-value"])
    }
}

@MainActor
struct ComposerPublicContractTests {
    private final class Account {
        var session = AppStorageSession(accountIdentifier: "composer-A")
    }
    @Test func imagePreparationAndStoredBytesFollowTheSelectedBackend() async throws {
        let files = ModuleScoreFiles()
        let session = AppStorageSession(accountIdentifier: "composer-A")
        let store = ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { session }, prepareImageData: { Data([42]) + $0 })
        let snapshot = DeveloperSuggestionDraftSnapshot(text: "draft", images: [
            ComposerImageDraftSnapshot(filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        ], contact: "contact")
        #expect(await store.saveSuggestion(snapshot))
        let restored = try #require(await store.loadSuggestion())
        #expect(restored.text == snapshot.text)
        #expect(restored.contact == snapshot.contact)
        #expect(restored.images.first?.uploadData == Data([42, 7]))
        #expect(restored.images.first?.previewData == Data([42, 7]))
        let url = URL(fileURLWithPath: "/module-composer/BIT101-iOS")
            .appending(path: session.accountStorageIdentifier).appending(path: "composer-suggestion.json")
        #expect(files.writingOptions(at: url)?.contains(.atomic) == true)
        files.setFailures(writing: true)
        #expect(await store.saveSuggestion(.init(text: "next", images: [])) == false)
        #expect(await store.loadSuggestion()?.text == "draft")
    }

    @Test func capturedCleanupMatchesTheAccountAndSavedRevision() async {
        let account = Account()
        let store = ComposerDraftStore(files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { account.session }, prepareImageData: { $0 })
        #expect(await store.saveSuggestion(.init(text: "A", images: [])))
        let cleanup = await store.captureSuggestionCleanup()
        account.session = AppStorageSession(accountIdentifier: "composer-B")
        #expect(await store.saveSuggestion(.init(text: "B", images: [])))
        await cleanup()
        #expect(await store.loadSuggestion()?.text == "B")
        account.session = AppStorageSession(accountIdentifier: "composer-A")
        #expect(await store.loadSuggestion() == nil)
        #expect(await store.saveSuggestion(.init(text: "submitted", images: [])))
        let oldCleanup = await store.captureSuggestionCleanup()
        #expect(await store.saveSuggestion(.init(text: "continued", images: [])))
        await oldCleanup()
        #expect(await store.loadSuggestion()?.text == "continued")
    }

    @Test func preparedImageSizeIsEnforcedAtTheStorageBoundary() async {
        let store = ComposerDraftStore(files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { AppStorageSession(accountIdentifier: "composer-A") },
            prepareImageData: { _ in Data(count: ComposerDraftImagePolicy.maximumBytes + 1) })
        #expect(await store.saveSuggestion(.init(text: "saved", images: [])))
        #expect(await store.saveSuggestion(.init(text: "oversized", images: [
            .init(filename: "image.jpg", previewData: Data([1]), uploadData: nil)
        ])) == false)
        #expect(await store.loadSuggestion()?.text == "saved")
    }
}
