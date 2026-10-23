import BIT101TestSupport
import CommunityCore
import CommunityPersistence
import Foundation
import StorageCore
import Testing

@MainActor
struct PaperComposerDraftTests {
    @Test(.timeLimit(.minutes(1))) func capturedRecoveryPreservesALaterAccountsArchive() async throws {
        let files = ModuleScoreFiles(), account = Account()
        let drafts = store(files, session: { account.session })
        #expect(await drafts.savePaper(snapshot(content: "原账号")))
        let original = try #require(files.storedData.keys.first { $0.lastPathComponent == "composer-paper.json" })
        let damaged = Data("{".utf8)
        try files.writeData(damaged, to: original, options: [])
        let recovery = await drafts.capturePaperRecovery()
        account.session = AppStorageSession(accountIdentifier: "B")
        #expect(await drafts.savePaper(snapshot(content: "当前账号")))
        let current = try #require(files.storedData.keys.first { $0 != original && $0.lastPathComponent == "composer-paper.json" })
        let bytes = try files.readData(at: current)
        #expect(await recovery() == false)
        #expect(files.storedData[original] == damaged && files.storedData[current] == bytes)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func confirmedRecoveryKeepsReadableDraftsAndOtherAccounts(brokenRoot: Bool) async throws {
        let files = ModuleScoreFiles(), account = Account()
        let drafts = store(files, session: { account.session })
        let good = snapshot(1, content: "保留的草稿")
        #expect(await drafts.savePaper(good))
        #expect(await drafts.savePaper(snapshot(2, content: "待恢复")))
        let url = try #require(files.storedData.keys.first { $0.lastPathComponent == "composer-paper.json" })
        account.session = AppStorageSession(accountIdentifier: "B")
        #expect(await drafts.savePaper(snapshot(content: "其他账号")))
        let other = try #require(files.storedData.keys.first { $0 != url && $0.lastPathComponent == "composer-paper.json" })
        let otherBytes = try files.readData(at: other)
        account.session = AppStorageSession(accountIdentifier: "A")
        var root = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        var entries = try #require(root["entries"] as? [String: Any])
        entries["paper:2"] = ["content": 7]
        root["entries"] = entries
        let damaged = brokenRoot ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: root)
        try files.writeData(damaged, to: url, options: [])
        #expect((await drafts.loadPaper(paperID: 2)).allowsWrite == false)
        #expect(await drafts.savePaper(snapshot(2, content: "当前编辑")) == false)
        #expect(try files.readData(at: url) == damaged)
        let recovery = await drafts.capturePaperRecovery()
        #expect(await recovery())
        #expect((await drafts.loadPaper(paperID: 1)).snapshot == (brokenRoot ? nil : good))
        #expect(try files.readData(at: other) == otherBytes)
        let current = snapshot(2, content: "当前编辑")
        #expect(await drafts.savePaper(current))
        #expect((await drafts.loadPaper(paperID: 2)).snapshot == current)
    }

    @Test(.timeLimit(.minutes(1))) func recoveryPreservesAnAlreadyReadableArchive() async throws {
        let files = ModuleScoreFiles(), drafts = store(files, session: { .init(accountIdentifier: "A") })
        #expect(await drafts.savePaper(snapshot(content: "可读新版本")))
        let url = try #require(files.storedData.keys.first { $0.lastPathComponent == "composer-paper.json" })
        let original = try files.readData(at: url)
        let recovery = await drafts.capturePaperRecovery()
        #expect(await recovery())
        #expect(try files.readData(at: url) == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func damagedSiblingKeepsReadableDraftsAvailable(identityMismatch: Bool) async throws {
        let files = ModuleScoreFiles(), drafts = store(files, session: { .init(accountIdentifier: "A") })
        let good = snapshot(1, content: "可读草稿")
        #expect(await drafts.savePaper(good))
        #expect(await drafts.savePaper(snapshot(2, content: "待恢复草稿")))
        let url = try #require(files.storedData.keys.first { $0.lastPathComponent == "composer-paper.json" })
        var root = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        var entries = try #require(root["entries"] as? [String: Any])
        var bad = try #require(entries[identityMismatch ? "paper:1" : "paper:2"] as? [String: Any])
        if !identityMismatch { bad["content"] = 7 }
        entries["paper:2"] = bad
        root["entries"] = entries
        let original = try JSONSerialization.data(withJSONObject: root)
        try files.writeData(original, to: url, options: [])
        #expect((await drafts.loadPaper(paperID: 1)).snapshot == good)
        #expect(try files.readData(at: url) == original)
        let updated = snapshot(1, content: "继续编辑")
        #expect(await drafts.savePaper(updated))
        let saved = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        let retained = try #require(saved["entries"] as? [String: Any])
        #expect(retained["paper:2"] as? NSDictionary == bad as NSDictionary)
        let cleanup = await drafts.capturePaperCleanup(matching: updated)
        #expect(await cleanup())
        #expect((await drafts.loadPaper(paperID: 1)).snapshot == nil)
        #expect((await drafts.loadPaper(paperID: 2)).allowsWrite == false)
    }

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
        let blockedRecovery = await drafts.capturePaperRecovery()
        #expect(await blockedRecovery() == false)
        #expect(try files.readData(at: url) == original)
        files.setFailures()
        let future = Data(#"{"schemaVersion":2,"entries":{}}"#.utf8)
        try files.writeData(future, to: url, options: .atomic)
        #expect(await drafts.savePaper(snapshot(content: "待保存")) == false)
        let futureRecovery = await drafts.capturePaperRecovery()
        #expect(await futureRecovery() == false)
        let loaded = await drafts.loadPaper(paperID: nil)
        if case .unsupportedVersion(2) = loaded {} else { Issue.record("较新草稿格式需要保留恢复入口。") }
        #expect(try files.readData(at: url) == future)
    }
}
