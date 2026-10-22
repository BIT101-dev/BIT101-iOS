import BIT101TestSupport
import CommunityCore
import CommunityTransport
import Foundation
import GalleryFeature
import PaperFeature
import Testing
import TransportCore

@MainActor
struct CommunityDeletionRecoveryTests {
    private final class DeletionTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var firstResponseLost = true
        var status = 404
        var boundary = "target"
        var didReceive: (() -> Void)?
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if firstResponseLost { firstResponseLost = false; throw URLError(.networkConnectionLost) }
            var final = request
            if boundary == "redirect" { final.url = AppURL.required("https://example.invalid/login") }
            if boundary == "method" { final.httpMethod = "GET" }
            HTTPRequestEvidenceContext.didReceiveFinalRequest?(final)
            didReceive?()
            let url = try #require(final.url)
            return (Data(#"{"detail":"target missing"}"#.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: status, httpVersion: nil, headerFields: nil)))
        }
    }

    private final class Credentials {
        var value = CommunityCredentials(identity: .init(accountIdentifier: "deletion"), cookie: "fixture")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["poster", "comment", "paper"],
        ["target", "denied", "redirect", "method", "account"])
    func deletionRetryConvergesOnlyForTheValidatedMissingTarget(resource: String, boundary: String) async throws {
        let transport = DeletionTransport(), credentials = Credentials()
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { credentials.value }, refresh: { _ in })
        let gallery = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let paper = PaperService(session: session)
        func delete() async throws {
            switch resource {
            case "poster": try await gallery.deletePoster(id: 42)
            case "comment": try await gallery.deleteComment(id: 42)
            default: try await paper.deletePaper(id: 42)
            }
        }
        await #expect(throws: URLError.self) { try await delete() }
        transport.boundary = boundary
        if boundary == "denied" { transport.status = 403 }
        if boundary == "account" {
            transport.didReceive = { credentials.value = .init(identity: .init(accountIdentifier: "other"), cookie: "other") }
        }
        if boundary == "target" { try await delete() }
        else { await #expect(throws: (any Error).self) { try await delete() } }
        let path = resource == "poster" ? "/posters/42" : resource == "comment" ? "/reaction/comments/42" : "/papers/42"
        #expect(transport.requests.map { $0.url?.path } == [path, path])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "DELETE" })
    }

    @Test(.timeLimit(.minutes(1)))
    func missingReadAndRejectedDeletionKeepTheirHTTPFailures() async throws {
        let transport = DeletionTransport(); transport.firstResponseLost = false
        let api = CommunityAPIClient<PaperServiceError>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "deletion", credentials: {
                .init(identity: .init(accountIdentifier: "deletion"), cookie: "fixture")
            })
        await #expect(throws: (any Error).self) { try await api.requestVoid(path: "papers/42", method: "GET") }
        transport.status = 500
        await #expect(throws: (any Error).self) { try await api.requestVoid(path: "papers/42", method: "DELETE") }
    }
}
