import BIT101TestSupport
import Combine
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import Foundation
import StorageCore
import Testing
import TransportCore
import os

@testable import CourseFeature
@testable import GalleryFeature
@testable import MediaKit
@testable import MineFeature
@testable import PaperFeature

extension CommunityDependencyBoundaryTests {
    @Test(.timeLimit(.minutes(1)), .serialized, arguments: [false, true])
    func unreadWindowSurvivesInterruptedPaging(cancelled: Bool) async throws {
        let domain = "BIT101ModulesTests.message-interruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        let service = PagedMessageService()
        service.laterPageFailure = cancelled ? CancellationError() : URLError(.timedOut)
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 5 && service.cursors == [Int.max, 5])
        #expect(store.unreadCount(for: .comment) == 0)
        service.laterPageFailure = nil
        let reopened = GalleryMessageReadStore(
            files: files, storageRoot: URL(fileURLWithPath: "/messages"), defaults: defaults,
            session: { session })
        service.beforeAcknowledgement = { #expect(reopened.unreadCount(for: .comment) == 5) }
        let retry = GalleryMessageViewModel(service: service, readStore: reopened)
        await retry.bootstrapIfNeeded()
        #expect(retry.state(for: .comment).status == .loaded)
        #expect(service.unread == 0 && reopened.unreadCount(for: .comment) == 5)
    }

