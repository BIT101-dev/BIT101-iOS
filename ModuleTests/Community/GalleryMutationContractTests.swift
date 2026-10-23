import CommunityCore
import CommunityTransport
import Foundation
import Testing
import TransportCore
@testable import GalleryFeature

extension ServiceContractTests {
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
