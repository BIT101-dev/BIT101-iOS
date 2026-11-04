import ClientCore
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import DesignSystemKit
import Foundation
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

@Suite("Schedule academic course matching")
@MainActor
struct CourseLookupMatcherTests {
    private final class ServiceStub: CourseListServicing {
        let results: [String: [CourseSummary]]
        var laterPages: [Int: [CourseSummary]] = [:]
        var repeatsFirstPage = false
        private var searches: [String] = []

        init(results: [String: [CourseSummary]]) {
            self.results = results
        }

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            searches.append(search)
            return page == 0 || repeatsFirstPage ? results[search] ?? [] : laterPages[page] ?? []
        }

        func recordedSearches() -> [String] {
            searches
        }
    }

    @Test("Course number matching ignores formatting differences")
    func matchesCourseNumber() {
        let expected = makeSummary(id: 1, name: "高等数学", number: "MATH-1001", teacher: "张老师")
        let other = makeSummary(id: 2, name: "高等数学", number: "MATH-1002", teacher: "张老师")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: " math 1001 ",
                courseName: "", teacher: "",
                candidates: [other, expected]
            )?.id == expected.id)
    }

    @Test func completeTeacherGroupsPrecedePartialMatches() {
        let partial = makeSummary(id: 1, name: "课程", number: "C1", teacher: "张、李")
        let complete = makeSummary(id: 2, name: "课程", number: "C1", teacher: "李、王")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "C1", courseName: "课程", teacher: "李、王",
                candidates: [partial, complete])?.id == 2)
        let another = makeSummary(id: 3, name: "课程", number: "C1", teacher: "王、赵")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "C1", courseName: "课程", teacher: "李、王",
                candidates: [partial, another]) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func resolverReadsPagesPreservesNumberQueryPage() async throws {
        let first = makeSummary(id: 1, name: "课程", number: "C1", teacher: "张")
        let second = makeSummary(id: 2, name: "课程", number: "C1", teacher: "王")
        let expected = makeSummary(id: 3, name: "课程", number: "C1", teacher: "李")
        let service = ServiceStub(results: ["C1": [first, second]])
        service.laterPages[1] = [expected]
        let result = try #require(
            await CourseEvaluationResolver(service: service).resolve(
                courseName: "", courseNumber: "C1", teacher: "李"))
        #expect(result.selectedCourse.id == 3 && result.searchQuery == "C1")
        #expect(result.searchResults.map(\.id) == [3, 1, 2])
        service.repeatsFirstPage = true
        do {
            _ = try await CourseEvaluationResolver(service: service).resolve(
                courseName: "", courseNumber: "C1", teacher: "李")
            Issue.record("重复后页需要保留首屏和协议错误")
        } catch {
            let recovery = try #require(error as? CourseEvaluationSearchRecovery)
            #expect(recovery.items.map(\.id) == [1, 2])
            #expect((recovery.underlying as? URLError)?.code == .badServerResponse)
        }
    }

    @Test("Teacher disambiguates courses with the same name")
    func disambiguatesByTeacher() {
        let first = makeSummary(id: 1, name: "大学物理", number: "PHY-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "大学物理", number: "PHY-2", teacher: "李老师")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "",
                courseName: "大学 物理",
                teacher: "李老师",
                candidates: [first, second]
            )?.id == second.id)
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "",
                courseName: "大学物理",
                teacher: "",
                candidates: [first, second]
            ) == nil)
    }

    @Test("Teacher also disambiguates records sharing one course number")
    func disambiguatesSameNumberByTeacher() {
        let first = makeSummary(id: 1, name: "线性代数", number: "MATH-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "线性代数", number: "MATH-1", teacher: "李老师、王老师")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "MATH-1",
                courseName: "",
                teacher: "李老师",
                candidates: [first, second]
            )?.id == second.id)
    }

    @Test("Records with the same course identity and an empty teacher open successfully")
    func resolvesSameIdentityWithoutTeacher() {
        let first = makeSummary(id: 1, name: "线性代数", number: "MATH-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "线性代数", number: "MATH-1", teacher: "李老师")
        #expect(
            CourseLookupMatcher.bestMatch(
                courseNumber: "MATH-1",
                courseName: "线性代数",
                teacher: "",
                candidates: [first, second]
            )?.id == first.id)
    }

    @Test(
        "Evaluation lookup searches both identity fields and normalizes punctuation",
        .timeLimit(.minutes(1)))
    @MainActor
    func evaluationLookupFallsBackToCourseName() async throws {
        let expected = makeSummary(
            id: 7,
            name: "自动控制理论II（双语）",
            number: "AUTO-1",
            teacher: ""
        )
        let service = ServiceStub(results: [
            "AUTO 1": [],
            "自动控制理论II(双语)": [expected],
        ])

        let result = try #require(
            await CourseEvaluationResolver(service: service).resolve(
                courseName: "自动控制理论II(双语)",
                courseNumber: "AUTO 1"
            ))

        #expect(result.selectedCourse.id == expected.id)
        #expect(result.searchQuery == "自动控制理论II(双语)")
        #expect(result.searchResults.map(\.id) == [expected.id])
        let searches = service.recordedSearches()
        #expect(Set(searches) == ["AUTO 1", "自动控制理论II(双语)"])
    }

    @Test("Unknown evaluation course resolves to a failure result", .timeLimit(.minutes(1)))
    @MainActor
    func evaluationLookupReturnsNil() async throws {
        let service = ServiceStub(results: [:])
        let result = try await CourseEvaluationResolver(service: service).resolve(
            courseName: "不存在的课程",
            courseNumber: "UNKNOWN-1"
        )
        #expect(result == nil)
    }

    @Test(
        "Resolver queries both identities while selecting the current teacher",
        .timeLimit(.minutes(1)))
    @MainActor
    func resolvesBothIdentitiesAndSelectsTeacher() async throws {
        let first = makeSummary(id: 1, name: "大学物理", number: "PHY-1", teacher: "张老师")
        let second = makeSummary(id: 2, name: "大学物理", number: "PHY-1", teacher: "李老师")
        let service = ServiceStub(results: [
            "PHY-1": [first, second],
            "大学物理": [first, second],
        ])
        let resolver = ScheduleAcademicCourseResolver(service: service)

        let resolution = try #require(
            await resolver.resolve(
                makeCourse(
                    name: "大学物理",
                    number: "PHY-1",
                    teacher: "李老师"
                )))

        let searches = service.recordedSearches()
        #expect(Set(searches) == ["PHY-1", "大学物理"])
        #expect(resolution.selectedCourse.id == second.id)
    }

    private func makeSummary(
        id: Int,
        name: String,
        number: String,
        teacher: String
    ) -> CourseSummary {
        CourseSummary(
            detail: CourseDetail(
                id: id,
                name: name,
                number: number,
                credit: 2,
                likeNum: 0,
                commentNum: 0,
                rate: 0,
                teachersName: teacher,
                teachersNumber: "",
                like: false
            ))
    }

    private func makeCourse(name: String, number: String, teacher: String) -> CourseRecord {
        CourseRecord(
            id: "schedule-course",
            term: "2026-2027-1",
            name: name,
            teacher: teacher,
            classroom: "",
            description: "",
            weeks: [1],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "",
            number: number,
            credit: 2,
            hour: 32,
            type: "",
            category: "",
            department: ""
        )
    }
}

