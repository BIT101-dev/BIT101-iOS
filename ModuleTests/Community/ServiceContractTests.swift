import CommunityCore
import CommunityTransport
import CourseFeature
import PaperFeature
import Foundation
import Testing
import TransportCore

@MainActor
struct ServiceContractTests {
    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        private var responses: [(Int, String)]
        init(_ responses: [(Int, String)]) { self.responses = responses }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try Task.checkCancellation()
            requests.append(request)
            let response = try #require(responses.first)
            responses.removeFirst()
            let url = try #require(request.url)
            return (Data(response.1.utf8), try #require(HTTPURLResponse(url: url, statusCode: response.0,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
    }

    private let course = #"{"id":42,"name":"操作系统","number":"CS101","credits":"3.5","like_num":7,"comment_num":2,"rate":9.2,"teachers_name":"教师","teachers_number":"T1"}"#
    private let paper = #"{"id":17,"title":"文章","intro":"摘要","like_num":3,"comment_num":4,"update_time":"2026-09-01T08:00:00Z"}"#
    private let user = #"{"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"avatar","url":"https://example.invalid/avatar","low_url":"https://example.invalid/small"},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#

    private func session(_ transport: Transport, cookie: String = "fixture-cookie") -> CommunitySession {
        CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts"), cookie: cookie) }, refresh: { _ in })
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func coursePagingAndDetailDecodeSnakeCaseAndFlexibleCredits() async throws {
        let detail = String(course.dropLast()) + #", "like":true}"#
        let transport = Transport([(200, "[" + course + "]"), (200, "[]"), (200, detail)])
        let service = CourseService(session: session(transport))
        let first = try await service.fetchCourses(search: "  操作系统 & A+B  ", page: 0)
        #expect(first.first?.credit == 3.5)
        #expect(first.first?.teachersName == "教师")
        #expect(first.first?.likeNum == 7)
        #expect(try query(transport.requests[0]) == ["search": "操作系统 & A+B", "order": "new", "page": "0"])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == "fixture-cookie")
        #expect(try await service.fetchCourses(search: "", page: 1).isEmpty)
        #expect(try query(transport.requests[1]) == ["order": "new", "page": "1"])
        let value = try await service.fetchCourse(id: 42)
        #expect(value.like && value.id == 42)
        #expect(value.credit == 3.5)
        #expect(transport.requests[2].url?.path == "/courses/42")
    }

    @Test func courseHistoryEscapesPathSeparatorsAndDecodesStatistics() async throws {
        let transport = Transport([(200, #"[{"term":"2026-2027-1","avg_score":"85.5","max_score":100,"student_num":"37"}]"#)])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(number: "MATH/1+中文%20")
        #expect(values.first?.avgScore == 85.5)
        #expect(values.first?.studentNum == 37)
        #expect(transport.requests.first?.url?.path == "/courses/histories/MATH/1+中文%20")
        #expect(transport.requests.first?.url?.absoluteString.contains("MATH%2F1%2B") == true)
        #expect(transport.requests.first?.url?.absoluteString.hasSuffix("%2520") == true)
    }

    @Test func expiredCourseCredentialsRestoreOnceAndReplayTheOwnedPage() async throws {
        let transport = Transport([(401, #"{"message":"expired"}"#), (200, "[" + course + "]")])
        var cookie = "old-cookie"
        var restores = 0
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts", generation: 2), cookie: cookie) },
            refresh: { observed in
                #expect(observed.cookie == "old-cookie")
                restores += 1
                cookie = "new-cookie"
            })
        let values = try await CourseService(session: session).fetchCourses(search: "CS101", page: 3)
        #expect(values.map(\.id) == [42])
        #expect(restores == 1 && transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "fake-cookie") == "new-cookie")
        #expect(try query(transport.requests[0]) == query(transport.requests[1]))
    }

    @Test(arguments: ["{}", "null", "<html>gateway</html>", #"[{"id":"invalid"}]"#])
    func malformedCourseAndPaperListsExposeTheirBusinessErrors(_ response: String) async {
        await #expect(throws: CourseServiceError.self) {
            try await CourseService(session: session(Transport([(200, response)]))).fetchCourses(search: "", page: 0)
        }
        await #expect(throws: PaperServiceError.self) {
            try await PaperService(session: session(Transport([(200, response)]), cookie: "")).fetchPapers(search: nil, order: .newest, page: 0)
        }
    }

    @Test func publicPaperPagesKeepAnonymousAccessAndDecodeAuthorDetails() async throws {
        let detail = #"{"id":17,"title":"文章","intro":"摘要","content":"正文","create_time":"","update_time":"","update_user":\#(user),"anonymous":false,"like_num":3,"comment_num":4,"public_edit":true,"like":false,"own":true}"#
        let transport = Transport([(200, "[" + paper + "]"), (200, "[]"), (200, detail), (200, "[]")])
        let service = PaperService(session: session(transport, cookie: ""))
        #expect(try await service.fetchPapers(search: "主题 & A+B", order: .comment, page: 2).first?.commentNum == 4)
        #expect(try query(transport.requests[0]) == ["search": "主题 & A+B", "order": "comment", "page": "2"])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == nil)
        #expect(try await service.fetchPapers(search: nil, order: .newest, page: 3).isEmpty)
        #expect(try query(transport.requests[1]) == ["page": "3"])
        let value = try await service.fetchPaper(id: 17)
        #expect(value.updateUser.nickname == "作者" && value.publicEdit && value.own)
        #expect(value.content == "正文")
        #expect(try await service.fetchComments(paperID: 17, order: .oldest, page: 2).isEmpty)
        #expect(try query(transport.requests[3]) == ["obj": "paper17", "order": "old", "page": "2"])
    }

    @Test func paperCreationEditingAndDeletionPreserveTheWireContract() async throws {
        let transport = Transport([(200, #"{"id":17}"#), (204, ""), (204, "")])
        let service = PaperService(session: session(transport))
        #expect(try await service.createPaper(title: "标题", intro: "摘要", content: "正文", anonymous: true, publicEdit: false) == 17)
        try await service.updatePaper(id: 17, title: "编辑", intro: "摘要", content: "新正文", anonymous: false, publicEdit: true)
        try await service.deletePaper(id: 17)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "PUT", "DELETE"])
        #expect(transport.requests.map { $0.url?.path } == ["/papers", "/papers/17", "/papers/17"])
        let created = try body(transport.requests[0])
        #expect(created["public_edit"] as? Bool == false && created["anonymous"] as? Bool == true)
        #expect(created["content"] as? String == "正文")
        let updated = try body(transport.requests[1])
        #expect(updated["public_edit"] as? Bool == true && updated["title"] as? String == "编辑")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func courseAndPaperCommentsSendReplyIdentityAndRating() async throws {
        let comment = #"{"id":5,"obj":"course42","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":8,"reply_user":\#(user),"reply_obj":"comment2","text":"回复","sub":[]}"#
        let transport = Transport([(200, comment), (200, comment), (200, #"{"like":true,"like_num":8}"#), (200, "[]")])
        let shared = session(transport)
        let courseService = CourseService(session: shared)
        let paperService = PaperService(session: shared)
        #expect(try await courseService.createComment(objectID: "course42", text: "回复", replyObjectID: "comment2", replyUID: 1, rate: 8).rate == 8)
        #expect(try await paperService.createComment(objectID: "paper17", text: "回复", replyObjectID: "comment2", replyUID: 1, anonymous: true).id == 5)
        let courseBody = try body(transport.requests[0])
        let paperBody = try body(transport.requests[1])
        #expect(courseBody["rate"] as? Int == 8 && courseBody["reply_uid"] as? Int == 1)
        #expect(courseBody["reply_obj"] as? String == "comment2")
        #expect(paperBody["obj"] as? String == "paper17" && paperBody["anonymous"] as? Bool == true)
        #expect(try await courseService.like(objectID: "course42").like)
        #expect(try await courseService.fetchComments(courseID: 42, page: nil).isEmpty)
        #expect(try query(transport.requests[3]) == ["obj": "course42", "order": "new"])
    }

    @Test func cancelledCourseAndPaperRequestsFinishBeforeTransportAdmission() async {
        let transport = Transport([])
        let shared = session(transport)
        let task = Task {
            await #expect(throws: CancellationError.self) { try await CourseService(session: shared).fetchCourse(id: 42) }
            await #expect(throws: CancellationError.self) { try await PaperService(session: shared).fetchPaper(id: 17) }
        }
        task.cancel()
        await task.value
        #expect(transport.requests.isEmpty)
    }
}