    @Test(
        .timeLimit(.minutes(1)), .serialized,
        arguments: [
            "before-first", "after-first", "during-confirm", "lost-confirm", "interrupted-recovery",
            "large-window", "large-recovery",
        ])
    func unreadWindowRecoversConcurrentArrivals(stage: String) async throws {
        let domain = "BIT101ModulesTests.message-recovery"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/messages")
        let service = PagedMessageService()
        let store = GalleryMessageReadStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        var saves = 0
        let saveObservation = store.localSaves.sink { _ in saves += 1 }
        defer { withExtendedLifetime(saveObservation) {} }
        if stage == "large-window" {
            service.unread = 2_000
            service.identifiers = Array((1...2_000).reversed())
        }
        if stage == "before-first" {
            service.beforeFirstPage = {
                service.identifiers.insert(7, at: 0)
                service.unread += 1
            }
        } else if stage == "after-first" {
            service.unread = 1
            service.identifiers = [100, 99]
            service.beforeUnreadSummary = {
                service.identifiers.insert(101, at: 0)
                service.unread += 1
            }
        } else if stage == "large-recovery" {
            service.beforeAcknowledgement = { service.identifiers = Array((1...2_000).reversed()) }
        } else if stage != "large-window" {
            service.beforeAcknowledgement = { service.identifiers = Array((1...12).reversed()) }
        }
        if stage == "lost-confirm" {
            service.acknowledgementFailure = URLError(.networkConnectionLost)
        }
        if stage == "interrupted-recovery" {
            service.postAcknowledgementFailure = URLError(.timedOut)
        }
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 0)
        if stage == "lost-confirm" || stage == "interrupted-recovery" {
            #expect(store.pendingUnreadAfterID(for: .comment) == 6)
            service.acknowledgementFailure = nil
            service.postAcknowledgementFailure = nil
            defaults.removePersistentDomain(forName: domain)
            let reopened = GalleryMessageReadStore(
                files: files, storageRoot: root, defaults: defaults, session: { session })
            let retry = GalleryMessageViewModel(service: service, readStore: reopened)
            await retry.bootstrapIfNeeded()
            #expect(
                reopened.unreadCount(for: .comment) == 11
                    && reopened.pendingUnreadAfterID(for: .comment) == nil)
            #expect(
                reopened.isUnread(id: 2, for: .comment) && reopened.isUnread(id: 7, for: .comment))
        } else {
            let expectedUnread: Int
            switch stage {
            case "large-window": expectedUnread = 2_000
            case "large-recovery": expectedUnread = 1_999
            case "before-first": expectedUnread = 6
            case "after-first": expectedUnread = 2
            default: expectedUnread = 11
            }
            #expect(store.unreadCount(for: .comment) == expectedUnread)
            #expect(
                store.isUnread(
                    id: stage == "large-window" ? 1 : stage == "after-first" ? 100 : 2,
                    for: .comment))
            if stage == "after-first" { #expect(!store.isUnread(id: 99, for: .comment)) }
            #expect(store.pendingUnreadAfterID(for: .comment) == nil)
            if stage == "large-recovery" { #expect(saves == 5) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func unavailableReadStorageKeepsServerUnread(damaged: Bool) async throws {
        let store = RecordingMessageReadStore()
        store.hasUnreadableSnapshot = damaged
        store.saveSucceeds = false
        let service = PagedMessageService()
        let model = GalleryMessageViewModel(service: service, readStore: store)
        await model.refreshUnreadCounts()
        await model.refresh(type: .comment)
        #expect(service.unread == 5 && !service.cursors.contains(nil))
        if damaged { #expect(service.cursors == [Int.max]) }
        #expect(
            model.state(for: .comment).status == .loaded
                && !model.state(for: .comment).items.isEmpty)
        #expect(model.alert?.title == "消息状态同步受阻")
        #expect(model.alert?.message.contains(damaged ? "读取失败" : "保存失败") == true)
        model.alert = nil
        await model.markMessageAsRead(
            try #require(RecordingMessageService.messages([42]).first), in: .comment)
        #expect(model.alert?.title == "保存消息状态失败")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["paper", "course"])
    func messageNavigationKeepsTheResourceKind(kind: String) async throws {
        let model = GalleryMessageViewModel(
            service: RecordingMessageService(), readStore: RecordingMessageReadStore())
        let details = SuspendedMessageDetails()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(
            GalleryMessage.self,
            from: Data(
                """
                {\"id\":42,\"from_user\":{},\"link_obj\":\"\(kind)42\",\"obj\":\"\(kind)42\",\"\
                text\":\"更新\",\"update_time\":\"\"}
                """
                .utf8))
        await model.openMessage(message, in: .comment, using: details)
        #expect(model.destination == (kind == "paper" ? .paper(42) : .course(42)))
        #expect(details.pending.isEmpty)
        #expect(
            GalleryMessageType.comment.actionText(for: message)
                == (kind == "paper" ? "评论了你的文章" : "评论了你的课程"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["replacement", "cancel", "account", "error"])
    func messageNavigationKeepsLatestIntent(boundary: String) async throws {
        let store = RecordingMessageReadStore()
        let model = GalleryMessageViewModel(service: RecordingMessageService(), readStore: store)
        let details = SuspendedMessageDetails()
        let messages = try RecordingMessageService.messages([1, 2])
        let first = Task { await model.openMessage(messages[0], in: .comment, using: details) }
        try await waitForTestEvent { !(details.pending[1] == nil) }
        if boundary == "replacement" {
            let second = Task { await model.openMessage(messages[1], in: .comment, using: details) }
            try await waitForTestEvent { !(details.pending[2] == nil) }
            details.pending.removeValue(forKey: 2)?.resume(returning: details.poster(2))
            await second.value
        } else if boundary == "cancel" {
            first.cancel()
        } else if boundary == "account" {
            store.currentSession = AppStorageSession(accountIdentifier: "replacement")
        }
        let failure = URLError(.notConnectedToInternet)
        if boundary == "error" {
            details.pending.removeValue(forKey: 1)?.resume(throwing: failure)
        } else {
            details.pending.removeValue(forKey: 1)?.resume(returning: details.poster(1))
        }
        await first.value
        let resolvedID: Int?
        if case .poster(let poster) = model.destination {
            resolvedID = poster.id
        } else {
            resolvedID = nil
        }
        #expect(resolvedID == (boundary == "replacement" ? 2 : nil))
        #expect(model.alert?.message == (boundary == "error" ? failure.localizedDescription : nil))
    }

    @Test(.timeLimit(.minutes(1))) func courseEvaluationFactoryUsesInjectedService() async throws {
        let list = RecordingCourseList()
        let dependencies = CourseDependencies(
            list: list, detail: CourseService(session: session), preferences: preferences,
            networkPath: .init(), loadCourseCredits: { [] }
        )
        let result = try await dependencies.makeEvaluationResolver().resolve(
            courseName: "高等数学", courseNumber: "MATH")
        #expect(result == nil)
        #expect(Set(list.requests) == ["MATH", "高等数学"])
    }

    @Test(.timeLimit(.minutes(1))) func automaticCourseLookupStopsAtBudget() async throws {
        let service = LargeCourseLookup()
        do {
            _ = try await CourseEvaluationResolver(service: service).resolve(
                courseName: "课程", courseNumber: "")
            Issue.record("自动消歧达到候选容量后应提示使用课程搜索")
        } catch {
            #expect(error.localizedDescription.contains("课程搜索"))
            #expect(service.pages == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func automaticCourseLookupCancelsInSearches() async throws {
        let service = PageAdvancementService()
        service.suspendedCourseSearches = ["number", "name"]
        let entered = OSAllocatedUnfairLock(initialState: false)
        let lookup = CourseEvaluationResolver(
            service: service,
            waitForDeadline: { _ in
                while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
            })
        let task = Task { try await lookup.resolve(courseName: "name", courseNumber: "number") }
        defer { task.cancel() }
        try await waitForTestEvent { service.enteredCourseSearches == ["number", "name"] }
        entered.withLock { $0 = true }
        do {
            _ = try await task.value
            Issue.record("检索总时限需要结束两路在途请求")
        } catch {
            #expect(error.localizedDescription.contains("课程搜索"))
            #expect(service.cancelledCourseSearches == ["number", "name"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func galleryFeedUsesTheInjectedSceneService() async {
        let feed = RecordingGalleryFeed()
        let viewModel = GalleryViewModel(service: feed)
        await viewModel.refresh(feed: .newest)

        #expect(feed.requests == [.newest])
        #expect(viewModel.state(for: .newest).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1))) func galleryMessagesUseIndependentReadPorts() async throws {
        let store = RecordingMessageReadStore()
        let otherStore = RecordingMessageReadStore()
        let model = GalleryMessageViewModel(service: RecordingMessageService(), readStore: store)
        let refreshes = ObservationCounter { _ = model.totalUnreadCount }
        otherStore.changeSubject.send(store.currentSession)
        store.changeSubject.send(AppStorageSession(accountIdentifier: "other-account"))
        await refreshes.settle()
        #expect(refreshes.count == 0)
        store.changeSubject.send(store.currentSession)
        await refreshes.settle()
        #expect(refreshes.count == 1)
        #expect(model.unreadCount(for: .comment) == 7)
        await model.refresh(type: .comment)
        #expect(store.latestIDs.isEmpty)
        await model.markCurrentTypeAsRead()
        #expect(store.seenIDs == [42])
        #expect(otherStore.seenIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["newer", "list", "cancel"])
    func unreadSummaryRejectsLateResponses(boundary: String) async throws {
        let service = DelayedUnreadService()
        let store = RecordingMessageReadStore()
        store.unread = 0
        let model = GalleryMessageViewModel(service: service, readStore: store)
        let old = Task { await model.refreshUnreadCounts() }
        try await waitForTestEvent { !(service.pending == nil) }
        service.delay = false
        switch boundary {
        case "newer": await model.refreshUnreadCounts()
        case "list": await model.refresh(type: .comment)
        default: old.cancel()
        }
        service.pending?.resume(returning: .init(comment: 9))
        await old.value
        #expect(model.unreadCounts.comment == 0)
        #expect(model.totalUnreadCount == 0)
        #expect(model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1))) func courseListAndCreditQueryUseInjections() async {
        let detail = CourseService(session: session)
        let list = RecordingCourseList()
        let dependencies = CourseDependencies(
            list: list, detail: detail, preferences: preferences,
            networkPath: .init(),
            loadCourseCredits: { [CommunityCourseCredit(number: "MATH", name: "高等数学", credit: 3)] }
        )
        let viewModel = dependencies.makeListViewModel()
        await viewModel.search(for: "高等数学")
        let credits = await dependencies.loadCourseCredits()

        #expect(list.requests == ["高等数学"])
        #expect(viewModel.state.status == .loaded)
        #expect(credits.map(\.number) == ["MATH"])
        #expect(credits.map(\.credit) == [3])
    }

    @Test(.timeLimit(.minutes(1))) func paperListAndUseSeparateSceneServices() async throws {
        let detail = PaperService(session: session)
        let list = RecordingPaperList()
        let composer = RecordingPaperComposer()
        let dependencies = PaperDependencies(
            list: list, detail: detail, composer: composer,
            drafts: ComposerDraftStore(
                files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/paper-draft"),
                session: { AppStorageSession(accountIdentifier: "test-account") },
                prepareImageData: { $0 }),
            networkPath: NetworkPathState(snapshot: NetworkPathSnapshot(status: .connected)),
            currentIdentity: { self.session.currentCredentials.identity })
        let viewModel = PaperListViewModel(service: dependencies.list)
        await viewModel.refresh()
        let id = try await dependencies.composer.createPaper(
            title: "标题", intro: "简介", content: "正文", anonymous: false, publicEdit: true
        )
        try await dependencies.composer.updatePaper(
            id: id, title: "编辑标题", intro: "简介", content: "编辑正文", anonymous: true, publicEdit: false,
            lastUpdatedAt: "2026-10-01T08:00:00Z"
        )

        #expect(list.requests == 1)
        #expect(viewModel.state.status == .loaded)
        #expect(composer.createdTitles == ["标题"])
        #expect(composer.updatedIDs == [42])
        #expect(composer.publicEditValues == [true, false])
    }

    @Test(.timeLimit(.minutes(1))) func mineOverviewPreservesInjectedSemantics() async {
        let overview = RecordingMineOverview()
        let dependencies = MineDependencies(
            overview: overview,
            profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { _ in }, networkPath: .init(snapshot: .init(status: .connected))
        )
        let viewModel = MineViewModel(service: dependencies.overview)
        await viewModel.bootstrapIfNeeded()

        #expect(overview.requests == 1)
        #expect(viewModel.profileStatus == .idle)
        #expect(viewModel.alert == nil)
        await viewModel.bootstrapIfNeeded()
        #expect(overview.requests == 2)
    }

    @Test(.timeLimit(.minutes(1))) func mineDeletionUsesItsInjectedBusinessAction() async throws {
        var deletedIDs: [Int] = []
        let dependencies = MineDependencies(
            overview: RecordingMineOverview(),
            profile: MineService(session: session, preferences: { self.preferences.snapshot }),
            deletePoster: { deletedIDs.append($0) },
            networkPath: .init(snapshot: .init(status: .connected))
        )
        try await dependencies.deletePoster(42)
        #expect(deletedIDs == [42])
    }

    @Test func mediaProjectionPreservesOriginalThumbnail() throws {
        let original = "https://example.com/original.png"
        let thumbnail = "https://example.com/thumbnail.png"
        let images = [
            CommunityImage(mid: "both", url: original, lowUrl: thumbnail),
            CommunityImage(mid: "original", url: original, lowUrl: ""),
            CommunityImage(mid: "thumbnail", url: "", lowUrl: thumbnail),
        ]
        let projected = images.map(\.previewImage)
        #expect(projected[0].originalURL == URL(string: original))
        #expect(projected[0].thumbnailURL == URL(string: thumbnail))
        #expect(projected[1].originalURL == projected[1].thumbnailURL)
        #expect(projected[2].originalURL == projected[2].thumbnailURL)

    }
}
