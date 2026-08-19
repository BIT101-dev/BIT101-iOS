import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Schedule cache migration and reconciliation")
struct ScheduleCacheMigrationTests {
    private struct LegacyCache: Encodable {
        let primaryScheduleTitle: String
        let currentTerm: String
        let courses: [CourseRecord]
        let updatedAt: Date
    }

    @Test("Legacy single-term caches migrate without losing courses or timestamps")
    func legacyCacheMigration() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let course = makeCourse(id: "course-1", term: "2025-2026-1")
        let legacy = LegacyCache(
            primaryScheduleTitle: "  一份名字很长的课表  ",
            currentTerm: course.term,
            courses: [course],
            updatedAt: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(legacy))

        #expect(decoded.courses == [course])
        #expect(decoded.cachedCoursesByTerm[course.term] == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.updatedAt == timestamp)
        #expect(decoded.coursesUpdatedAt == timestamp)
        #expect(decoded.primaryScheduleTitle.count == scheduleNameCharacterLimit)
        #expect(decoded.iCloudSyncEnabled)
    }

    @Test("Reconciliation only applies a newer remote cache when allowed")
    func reconciliationPolicy() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)

        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .applyRemote)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: true
        ) == .uploadLocal)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: false
        ) == .noChange)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: new,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .noChange)
    }

    private func makeCourse(id: String, term: String) -> CourseRecord {
        CourseRecord(
            id: id,
            term: term,
            name: "高等数学",
            teacher: "张老师",
            classroom: "理教201",
            description: "",
            weeks: [1, 2],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "良乡",
            number: "MATH-1",
            credit: 4,
            hour: 64,
            type: "必修",
            category: "公共课",
            department: "数学学院"
        )
    }
}

@Suite("Free-classroom request lifecycle")
@MainActor
struct ScheduleClassroomCoordinatorTests {
    @Test("Only the newest request can finish shared loading state")
    func staleRequestsCannotFinish() {
        let coordinator = ScheduleClassroomCoordinator()
        let first = coordinator.beginRequest(hasVisibleResults: false)
        let second = coordinator.beginRequest(hasVisibleResults: false)

        #expect(first.shouldShowInitialSpinner)
        #expect(second.shouldShowInitialSpinner)
        #expect(!coordinator.finish(first.id))
        #expect(coordinator.isRequestInFlight)
        #expect(coordinator.finish(second.id))
        #expect(!coordinator.isRequestInFlight)
    }

    @Test("Automatic preparation and metadata refresh are single-flight")
    func oneTimeClaimsResetWithAccount() {
        let coordinator = ScheduleClassroomCoordinator()

        #expect(coordinator.claimAutomaticPreparation())
        #expect(!coordinator.claimAutomaticPreparation())
        let oldMetadataToken = coordinator.beginMetadataRefresh()
        #expect(oldMetadataToken != nil)
        #expect(coordinator.beginMetadataRefresh() == nil)

        coordinator.reset()
        #expect(coordinator.claimAutomaticPreparation())
        let newMetadataToken = coordinator.beginMetadataRefresh()
        #expect(newMetadataToken != nil)
        #expect(oldMetadataToken != newMetadataToken)
        #expect(!coordinator.isCurrentMetadataRefresh(oldMetadataToken!))
        #expect(coordinator.isCurrentMetadataRefresh(newMetadataToken!))
    }
}

@Suite("Schedule authentication continuation")
@MainActor
struct ScheduleCourseSyncCoordinatorTests {
    @Test("SMS authentication resumes the exact suspended operation")
    func continuationPurpose() {
        let coordinator = ScheduleCourseSyncCoordinator()

        coordinator.waitForCourseAuthentication(term: "2025-2026-2")
        #expect(coordinator.continuation == .courseSync(term: "2025-2026-2"))
        #expect(coordinator.courseSyncTerm == "2025-2026-2")

        coordinator.waitForAvailableTermsAuthentication()
        #expect(coordinator.continuation == .availableTerms)
        #expect(coordinator.courseSyncTerm == nil)

        coordinator.reset()
        #expect(coordinator.continuation == nil)
    }
}

@Suite("Gallery recommendation prefetch")
@MainActor
struct GalleryRecommendationPrefetchTests {
    private final class FeedServiceStub: GalleryFeedServicing {
        var batches: [Int: GalleryRecommendFeedBatch] = [:]
        private(set) var requestedRecommendPages: [Int] = []

        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [GalleryPoster] { [] }

        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch {
            requestedRecommendPages.append(sourcePage)
            guard let batch = batches[sourcePage] else {
                throw URLError(.resourceUnavailable)
            }
            return batch
        }

        func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch {
            GalleryBotFeedBatch(posters: [], nextSourcePage: startPage + 1, canLoadMore: false)
        }

        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [GalleryPoster] { [] }
    }

    @Test("Prefetched pages merge stably and never duplicate a source request")
    func stablePrefetchMerge() async throws {
        let service = FeedServiceStub()
        let first = try makePoster(id: 1)
        let second = try makePoster(id: 2)
        let third = try makePoster(id: 3)
        service.batches = [
            0: GalleryRecommendFeedBatch(posters: [first, first], nextSourcePage: 1, canLoadMore: true),
            1: GalleryRecommendFeedBatch(posters: [first, second], nextSourcePage: 2, canLoadMore: true),
            2: GalleryRecommendFeedBatch(posters: [second, third], nextSourcePage: 3, canLoadMore: true),
        ]
        let viewModel = GalleryViewModel(service: service)

        await viewModel.refresh(feed: .recommend)
        await waitUntil { service.requestedRecommendPages.contains(2) }

        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1])
        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: first)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2])

        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: second)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2, 3])
        #expect(service.requestedRecommendPages.filter { $0 == 1 }.count == 1)
        #expect(service.requestedRecommendPages.filter { $0 == 2 }.count == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    private func makePoster(id: Int) throws -> GalleryPoster {
        let json = """
        {
          "anonymous": false,
          "claim": { "id": 1, "text": "校园" },
          "comment_num": 0,
          "create_time": "2026-08-12T00:00:00Z",
          "edit_time": "2026-08-12T00:00:00Z",
          "id": \(id),
          "images": [],
          "like_num": 0,
          "public": true,
          "tags": [],
          "text": "内容 \(id)",
          "title": "标题 \(id)",
          "update_time": "2026-08-12T00:00:00Z",
          "user": {
            "id": 1,
            "create_time": "2026-08-12T00:00:00Z",
            "nickname": "测试用户",
            "avatar": { "mid": "avatar", "url": "", "low_url": "" },
            "motto": "",
            "identity": {
              "id": 1,
              "color": "#000000",
              "text": "用户",
              "create_time": "2026-08-12T00:00:00Z",
              "update_time": "2026-08-12T00:00:00Z",
              "delete_time": null
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GalleryPoster.self, from: Data(json.utf8))
    }
}
