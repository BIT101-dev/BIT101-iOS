import Foundation

public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let statusCode: Int

    public init(request: URLRequest, response: HTTPURLResponse) {
        method = request.httpMethod ?? "GET"
        var endpoint = (request.url ?? response.url).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        endpoint?.user = nil
        endpoint?.password = nil
        endpoint?.query = nil
        endpoint?.fragment = nil
        self.endpoint = endpoint?.string ?? ""
        statusCode = response.statusCode
    }
}

public nonisolated enum HTTPRequestEvidenceContext {
    @TaskLocal public static var didReceive: (@MainActor @Sendable (HTTPRequestEvidence) -> Void)?
}
