import Foundation
import TransportCore

nonisolated struct NetworkSmokeHTTPRequestEvidence: Codable, Sendable {
    let method: String
    let endpoint: String
    let endpointDigest: String
    let finalEndpoint: String
    let finalMethod: String
    let finalQuery: [String: String]
    let statusCode: Int
    let query: [String: String]
    let ambiguousParameters: [String]?
    let finalAmbiguousParameters: [String]?
    let responseMinimumID: String?
    let responseCourseIDs: [String]?

    init(request: URLRequest, response: HTTPURLResponse, responseMinimumID: String? = nil, responseCourseIDs: [String]? = nil, finalRequest: URLRequest? = nil) {
        self.responseMinimumID = responseMinimumID
        self.responseCourseIDs = responseCourseIDs
        let metadata = HTTPRequestEvidence(request: request, response: response, finalRequest: finalRequest)
        method = metadata.method
        finalMethod = metadata.finalMethod
        let originalParameters = Self.parameters(request)
        query = originalParameters.values
        ambiguousParameters = originalParameters.ambiguous
        if let finalRequest {
            let parameters = Self.parameters(finalRequest)
            finalQuery = parameters.values
            finalAmbiguousParameters = parameters.ambiguous
        } else if response.url == request.url {
            finalQuery = query
            finalAmbiguousParameters = ambiguousParameters
        } else {
            finalQuery = [:]
            finalAmbiguousParameters = nil
        }
        endpoint = metadata.endpoint
        endpointDigest = metadata.endpointDigest
        finalEndpoint = metadata.finalEndpoint
        statusCode = metadata.statusCode
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
    static func capture(request: URLRequest, response: HTTPURLResponse, body: Data, finalRequest: URLRequest? = nil) async -> Self {
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


struct NetworkSmokeRequestEvidence: Codable {
    let probe: String
    let requests: [NetworkSmokeHTTPRequestEvidence]
    var expectedParameters: [String: String] = [:]
}

@MainActor
final class NetworkSmokeRequestCollector {
    private(set) var requests: [NetworkSmokeHTTPRequestEvidence] = []

    func perform<Value>(_ operation: () async throws -> Value, required: Bool, expectedParameters: [String: String] = [:]) async throws -> Value {
        requests = []
        let value = try await HTTPRequestEvidenceContext.$didReceive.withValue({ [self] request, response in
            let evidence = await NetworkSmokeHTTPRequestEvidence.capture(request: request, response: response.response, body: response.data, finalRequest: response.finalRequest)
            guard !Task.isCancelled else { return }
            requests.append(evidence) }) {
            try await operation()
        }
        if required && requests.isEmpty { throw NetworkSmokeRequestError.missingResponse }
        if required {
            for request in requests {
                if let key = (request.ambiguousParameters ?? []).first ?? (request.finalAmbiguousParameters ?? []).first {
                    throw NetworkSmokeRequestError.parameterMismatch(key)
                }
            }
            try checkCourseActivityRequests()
            if let resources = expectedParameters["resourceDigests"] {
                let expected = Set(resources.split(separator: ",").map(String.init))
                let observed = Set(requests.filter { (200..<300).contains($0.statusCode) }.map(\.endpointDigest))
                guard !expected.isEmpty, observed == expected
                else { throw NetworkSmokeRequestError.parameterMismatch("resourceDigests") }
            }
            for (key, expected) in expectedParameters where key != "resourceDigests" {
                let observed = requests.compactMap { request -> String? in
                    guard key == "path" else { return request.query[key] }
                    guard let path = URLComponents(string: request.endpoint)?.path,
                          path.split(separator: "/").dropLast() == expected.split(separator: "/").dropLast() else { return nil }
                    return path
                }
                guard !observed.isEmpty, observed.allSatisfy({ $0 == expected }) else {
                    throw NetworkSmokeRequestError.parameterMismatch(key)
                }
            }
        }
        return value
    }

    private func checkCourseActivityRequests() throws {
        let successful = requests.filter { (200..<300).contains($0.statusCode) }
        let pages = successful.filter { $0.endpoint == "https://zy-eclass.bit.edu.cn/api/my-courses" }
        guard !pages.isEmpty else { return }
        guard pages.allSatisfy({ $0.responseCourseIDs != nil }) else { throw NetworkSmokeRequestError.missingResponse }
        let expected = Set(pages.flatMap { $0.responseCourseIDs ?? [] })
        let activities = successful.filter { $0.endpoint.hasPrefix("https://zy-eclass.bit.edu.cn/api/courses/") && $0.endpoint.hasSuffix("/activities") }
        let observed = Set(activities.compactMap { URL(string: $0.endpoint)?.pathComponents.dropFirst(3).first })
        guard observed == expected, activities.allSatisfy({ $0.endpoint == $0.finalEndpoint })
        else { throw NetworkSmokeRequestError.parameterMismatch("courseID") }
    }
}

nonisolated enum NetworkSmokeRequestError: LocalizedError {
    case missingResponse
    case parameterMismatch(String)
    var errorDescription: String? {
        switch self {
        case .missingResponse: "探针需要实际请求端点与 HTTP 响应记录。"
        case .parameterMismatch(let key): "探针请求参数 \(key) 与业务输入存在差异。"
        }
    }
}
