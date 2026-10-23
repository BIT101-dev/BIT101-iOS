import CommunityTransport
import Foundation
import Testing
import TransportCore

@MainActor
struct HTTPResponseValidationTests {
    private struct Transport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (Data(#"{"required":7}"#.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }
    private final class Observer: HTTPClientObserving {
        var errors: [(any Error)?] = []
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?, error: (any Error)?, elapsed: TimeInterval) async {
            errors.append(error)
        }
    }
    private enum Failure: CommunityAPIServiceError {
        case signedOut, invalid
        static var communityNotLoggedIn: Self { .signedOut }
        static var communityInvalidResponse: Self { .invalid }
    }

    @Test(.timeLimit(.minutes(1)))
    func validationReportsTheFirstFailureAndPreservesTheDecodingCause() async throws {
        let observer = Observer()
        let url = try #require(URL(string: "https://example.invalid/fields"))
        let response = try await HTTPClient(transport: Transport(), observer: observer).send(URLRequest(url: url))
        await response.reportValidationFailure(CancellationError())
        #expect(observer.errors.count == 1 && observer.errors[0] == nil)
        do {
            let _: [String: String] = try await response.validated { data, _ in
                try JSONDecoder().decode([String: String].self, from: data)
            }
            Issue.record("字段解析应传播类型错误")
        } catch {
            #expect(error is DecodingError)
        }
        await response.reportValidationFailure(URLError(.badServerResponse))
        let failure = try #require(observer.errors.last.flatMap { $0 })
        #expect(observer.errors.count == 2 && failure is DecodingError)
    }

    @Test(.timeLimit(.minutes(1)))
    func communityParsingFailureReachesTheRequestObserver() async throws {
        let observer = Observer()
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: Transport(), observer: observer),
            baseURL: try #require(URL(string: "https://example.invalid")), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture", generation: 0), cookie: "") })
        do {
            let _: [String: String] = try await client.request(path: "fields", authentication: .none)
            Issue.record("社区解析应传播类型错误")
        } catch {
            #expect((error as NSError).userInfo[NSUnderlyingErrorKey] is DecodingError)
        }
        let failure = try #require(observer.errors.last.flatMap { $0 })
        #expect(observer.errors.count == 2 && failure is DecodingError)
    }
}
