import CommunityCore
import Foundation
import Testing
@testable import CourseFeature

@MainActor
struct CourseLookupRecoveryTests {
    private final class Service: CourseListServicing {
        var slowName = false
        var aliasNumber = false
        var cancelledName = false
        var numberPages: [Int] = []
        private var numberReady: CheckedContinuation<Void, Never>?
        private var nameEntered = false

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            if search == "课程" {
                nameEntered = true
                numberReady?.resume(); numberReady = nil
                if slowName {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancelledName = Task.isCancelled; throw error }
                }
                throw URLError(.notConnectedToInternet)
            }
            numberPages.append(page)
            if !nameEntered { await withCheckedContinuation { numberReady = $0 } }
            return page == 0 ? [CourseSummary(detail: CourseDetail(id: 42, name: "课程",
                number: aliasNumber ? "community-code" : "C1", credit: 1, likeNum: 0,
                commentNum: 0, rate: 0, teachersName: "教师", teachersNumber: "T1", like: false))] : []
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func exactIdentityFinishesThroughAnUnavailableParallelSearch(slow: Bool) async throws {
        let service = Service()
        service.slowName = slow
        let result = try #require(await CourseEvaluationResolver(service: service).resolve(
            courseName: "课程", courseNumber: "C1", teacher: "教师"))
        #expect(result.selectedCourse.id == 42 && result.searchResults.map(\.id) == [42])
        #expect(result.searchQuery == "C1")
        #expect(service.numberPages == [0])
        #expect(service.cancelledName == slow)
    }

    @Test(.timeLimit(.minutes(1))) func aCompletedIdentitySearchSurvivesTheOtherSearchFailure() async throws {
        let service = Service()
        service.aliasNumber = true
        let result = try #require(await CourseEvaluationResolver(service: service).resolve(
            courseName: "课程", courseNumber: "school-code", teacher: "教师"))
        #expect(result.selectedCourse.id == 42 && service.numberPages == [0, 1])
    }
}
