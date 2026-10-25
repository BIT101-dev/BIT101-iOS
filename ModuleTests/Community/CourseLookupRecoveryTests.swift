import CommunityCore
import CommunityTransport
import Foundation
import Testing
import TransportCore
@testable import CourseFeature
@testable import PaperFeature

@MainActor
struct CourseLookupRecoveryTests {
    private final class ListTransport: HTTPTransport {
        let row: [String: Any]
        init(row: [String: Any]) { self.row = row }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (try JSONSerialization.data(withJSONObject: [row]),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) { try await data(for: request) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["course", "paper"], ["valid", "id", "likes", "comments", "rating"])
    func listsValidateIdentifiersCountsAndCourseRatings(kind: String, damage: String) async throws {
        var row: [String: Any] = ["id": 1, "name": "课程", "number": "C1", "credits": "1", "teachers_name": "教师",
            "teachers_number": "T1", "title": "文章", "intro": "", "update_time": "", "rate": 9.2, "like_num": 0, "comment_num": 0]
        switch damage {
        case "id": row["id"] = 0
        case "likes": row["like_num"] = -1
        case "comments": row["comment_num"] = -1
        case "rating": row["rate"] = 11
        default: break
        }
        let valid = damage == "valid" || (kind == "paper" && damage == "rating")
        let session = CommunitySession(httpClient: HTTPClient(transport: ListTransport(row: row), observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        do {
            if kind == "course" { #expect(try await CourseService(session: session).fetchCourses(search: "", page: 0).map(\.id) == [1]) }
            else { #expect(try await PaperService(session: session).fetchPapers(search: nil, order: .newest, page: 0).map(\.id) == [1]) }
            #expect(valid)
        } catch {
            #expect(!valid)
            #expect(kind == "course" ? error is CourseServiceError : error is PaperServiceError)
        }
    }

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
