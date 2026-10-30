import CommunityCore
import CommunityTransport
import Foundation
import Testing
import TransportCore
@testable import GalleryFeature

extension ServiceContractTests {
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
