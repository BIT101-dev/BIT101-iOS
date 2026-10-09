import Foundation

public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let statusCode: Int
    public let query: [String: String]
    public let responseMinimumID: String?

    public init(request: URLRequest, response: HTTPURLResponse, responseMinimumID: String? = nil) {
        self.responseMinimumID = responseMinimumID
        method = request.httpMethod ?? "GET"
        var endpoint = (request.url ?? response.url).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail"])
        var parameters: [String: String] = Dictionary((endpoint?.queryItems ?? []).compactMap { item in
            guard allowed.contains(item.name), let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
           let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = object["detail"] as? Bool { parameters["detail"] = String(detail) }
            if let value = object["obj"] as? String,
               value.range(of: "^(poster|paper|course|comment)[1-9][0-9]*$", options: .regularExpression) != nil {
                parameters["obj"] = value
            }
        }
        query = parameters
        endpoint?.user = nil
        endpoint?.password = nil
        endpoint?.query = nil
        endpoint?.fragment = nil
        self.endpoint = endpoint?.string ?? ""
        statusCode = response.statusCode
    }

    @concurrent
    public static func capture(request: URLRequest, response: HTTPURLResponse, body: Data) async -> Self {
        let cursor: String?
        if let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
            if rows.isEmpty { cursor = "0" }
            else {
                let identifiers = rows.compactMap { $0["id"] as? Int }
                cursor = identifiers.count == rows.count && identifiers.allSatisfy({ $0 > 0 })
                    ? identifiers.min().map(String.init) : nil
            }
        } else { cursor = nil }
        return Self(request: request, response: response, responseMinimumID: cursor)
    }
}

public nonisolated enum HTTPRequestEvidenceContext {
    @TaskLocal public static var didReceive: (@MainActor @Sendable (HTTPRequestEvidence) -> Void)?
}
