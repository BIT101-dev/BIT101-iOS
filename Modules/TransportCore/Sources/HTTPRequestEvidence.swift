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
        finalMethod = finalRequest?.httpMethod
            ?? (response.url == request.url ? method : "")
        var final = response.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        final?.user = nil; final?.password = nil
        final?.query = nil; final?.fragment = nil
        finalEndpoint = final?.string ?? ""
        var endpoint = (request.url ?? response.url).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail", "search", "hide_bot", "XNXQDM", "JXLDM"])
        let responseQuery = response.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
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
        query = parameters
        finalQuery = finalMethod == "GET" ? Dictionary(responseQuery.compactMap { item in
            guard allowed.contains(item.name), let value = item.value else { return nil }; return (item.name, value)
        }, uniquingKeysWith: { first, _ in first }) : parameters
        endpoint?.user = nil
        endpoint?.password = nil
        endpoint?.query = nil
        endpoint?.fragment = nil
        self.endpoint = endpoint?.string ?? ""
        statusCode = response.statusCode
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
