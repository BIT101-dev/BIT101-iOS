import BIT101TestSupport
import CommunityCore
import CommunityPersistence
import Foundation
import StorageCore
import Testing

@MainActor
struct PaperComposerDraftTests {
    @MainActor private final class Account {
        var session = AppStorageSession(accountIdentifier: "A")
    }
    private func snapshot(_ id: Int? = nil, content: String) -> PaperComposerDraftSnapshot {
        .init(paperID: id, baselineUpdatedAt: id == nil ? nil : "saved-version", title: "草稿",
              intro: "简介", content: content, anonymous: true)
    }

    private func store(_ files: ModuleScoreFiles, session: @escaping @MainActor @Sendable () -> AppStorageSession) -> ComposerDraftStore {
        .init(files: files, applicationSupport: URL(fileURLWithPath: "/paper-drafts"), session: session, prepareImageData: { $0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func draftsSurviveStoreRecreationAndKeepAccountAndArticleScopes() async {
        let files = ModuleScoreFiles()
        let account = Account()
        let drafts = store(files, session: { account.session })
        let first = snapshot(content: "新文章"), edit = snapshot(1, content: "编辑文章")
        #expect(await drafts.savePaper(first))
        #expect(await drafts.savePaper(edit))
        let cleanup = await drafts.capturePaperCleanup(matching: first)
        let restored = await store(files, session: { account.session }).loadPaper(paperID: 1)
        #expect(restored.snapshot == edit)
        account.session = AppStorageSession(accountIdentifier: "B")
        #expect((await drafts.loadPaper(paperID: nil)).snapshot == nil)
        let second = snapshot(content: "账号 B")
        #expect(await drafts.savePaper(second))
        #expect(await cleanup())
        #expect((await drafts.loadPaper(paperID: nil)).snapshot == second)
        account.session = AppStorageSession(accountIdentifier: "A")
        #expect((await drafts.loadPaper(paperID: nil)).snapshot == nil)
        #expect((await drafts.loadPaper(paperID: 1)).snapshot == edit)
        #expect(files.storedData.keys.filter { $0.lastPathComponent == "composer-paper.json" }.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentStoresAndSubmittedCleanupPreserveNewerDrafts() async {
        let files = ModuleScoreFiles()
        let first = store(files, session: { .init(accountIdentifier: "A") })
        let second = store(files, session: { .init(accountIdentifier: "A") })
        async let savedOne = first.savePaper(snapshot(1, content: "第一篇"))
        async let savedTwo = second.savePaper(snapshot(2, content: "第二篇"))
        let saved = await (savedOne, savedTwo)
        #expect(saved.0 && saved.1)
        #expect((await first.loadPaper(paperID: 1)).snapshot?.content == "第一篇")
        #expect((await first.loadPaper(paperID: 2)).snapshot?.content == "第二篇")
        let cleanup = await first.capturePaperCleanup(matching: snapshot(1, content: "第一篇"))
        #expect(await second.savePaper(snapshot(1, content: "继续编辑")))
        #expect(await cleanup())
        #expect((await first.loadPaper(paperID: 1)).snapshot?.content == "继续编辑")
    }

    @Test(.timeLimit(.minutes(1)))
    func futureFormatsAndStorageFailuresKeepTheOriginalBytes() async throws {
        let files = ModuleScoreFiles(), drafts = store(files, session: { .init(accountIdentifier: "A") })
        #expect(await drafts.savePaper(snapshot(content: "已保存")))
        let url = try #require(files.storedData.keys.first { $0.lastPathComponent == "composer-paper.json" })
        let original = try files.readData(at: url)
        files.setFailures(protection: true)
        #expect(await drafts.savePaper(snapshot(content: "待保存")) == false)
        #expect(try files.readData(at: url) == original)
        files.setFailures()
        let future = Data(#"{"schemaVersion":2,"entries":{}}"#.utf8)
        try files.writeData(future, to: url, options: .atomic)
        #expect(await drafts.savePaper(snapshot(content: "待保存")) == false)
        let loaded = await drafts.loadPaper(paperID: nil)
        if case .unsupportedVersion(2) = loaded {} else { Issue.record("较新草稿格式需要保留恢复入口。") }
        #expect(try files.readData(at: url) == future)
    }
}
