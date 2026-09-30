import ScoreDomain
import ClientCore
import Foundation
import ScoreFeature
@testable import ScoreInfrastructure
import Testing
import TransportCore

@MainActor
struct ScoreInfrastructureBoundaryTests {
    private struct Credentials: SchoolCredentialsProviding {
        let currentStudentID = "fixture-account"
        let currentPassword = "fixture-password"
    }

    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            throw URLError(.timedOut)
        }
    }

    @Test func productionServiceUsesInjectedCredentialsEndpointAndTransport() async throws {
        let authentication = Transport()
        let downloads = Transport()
        let service = ScoreService(credentials: Credentials(), httpClient: HTTPClient(transport: authentication, observer: nil), sensitiveHTTPClient: HTTPClient(transport: downloads, observer: nil), endpointBaseURL: AppURL.required("https://example.invalid"))
        await #expect(throws: ScoreServiceError.self) { try await service.startScoreChallenge() }
        let request = try #require(authentication.requests.first)
        #expect(request.url?.absoluteString == "https://example.invalid/api/auth/start")
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(payload?["username"] as? String == "fixture-account")
        #expect(payload?["password"] as? String == "fixture-password")
        #expect(authentication.requests.count == 1)
        #expect(downloads.requests.isEmpty)
    }

    @Test func scoreResponseParsingRunsInThePackageHost() throws {
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[]}"#.utf8)).isEmpty)
    }
}
