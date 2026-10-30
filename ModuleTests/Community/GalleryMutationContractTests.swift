import CommunityCore
import CommunityTransport
import Combine
import Foundation
import Testing
import TransportCore
@testable import GalleryFeature
@testable import PaperFeature

extension ServiceContractTests {
    private final class ImageRecoveryObserver: HTTPClientObserving {
        var failures = 0
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?, error: (any Error)?, elapsed: TimeInterval) async {
            if error != nil { failures += 1 }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func posterImagesKeepValidNeighborsAndReportTheirPartialResponse(detail: Bool) async throws {
        let text = String(repeating: "完整正文", count: 2_000)
        let body = #"{"id":42,"anonymous":false,"user":{"id":1},"like":false,"own":true,"title":"图片","text":"\#(text)","images":[{"mid":"first","url":"https://example.invalid/first"},{"url":"https://example.invalid/missing"},null,{"mid":"last","url":"https://example.invalid/last"}]}"#
        let transport = Transport([(200, detail ? body : "[\(body)]")])
        let observer = ImageRecoveryObserver()
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: observer),
            baseURL: AppURL.required("https://example.invalid"), credentials: {
                .init(identity: .init(accountIdentifier: "image-recovery"), cookie: "fixture")
            }, refresh: { _ in })
        let service = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        if detail {
            let poster = try await service.fetchPoster(id: 42)
            #expect(poster.images.map(\.mid) == ["first", "last"] && poster.discardedImageCount == 2)
            #expect(poster.text == text)
        } else {
            let page = try await service.fetchFeed(kind: .newest, page: 0)
            #expect(page.items.first?.images.map(\.mid) == ["first", "last"] && page.items.first?.discardedImageCount == 2)
        }
        #expect(observer.failures == 1)
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["poster", "paper"], ["like_num", "comment_num"])
    func invalidDetailCountsKeepTheirFailureOutOfSharedLists(kind: String, field: String) async throws {
        let body: [String: Any] = ["id": 42, "title": "内容", "intro": "", "content": "", "text": "正文", "anonymous": false,
            "user": ["id": 1], "update_user": ["id": 1], "like": false, "own": true, "public_edit": false,
            "create_time": "", "update_time": "", "like_num": field == "like_num" ? -1 : 0,
            "comment_num": field == "comment_num" ? -1 : 0]
        let transport = Transport([(200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))])
        let session = session(transport)
        let gallery = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let paper = PaperService(session: session)
        var updates: [CommunityResourceMetrics] = []
        let subscription = (kind == "poster" ? gallery.resourceChanges : paper.resourceChanges).sink { updates += $0 }
        defer { subscription.cancel() }
        do {
            if kind == "poster" { _ = try await gallery.fetchPoster(id: 42) }
            else { _ = try await paper.fetchPaper(id: 42) }
            Issue.record("异常计数需要保留协议错误。")
        } catch {
            #expect(kind == "poster" ? error is GalleryServiceError : error is PaperServiceError)
        }
        #expect(updates.isEmpty)
    }

    @Test func negativeLikeResponsesRemainProtocolFailures() {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(throws: DecodingError.self) { try decoder.decode(CommunityLikeResult.self, from: Data(#"{"like":true,"like_num":-1}"#.utf8)) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["saved", "different", "readFailed", "rejected"])
    func posterEditsVerifyAmbiguousResponsesAndRetainClearRejections(scenario: String) async throws {
        let transport = Transport([])
        transport.responseForRequest = { request in
            if request.httpMethod == "PUT" {
                if scenario == "rejected" { return (400, #"{"msg":"fixture rejection"}"#) }
                throw URLError(.networkConnectionLost)
            }
            if scenario == "readFailed" { throw URLError(.notConnectedToInternet) }
            let title = scenario == "different" ? "其他修改" : "编辑"
            return (200, #"{"id":42,"title":"\#(title)","text":"正文","images":[],"plugins":"[]","anonymous":false,"tags":[],"claim":{"id":0,"text":""},"public":true,"comment_num":0,"like_num":0,"like":false,"own":true,"create_time":"","edit_time":"","update_time":"","user":{"id":1}}"#)
        }
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do {
            try await service.updatePoster(id: 42, title: "编辑", text: "正文", imageMids: [], plugins: "[]",
                anonymous: false, tags: [], claimID: 0, isPublic: true)
            #expect(scenario == "saved")
        } catch {
            #expect(scenario != "saved")
            #expect((error is CommunityUpdateOutcomeUnknown) == (scenario != "rejected"))
        }
        #expect(transport.requests.map(\.httpMethod) == (scenario == "rejected" ? ["PUT"] : ["PUT", "GET"]))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CommunityMutationKind.creation, .toggle, .update])
    func mutationPoliciesApplyToCallerOwnedEndpoints(kind: CommunityMutationKind) async {
        let transport = Transport([])
        transport.failure = URLError(.networkConnectionLost)
        let api: CommunityAPIClient<GalleryServiceError> = session(transport).client(errorDomain: "BIT101.Gallery")
        do {
            try await api.requestVoid(path: "caller-owned-action", method: "POST", mutation: kind)
            Issue.record("发送结果应进入调用方声明的待确认状态。")
        } catch {
            switch kind {
            case .creation: #expect(error is CommunityCreateOutcomeUnknown)
            case .toggle: #expect(error is CommunityToggleOutcomeUnknown)
            case .update: #expect(error is CommunityUpdateOutcomeUnknown)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["upload", "report"])
    func composerOperationsPreserveBackendRejectionDetails(operation: String) async throws {
        let transport = Transport([(400, #"{"msg":"fixture rejection"}"#)])
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do {
            if operation == "upload" { _ = try await service.uploadImage(data: Data([1, 2, 3])) }
            else { try await service.report(objectID: "poster1", typeID: 42, text: "说明") }
            Issue.record("服务端拒绝应进入调用方错误状态。")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == "BIT101.Gallery" && failure.code == 400)
            #expect(failure.localizedDescription.contains("fixture rejection"))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func reportTransportCancellationPreservesItsClassification(urlError: Bool) async {
        let transport = Transport([])
        transport.failure = urlError ? URLError(.cancelled) : CancellationError()
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do {
            try await service.report(objectID: "poster1", typeID: 42, text: "说明")
            Issue.record("Cancelled report should release its caller")
        } catch { #expect(TaskCancellation.matches(error)) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [400, 503, 0])
    func reportCreationDistinguishesRejectionFromAnUnknownOutcome(status: Int) async {
        let transport = Transport([(status, "")])
        if status == 0 { transport.failure = URLError(.networkConnectionLost) }
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do { try await service.report(objectID: "poster1", typeID: 42, text: "说明"); Issue.record("需要呈现传输结果") }
        catch { #expect((error is CommunityCreateOutcomeUnknown) == (status != 400)) }
        #expect(transport.requests.count == 1)
    }
}
