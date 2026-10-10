import Foundation
import CryptoKit

public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let endpointDigest: String
    public let finalEndpoint: String
    public let finalMethod: String
    public let finalQuery: [String: String]
    public let statusCode: Int
    public let query: [String: String]
    public let ambiguousParameters: [String]?
    public let finalAmbiguousParameters: [String]?
    public let responseMinimumID: String?
    public let responseCourseIDs: [String]?

    public init(request: URLRequest, response: HTTPURLResponse, responseMinimumID: String? = nil, responseCourseIDs: [String]? = nil, finalRequest: URLRequest? = nil) {
        self.responseMinimumID = responseMinimumID
        self.responseCourseIDs = responseCourseIDs
        method = request.httpMethod ?? "GET"
        let originalParameters = Self.parameters(request)
        query = originalParameters.values
        ambiguousParameters = originalParameters.ambiguous
        if let finalRequest {
            finalMethod = finalRequest.httpMethod ?? "GET"
            let parameters = Self.parameters(finalRequest)
            finalQuery = parameters.values
            finalAmbiguousParameters = parameters.ambiguous
        } else if response.url == request.url {
            finalMethod = method
            finalQuery = query
            finalAmbiguousParameters = ambiguousParameters
        } else {
            finalMethod = ""
            finalQuery = [:]
            finalAmbiguousParameters = nil
        }
        endpoint = Self.redactedEndpoint(request.url ?? response.url)
        endpointDigest = request.url.map(Self.urlDigest) ?? ""
        finalEndpoint = Self.redactedEndpoint(response.url)
        statusCode = response.statusCode
    }

    public static func urlDigest(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func redactedEndpoint(_ url: URL?) -> String {
        var components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        components?.user = nil; components?.password = nil
        components?.query = nil; components?.fragment = nil
        return components?.string ?? ""
    }

    private static func parameters(_ request: URLRequest) -> (values: [String: String], ambiguous: [String]?) {
        let endpoint = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail", "search", "hide_bot", "XNXQDM", "JXLDM", "XXXQDM"])
        var parameters: [String: [String]] = [:]
        for item in endpoint?.queryItems ?? [] where allowed.contains(item.name) {
            parameters[item.name, default: []].append(item.value ?? "")
        }
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true,
           let body = request.httpBody, let encoded = String(data: body, encoding: .utf8),
           let form = URLComponents(string: "?" + encoded.replacingOccurrences(of: "+", with: "%20"))?.queryItems {
            for item in form where ["XNXQDM", "JXLDM"].contains(item.name) {
                parameters[item.name, default: []].append(item.value ?? "")
            }
            for item in form where item.name == "requestParamStr" {
                if let encoded = item.value,
                   let object = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any],
                   let term = object["XNXQDM"] as? String { parameters["XNXQDM", default: []].append(term) }
            }
        }
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
           let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = object["detail"] as? Bool { parameters["detail", default: []].append(String(detail)) }
            if let value = object["obj"] as? String,
               value.range(of: "^(poster|paper|course|comment)[1-9][0-9]*$", options: .regularExpression) != nil {
                parameters["obj", default: []].append(value)
            }
        }
        let ambiguous = parameters.filter { $0.value.count > 1 }.keys.sorted()
        let values = parameters.compactMapValues { $0.count == 1 ? $0.first : nil }
        return (values, ambiguous.isEmpty ? nil : ambiguous)
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
        let courseIDs: [String]?
        if request.url?.host == "zy-eclass.bit.edu.cn", request.url?.path == "/api/my-courses",
           let page = try? JSONDecoder().decode(CoursePageEvidence.self, from: body), page.courses.allSatisfy({ $0.id > 0 }) {
            courseIDs = page.courses.map { String($0.id) }
        } else { courseIDs = nil }
        return Self(request: request, response: response, responseMinimumID: cursor, responseCourseIDs: courseIDs, finalRequest: finalRequest)
    }

    private struct CoursePageEvidence: Decodable {
        struct Course: Decodable { let id: Int }
        let courses: [Course]
    }
}

public nonisolated enum HTTPRequestEvidenceContext {
    @TaskLocal public static var didReceive: (@MainActor @Sendable (HTTPRequestEvidence) -> Void)?
    @TaskLocal public static var willStart: (@MainActor @Sendable () -> Void)?
    @TaskLocal public static var didReceiveFinalRequest: (@MainActor @Sendable (URLRequest) -> Void)?
}
