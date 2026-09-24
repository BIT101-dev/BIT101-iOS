import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Gallery hidden user policy")
struct GalleryContentFilterTests {
    @Test("Hiding a user also hides replies targeting that user")
    func hidesReplyTarget() {
        let hiddenIDs: Set<Int> = [42]

        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 42,
            replyTargetID: 8,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 42,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
    }

    @Test("Anonymous filtering remains an independent preference")
    func keepsAnonymousContentWhenPreferenceIsOff() {
        #expect(!GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: true
        ))
    }
}

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

    @Test("Legacy cache migration preserves row-specific negative weeks")
    func rowSpecificNegativeWeeksSurviveCacheDecoding() throws {
        let course = CourseRecord(
            id: "negative-row",
            term: "2026-2027-1",
            name: "文献检索",
            teacher: "",
            classroom: "文萃楼M227",
            description: "-2周 星期二 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227",
            weeks: [-1],
            weekday: 4,
            startSection: 6,
            endSection: 9,
            campus: "",
            number: "100960001",
            credit: 1,
            hour: 16,
            type: "",
            category: "",
            department: ""
        )
        var cache = ScheduleCache()
        cache.storedCourseScheduleParserVersion = 1
        cache.currentTerm = course.term
        cache.courses = [course]
        cache.cachedCoursesByTerm[course.term] = [course]
        cache.termSchedulesByTerm[course.term] = TermScheduleSnapshot(
            term: course.term,
            firstDayString: "2026-08-31",
            courses: [course],
            exams: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(cache))

        #expect(decoded.courses.first?.weeks == [-1])
        #expect(decoded.cachedCoursesByTerm[course.term]?.first?.weeks == [-1])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses.first?.weeks == [-1])
    }

    @Test("DDL sync timestamp survives cache encoding")
    func ddlUpdatedAtRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        var cache = ScheduleCache()
        cache.ddlUpdatedAt = timestamp

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(cache))
        #expect(decoded.ddlUpdatedAt == timestamp)
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
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: false
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

    @Test("Authentication time is outside the classroom request deadline")
    func authenticationUsesIndependentDeadline() async throws {
        let coordinator = ScheduleClassroomCoordinator(timeoutNanoseconds: 5_000_000)
        let value = try await coordinator.withAuthenticationThenTimeout {
            try await Task.sleep(for: .milliseconds(20))
        } operation: {
            42
        }

        #expect(value == 42)
    }

    @Test("Classroom operation timeout remains enforced after authentication")
    func operationTimeoutIsEnforced() async {
        let coordinator = ScheduleClassroomCoordinator(timeoutNanoseconds: 5_000_000)

        do {
            _ = try await coordinator.withAuthenticationThenTimeout {
            } operation: {
                try await Task.sleep(for: .milliseconds(20))
                return 42
            }
            Issue.record("空教室请求超时契约失败")
        } catch is ClassroomRequestTimeoutError {
        } catch {
            Issue.record("空教室请求错误：\(error)")
        }
    }
}

@Suite("Schedule authentication continuation")
@MainActor
struct ScheduleCourseSyncCoordinatorTests {
    @Test("Classroom SMS authentication has an explicit continuation")
    func classroomAuthenticationContinuation() {
        let coordinator = ScheduleCourseSyncCoordinator()

        coordinator.waitForClassroomAuthentication()

        #expect(coordinator.continuation == .classroomRefresh)
        #expect(coordinator.courseSyncTerm == nil)
    }

    @Test("Authentication state records the suspended operation")
    func recordsContinuationPurpose() {
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
        private let batches: [Int: GalleryRecommendFeedBatch]
        private let requestLog = RequestLog()

        init(batches: [Int: GalleryRecommendFeedBatch] = [:]) {
            self.batches = batches
        }

        func requestedPages() async -> [Int] {
            await requestLog.snapshot()
        }

        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [GalleryPoster] { [] }

        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch {
            await requestLog.append(sourcePage)
            await Task.yield()
            guard let batch = batches[sourcePage] else {
                throw URLError(.resourceUnavailable)
            }
            return batch
        }

        func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch {
            GalleryBotFeedBatch(posters: [], nextSourcePage: startPage + 1, canLoadMore: false)
        }

        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [GalleryPoster] { [] }

        private actor RequestLog {
            private var pages: [Int] = []

            func append(_ page: Int) {
                pages.append(page)
            }

            func snapshot() -> [Int] {
                pages
            }
        }
    }

    @Test("Prefetched pages merge stably and never duplicate a source request")
    func stablePrefetchMerge() async throws {
        let first = try makePoster(id: 1)
        let second = try makePoster(id: 2)
        let third = try makePoster(id: 3)
        let service = FeedServiceStub(batches: [
            0: GalleryRecommendFeedBatch(posters: [first, first], nextSourcePage: 1, canLoadMore: true),
            1: GalleryRecommendFeedBatch(posters: [first, second], nextSourcePage: 2, canLoadMore: true),
            2: GalleryRecommendFeedBatch(posters: [second, third], nextSourcePage: 3, canLoadMore: true),
        ])
        let viewModel = GalleryViewModel(service: service)

        await viewModel.refresh(feed: .recommend)
        #expect(await waitUntil {
            await service.requestedPages().contains(2)
        })

        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1])
        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: first)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2])

        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: second)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2, 3])
        let requestedPages = await service.requestedPages()
        #expect(requestedPages.filter { $0 == 0 }.count == 1)
        #expect(requestedPages.filter { $0 == 1 }.count == 1)
        #expect(requestedPages.filter { $0 == 2 }.count == 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
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
