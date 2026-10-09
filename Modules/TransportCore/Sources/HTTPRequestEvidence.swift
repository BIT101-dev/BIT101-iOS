import Foundation

public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let statusCode: Int
    public let query: [String: String]

    public init(request: URLRequest, response: HTTPURLResponse) {
        method = request.httpMethod ?? "GET"
        var endpoint = (request.url ?? response.url).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail"])
        var parameters: [String: String] = Dictionary((endpoint?.queryItems ?? []).compactMap { item in
            guard allowed.contains(item.name), let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
           let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let detail = object["detail"] as? Bool {
            parameters["detail"] = String(detail)
        }
        query = parameters
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
