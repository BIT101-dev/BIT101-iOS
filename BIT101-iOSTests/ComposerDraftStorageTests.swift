import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
import CommunityPersistence
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
@testable import BIT101_iOS

@Suite("Composer draft storage")
struct ComposerDraftStorageTests {
    @MainActor
    @Test func articleDraftsAndPendingPublicationsSurviveRecreationAndScopedCleanup() async throws {
        let files = PreferenceMemoryFiles(), owner = AppStorageSession(accountIdentifier: "draft-runtime")
        func store() -> ComposerDraftStore {
            .init(files: files, applicationSupport: URL(fileURLWithPath: "/draft-runtime"),
                session: { owner }, prepareImageData: { $0 })
        }
        let drafts = store()
        let original = PaperComposerDraftSnapshot(paperID: nil, baselineUpdatedAt: nil,
            title: "新文章", intro: "简介", content: "保留正文", anonymous: false)
        let editing = PaperComposerDraftSnapshot(paperID: 42, baselineUpdatedAt: "saved-version",
            title: "编辑文章", intro: "简介", content: "独立正文", anonymous: true)
        #expect(await drafts.savePaper(original))
        #expect(await drafts.savePaper(editing))
        let reopened = store()
        #expect((await reopened.loadPaper(paperID: nil)).snapshot == original)
        #expect((await reopened.loadPaper(paperID: 42)).snapshot == editing)
        let cleanup = await reopened.capturePaperCleanup(matching: original)
        #expect(await cleanup())
        #expect((await reopened.loadPaper(paperID: nil)).snapshot == nil)
        #expect((await reopened.loadPaper(paperID: 42)).snapshot == editing)
        let content = ComposerPublicationContent.paper(title: "待确认文章", intro: "简介", content: "正文", anonymous: false)
        let started = try await drafts.beginPublication(content, owner: owner.accountIdentifier)
        guard case .started(let attempt) = started else { Issue.record("首次发布应创建待确认记录"); return }
        #expect(try await reopened.loadPublication(kind: .paper, owner: owner.accountIdentifier) == attempt)
        #expect(try await reopened.finishPublication(attempt))
        #expect(try await drafts.loadPublication(kind: .paper, owner: owner.accountIdentifier) == nil)
        let recovery = await drafts.capturePaperRecovery()
        #expect(await recovery())
        #expect((await drafts.loadPaper(paperID: 42)).snapshot == editing)
    }

    @Test("Persisted image assets are bounded JPEG data")
    func persistedImageSizeAndEncoding() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let source = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }

        let persisted = try ComposerDraftImageCompressor.compress(source)
        #expect(persisted.count <= ComposerDraftImageCompressor.maximumBytes)
        #expect(UIImage(data: persisted) != nil)
    }
}
