import CommunityCore
import CommunityTransport
import Foundation
@testable import PaperFeature
import Testing
import TransportCore

@MainActor
struct PaperCommentPagingTests {
    private final class Transport: HTTPTransport {
        var pages: [Int] = []
        var stalls = false
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "page" }?.value.flatMap(Int.init) ?? 0
            pages.append(page)
            let id = stalls || page < 3 ? 1 : 2
            let user = #"{"id":1,"create_time":"","nickname":"用户","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#
            let data = Data("""
            [{"id":\(id),"obj":"paper1","images":[],"user":\(user),"anonymous":false,"create_time":"",
              "update_time":"","like":false,"like_num":0,"comment_num":0,"own":false,"rate":0,
              "reply_user":\(user),"reply_obj":"","text":"评论","sub":[]}]
            """.utf8)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (data, response)
        }
    }

    @Test(arguments: [false, true])
    func repeatedCommentsAdvanceOrRetainTheRetryPosition(stalled: Bool) async throws {
        let transport = Transport()
        transport.stalls = stalled
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "paper-paging"), cookie: "fixture-cookie") }, refresh: { _ in })
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "文章", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: PaperService(session: session))
        await model.refreshComments()
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.items.map(\.id) == (stalled ? [1] : [1, 2]))
        #expect(model.commentState.nextPage == 4 && !model.commentState.isLoadingMore)
        #expect((model.alert != nil) == stalled)
        #expect(transport.pages == (stalled ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]))
        if stalled {
            transport.stalls = false
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(model.commentState.items.map(\.id) == [1, 2] && transport.pages.last == 4)
        }
    }
}
