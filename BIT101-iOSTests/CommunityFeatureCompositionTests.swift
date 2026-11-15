import ClientCore
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import DesignSystemKit
import Foundation
import Observation
import ScheduleDomain
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import StorageCore
import SwiftUI
import Testing
import TransportCore
import UIKit
import WebKit

@testable import BIT101_iOS
@testable import CourseFeature
@testable import GalleryFeature
@testable import MediaKit
@testable import MineFeature
@testable import PaperFeature
@testable import ScheduleFeature
@testable import ScoreFeature

extension FeatureCompositionTests {
    @Observable
    final class RootCallbackChanges {
        var revision = 0
        @ObservationIgnored var renderedRevision = -1
        @ObservationIgnored var handledRevision = -1
    }

    struct PaperWithChangingCallback: View {
        let changes: RootCallbackChanges
        let dependencies: PaperDependencies
        let media: MediaEnvironment
        var body: some View {
            let revision = changes.revision
            PaperRootView(
                dependencies: dependencies, media: media,
                onShowFeed: { changes.handledRevision = revision }
            )
            .onChange(of: revision, initial: true) { _, revision in
                changes.renderedRevision = revision
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rootDescriptionsDeferModelSubscriptions() async throws {
        let paperSource = paper(TraceTransport())
        let paperService = PaperPreviewService()
        defer {
            paperService.pending?.resume(
                returning: .init(authorName: "author", avatarURL: nil, isAnonymous: false))
        }
        let paperDependencies = PaperDependencies(
            list: paperService, detail: paperSource.detail, composer: paperSource.composer,
            drafts: paperSource.drafts, networkPath: paperSource.networkPath,
            currentIdentity: paperSource.currentIdentity)
        let gallerySource = gallery(TraceTransport())
        let galleryService = GalleryFeed()
        let galleryDependencies = GalleryDependencies(
            webCredentials: gallerySource.webCredentials,
            currentIdentity: gallerySource.currentIdentity, feed: galleryService,
            messageService: gallerySource.messageService, posterDetail: gallerySource.posterDetail,
            subscriptions: gallerySource.subscriptions, reporting: gallerySource.reporting,
            composer: gallerySource.composer, images: gallerySource.images,
            preferences: gallerySource.preferences, messages: gallerySource.messages,
            drafts: gallerySource.drafts, networkPath: gallerySource.networkPath)
        let selectedMedia = media()
        func galleryView() -> GalleryRootView {
            GalleryRootView(
                dependencies: galleryDependencies, media: selectedMedia,
                profiles: CommunityProfileDestination { _ in AnyView(Text("profile")) },
                papers: CommunityPaperDestination(
                    papers: { _, _ in AnyView(Text("paper")) },
                    detail: { _ in AnyView(Text("paper")) }),
                courses: CommunityCourseDestination { _ in AnyView(Text("course")) })
        }
        for _ in 0..<20 {
            _ = PaperRootView(dependencies: paperDependencies, media: selectedMedia)
            _ = galleryView()
        }
        #expect(paperService.resourcePublisherRequests == 0)
        #expect(galleryService.resourcePublisherRequests == 0)
        let changes = RootCallbackChanges()
        weak var renderedController: UIViewController?
        func waitForRevision(_ revision: Int) async throws {
            do {
                try await waitForTestEvent {
                    renderedController?.view.setNeedsLayout()
                    renderedController?.view.layoutIfNeeded()
                    return changes.renderedRevision == revision
                }
            } catch {
                let rendered = changes.renderedRevision
                let subscriptions = paperService.resourcePublisherRequests
                Issue.record(
                    """
                    revision=\(revision), rendered=\(rendered), subscriptions=\(subscriptions)
                    """)
                throw error
            }
        }
        try await host(
            PaperWithChangingCallback(
                changes: changes, dependencies: paperDependencies, media: selectedMedia),
            prepare: { renderedController = $0 }
        ) {
            try await waitForRevision(0)
            #expect(paperService.resourcePublisherRequests == PaperSortOrder.allCases.count)
            for revision in 1...10 {
                changes.revision = revision
                try await waitForRevision(revision)
            }
            #expect(paperService.resourcePublisherRequests == PaperSortOrder.allCases.count)
        }
        try await host(galleryView()) {
            #expect(galleryService.resourcePublisherRequests == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [ScheduleSection.courses, .ddl, .classroom])
    func scheduleRootOwnsItsConstructorViewModel(section: ScheduleSection) async throws {
        var selectedLoads = 0
        var surroundingLoads = 0
        var continuation: CheckedContinuation<Void, Never>?
        let term = "2026-2027-1"
        let course = CourseRecord(
            id: "composition-course", term: term, name: "composition-course", teacher: "fixture",
            classroom: "fixture",
            description: "", weeks: Array(1...20), weekday: 1, startSection: 1, endSection: 2,
            campus: "fixture", number: "fixture", credit: 1,
            hour: 16, type: "必修", category: "fixture", department: "fixture")
        var cache = ScheduleCache()
        cache.courseData.currentTerm = term
        cache.courseData.schedulesByTerm[term] = TermScheduleSnapshot(
            term: term, firstDayString: "2026-09-07", courses: [course], exams: [],
            updatedAt: Date())
        func viewModel(load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult)
            -> ScheduleViewModel
        {
            let repository = ScheduleRepository(
                session: { AppStorageSession(accountIdentifier: "composition") }, load: load,
                save: { _, _, _ in })
            let service = SemesterStartDateService()
            return ScheduleViewModel(
                service: service, repository: repository, ddlService: service,
                classroomService: service,
                platformActions: RecordingSchedulePlatformActions(),
                newCustomScheduleDraft: { CustomScheduleDraft() })
        }
        let selected = viewModel { _ in
            selectedLoads += 1
            continuation?.resume()
            continuation = nil
            return .loaded(cache)
        }
        let surrounding = viewModel { _ in
            surroundingLoads += 1
            return .missing
        }
        let destinations = ScheduleDestinations(
            appStoreURL: AppURL.required("https://example.invalid"),
            academicCourse: { _, _ in AnyView(Text("course")) }, openCourseLocation: { _ in true },
            resolveCourseShare: { _ in nil })
        try await host(
            ScheduleRootView(
                viewModel: selected, requestedSection: .constant(section),
                destinations: destinations
            )
            .environment(surrounding).environment(media())
        ) {
            if selectedLoads == 0 { await withCheckedContinuation { continuation = $0 } }
            try await waitForTestEvent { selected.isCacheWritable }
            #expect(selected.courseState.courses.map(\.id) == [course.id])
            #expect(selected.selectedSection == section)
        }
        #expect(selectedLoads > 0)
        #expect(surroundingLoads == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func paperDependencyReplacementObject() async throws {
        let first = TraceTransport()
        let second = TraceTransport()
        let selectedMedia = media()
        try await replace(
            PaperRootView(dependencies: paper(first), media: selectedMedia),
            with: PaperRootView(dependencies: paper(second), media: selectedMedia),
            firstTransport: first, secondTransport: second)
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryDependencyReplacementScene() async throws {
        let first = TraceTransport()
        let second = TraceTransport()
        let selectedMedia = media()
        let profiles = CommunityProfileDestination { AnyView(Text("profile \($0)")) }
        let papers = CommunityPaperDestination(
            papers: { _, _ in AnyView(Text("paper")) },
            detail: { AnyView(Text("paper \($0)")) })
        let courses = CommunityCourseDestination { AnyView(Text("course \($0)")) }
        try await replace(
            GalleryRootView(
                dependencies: gallery(first), media: selectedMedia, profiles: profiles,
                papers: papers, courses: courses),
            with: GalleryRootView(
                dependencies: gallery(second), media: selectedMedia, profiles: profiles,
                papers: papers, courses: courses),
            firstTransport: first, secondTransport: second, initialRequests: 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func courseLookupDependencyTask() async throws {
        let first = CourseList()
        let second = CourseList()
        let selectedMedia = media()
        let profiles = CommunityProfileDestination { AnyView(Text("profile \($0)")) }
        let request = CourseNavigationRequest.lookup(courseName: "课程", courseNumber: "COURSE-1")
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                CourseEvaluationDestination(
                    dependencies: dependencies(list: first), media: selectedMedia,
                    profiles: profiles, request: request)
            })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await first.waitForLookup()
        controller.rootView = NavigationStack {
            CourseEvaluationDestination(
                dependencies: dependencies(list: second), media: selectedMedia, profiles: profiles,
                request: request)
        }
        try await second.waitForLookup()
        #expect(first.requests.count == 2)
        #expect(Set(second.requests) == ["课程", "COURSE-1"])
    }
}
