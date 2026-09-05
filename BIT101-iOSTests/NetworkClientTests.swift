import Foundation
import Testing
@testable import BIT101_iOS

private final class MockHTTPTransport: HTTPTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private enum TestCommunityError: LocalizedError, CommunityAPIServiceError {
    case notLoggedIn
    case invalidResponse

    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

@Suite("Network stack")
struct NetworkClientTests {
    private struct UserPayload: Decodable, Equatable {
        let displayName: String
    }

    @Test("HTTP errors preserve structured server messages")
    func structuredHTTPError() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(#"{"message":"稍后重试"}"#.utf8), response)
        }

        await #expect(throws: HTTPClientError.self) {
            _ = try await HTTPClient(transport: transport).send(URLRequest(url: try #require(URL(string: "https://example.com"))))
        }

        do {
            _ = try await HTTPClient(transport: transport).send(URLRequest(url: try #require(URL(string: "https://example.com"))))
            Issue.record("Expected an HTTP error")
        } catch let error as HTTPClientError {
            #expect(error.errorDescription == "稍后重试")
        }
    }

    @Test("Community requests apply auth, query and snake case decoding")
    func communityRequestConstruction() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "session-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "page", value: "2")
            ])
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(#"{"display_name":"BIT101"}"#.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { "session-token" }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            queryItems: [URLQueryItem(name: "page", value: "2")]
        )
        #expect(payload == UserPayload(displayName: "BIT101"))
    }

    @Test("Required authentication fails before transport")
    func requiredAuthentication() async throws {
        let transport = MockHTTPTransport { _ in
            Issue.record("Transport must not run without authentication")
            throw TestCommunityError.invalidResponse
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { "" }
        )

        do {
            let _: UserPayload = try await api.request(path: "users")
            Issue.record("Expected authentication to fail")
        } catch TestCommunityError.notLoggedIn {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Optional authentication omits an empty cookie")
    func optionalAuthentication() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == nil)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(#"{"display_name":"Guest"}"#.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { "" }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            authentication: .optional
        )
        #expect(payload.displayName == "Guest")
    }

    @Test("Multipart payload keeps the backend file contract")
    func multipartPayload() {
        let multipart = MultipartFormData.jpegFile(
            data: Data([0x01, 0x02]),
            filename: "avatar.jpg"
        )
        let text = String(decoding: multipart.body, as: UTF8.self)

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(text.contains("name=\"file\"; filename=\"avatar.jpg\""))
        #expect(text.contains("Content-Type: image/jpeg"))
        #expect(text.hasSuffix("--\r\n"))
    }

    @Test("School URLs are resolved and upgraded through one policy")
    func secureSchoolURLResolution() throws {
        let insecure = try #require(URL(string: "http://example.com/path?q=1"))
        #expect(HTTPSURLUpgrade.upgradedURL(from: insecure).absoluteString == "https://example.com/path?q=1")

        let login = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        #expect(
            HTTPSURLUpgrade.resolvedURL(from: "/gate/cas-success", relativeTo: login)?.absoluteString
                == "https://sso.bit.edu.cn/gate/cas-success"
        )
    }

    @Test("bit-login challenge protocol is shared by school services")
    func sharedBITLoginChallengeProtocol() throws {
        let data = Data(
            #"{"challenge_id":"challenge-1","access_token":"token","status":"waiting_sms","masked_phone":"138****0000","expires_in":120}"#.utf8
        )
        let payload = try BITLoginChallengeSupport.decodePayload(from: data)
        let challenge = BITLoginChallengeSupport.challenge(from: payload, accessToken: "token")

        #expect(challenge.challengeID == "challenge-1")
        #expect(challenge.status == "waiting_sms")
        #expect(challenge.maskedPhone == "138****0000")
        #expect(
            BITLoginChallengeSupport.errorMessage(
                from: Data(#"{"detail":{"error":"验证码错误"}}"#.utf8)
            ) == "验证码错误"
        )
    }
}
