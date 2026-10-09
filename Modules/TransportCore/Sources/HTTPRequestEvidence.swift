import Foundation

public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let finalEndpoint: String
    public let finalMethod: String
    public let finalQuery: [String: String]
    public let statusCode: Int
    public let query: [String: String]
    public let responseMinimumID: String?

    public init(request: URLRequest, response: HTTPURLResponse, responseMinimumID: String? = nil, finalRequest: URLRequest? = nil) {
        self.responseMinimumID = responseMinimumID
        method = request.httpMethod ?? "GET"
        query = Self.parameters(request)
        if let finalRequest {
            finalMethod = finalRequest.httpMethod ?? "GET"
            finalQuery = Self.parameters(finalRequest)
        } else if response.url == request.url {
            finalMethod = method
            finalQuery = query
        } else {
            finalMethod = ""
            finalQuery = [:]
        }
        endpoint = Self.redactedEndpoint(request.url ?? response.url)
        finalEndpoint = Self.redactedEndpoint(response.url)
        statusCode = response.statusCode
    }

    private static func redactedEndpoint(_ url: URL?) -> String {
        var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        components?.user = nil; components?.password = nil
        components?.query = nil; components?.fragment = nil
        return components?.string ?? ""
    }

    private static func parameters(_ request: URLRequest) -> [String: String] {
        let endpoint = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail", "search", "hide_bot", "XNXQDM", "JXLDM"])
        var parameters: [String: String] = Dictionary((endpoint?.queryItems ?? []).compactMap { item in
            guard allowed.contains(item.name), let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true,
           let body = request.httpBody, let encoded = String(data: body, encoding: .utf8),
           let form = URLComponents(string: "?" + encoded.replacingOccurrences(of: "+", with: "%20"))?.queryItems {
            for item in form where ["XNXQDM", "JXLDM"].contains(item.name) {
                parameters[item.name] = item.value
            }
            if let encoded = form.first(where: { $0.name == "requestParamStr" })?.value,
               let object = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any],
               let term = object["XNXQDM"] as? String { parameters["XNXQDM"] = term }
        }
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
           let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = object["detail"] as? Bool { parameters["detail"] = String(detail) }
            if let value = object["obj"] as? String,
               value.range(of: "^(poster|paper|course|comment)[1-9][0-9]*$", options: .regularExpression) != nil {
                parameters["obj"] = value
            }
        }
        return parameters
    }

    @concurrent
    public static func capture(request: URLRequest, response: HTTPURLResponse, body: Data, finalRequest: URLRequest? = nil) async -> Self {
        let cursor: String?
        if let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
            if rows.isEmpty { cursor = "0" }
            else {
                let identifiers = rows.compactMap { $0["id"] as? Int }
                cursor = identifiers.count == rows.count && identifiers.allSatisfy({ $0 > 0 })
                    ? identifiers.min().map(String.init) : nil
            }
        } else { cursor = nil }
        return Self(request: request, response: response, responseMinimumID: cursor, finalRequest: finalRequest)
    }
}

public nonisolated enum HTTPRequestEvidenceContext {
    @TaskLocal public static var didReceive: (@MainActor @Sendable (HTTPRequestEvidence) -> Void)?
    @TaskLocal public static var willStart: (@MainActor @Sendable () -> Void)?
    @TaskLocal public static var didReceiveFinalRequest: (@MainActor @Sendable (URLRequest) -> Void)?
}