// 内存响应替身沿测试模块提供接收完成后的预算适配。
extension HTTPTransport {
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes {
            throw HTTPClientError.responseTooLarge
        }
        return result
    }
}

extension ExperimentalPreferenceCloudSyncTests {
    final class ExternalDisplays: AppExternalDisplayCoordinating {
        var activationCount = 0
        var resetCount = 0
        var refreshes: [(String, AppStorageSession)] = []
        func activate() { activationCount += 1 }
        func resetAccountPresentation() { resetCount += 1 }
        func refresh(trigger: String, syncWidgetSnapshot: Bool, session: AppStorageSession) async {
            #expect(syncWidgetSnapshot)
            refreshes.append((trigger, session))
        }
        func waitForRefreshes(_ count: Int) async throws {
            try await waitForTestEvent { refreshes.count >= count }
        }
    }

    struct OfflineTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }
    struct OfflineScoreService: ScoreListServicing, TrustedTranscriptServicing {
        let transcriptServiceIdentity: AnyHashable = UUID()
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            throw URLError(.notConnectedToInternet)
        }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge)
            async throws -> [ScoreRow]
        { [] }
        func submitScoreCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        { challenge }
        func fetchTrustedPages(onPage: TrustedTranscriptPageDelivery?) async throws
            -> TrustedTranscriptPages
        { .init([]) }
        func submitTranscriptCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        { return challenge }
        func fetchTrustedPages(
            authenticatedBy challenge: BITLoginAuthenticationChallenge,
            onPage: TrustedTranscriptPageDelivery?
        ) async throws -> TrustedTranscriptPages { .init([]) }
    }

}
