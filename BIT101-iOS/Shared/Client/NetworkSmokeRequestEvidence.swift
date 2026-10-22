import Foundation
import CoreFoundation
import TransportCore
import GalleryFeature
import PaperFeature

nonisolated struct NetworkSmokeConfigurationEvidence: Codable, Sendable {
    let content: String
    let enabled: Bool
    let noticeID: String?
}

nonisolated struct NetworkSmokeCoursePageEvidence: Codable, Sendable {
    let page: Int?
    let pages: Int?
}

nonisolated struct NetworkSmokeHTTPRequestEvidence: Codable, Sendable {
    let method: String
    let endpoint: String
    let endpointDigest: String
    let finalEndpoint: String
    let finalMethod: String
    let finalQuery: [String: String]
    let bodyParameterNames: [String]
    let finalBodyParameterNames: [String]
    let statusCode: Int
    let query: [String: String]
    let ambiguousParameters: [String]?
    let finalAmbiguousParameters: [String]?
    let responseMinimumID: String?
    let responseCourseIDs: [String]?
    let responseCoursePage: NetworkSmokeCoursePageEvidence?
    let responseConfiguration: NetworkSmokeConfigurationEvidence?
    let responseContentMissing: Bool?

    init(request: URLRequest, response: HTTPURLResponse, responseMinimumID: String? = nil, responseCourseIDs: [String]? = nil,
         responseCoursePage: NetworkSmokeCoursePageEvidence? = nil,
         responseConfiguration: NetworkSmokeConfigurationEvidence? = nil, responseContentMissing: Bool? = nil, finalRequest: URLRequest? = nil) {
        self.responseMinimumID = responseMinimumID
        self.responseCourseIDs = responseCourseIDs
        self.responseCoursePage = responseCoursePage
        self.responseConfiguration = responseConfiguration
        self.responseContentMissing = responseContentMissing
        let metadata = HTTPRequestEvidence(request: request, response: response, finalRequest: finalRequest)
        method = metadata.method
        finalMethod = metadata.finalMethod
        let originalParameters = Self.parameters(request)
        query = originalParameters.values
        bodyParameterNames = originalParameters.bodyNames
        ambiguousParameters = originalParameters.ambiguous
        if let finalRequest {
            let parameters = Self.parameters(finalRequest)
            finalQuery = parameters.values
            finalBodyParameterNames = parameters.bodyNames
            finalAmbiguousParameters = parameters.ambiguous
        } else if response.url == request.url {
            finalQuery = query
            finalBodyParameterNames = bodyParameterNames
            finalAmbiguousParameters = ambiguousParameters
        } else {
            finalQuery = [:]
            finalBodyParameterNames = []
            finalAmbiguousParameters = nil
        }
        endpoint = metadata.endpoint
        endpointDigest = metadata.endpointDigest
        finalEndpoint = metadata.finalEndpoint
        statusCode = metadata.statusCode
    }

    private static func parameters(_ request: URLRequest) -> (values: [String: String], ambiguous: [String]?, bodyNames: [String]) {
        let endpoint = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let allowed = Set(["page", "last_id", "obj", "order", "mode", "type", "uid", "detail", "detailed", "search", "hide_bot",
                           "XNXQDM", "JXLDM", "XXXQDM", "dicCode", "SFSY", "RQ", "XQDM", "XNDM", "GPA", "page_size", "fields", "conditions", "appName", "EMAP_LANG"])
        var parameters: [String: [String]] = [:]
        var occurrences: [String: Int] = [:]
        var jsonAmbiguities = Set<String>()
        var bodyNames = Set<String>()
        for item in endpoint?.queryItems ?? [] {
            occurrences[item.name, default: 0] += 1
            parameters[item.name, default: []].append(allowed.contains(item.name) ? item.value ?? "" : "[REDACTED]")
        }
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true,
           let body = request.httpBody, let encoded = String(data: body, encoding: .utf8),
           let form = URLComponents(string: "?" + encoded.replacingOccurrences(of: "+", with: "%20"))?.queryItems {
            bodyNames.formUnion(form.map(\.name))
            for item in form {
                occurrences[item.name, default: 0] += 1
                if allowed.contains(item.name) { parameters[item.name, default: []].append(item.value ?? "") }
            }
            for item in form where item.name == "requestParamStr" {
                let projected = Self.jsonObject(Data((item.value ?? "").utf8))
                jsonAmbiguities.formUnion(projected.ambiguous)
                for (name, value) in projected.object ?? [:] {
                    occurrences[name, default: 0] += 1
                    bodyNames.insert("requestParamStr." + name)
                    if allowed.contains(name), let text = value as? String { parameters[name, default: []].append(text) }
                }
            }
        }
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
           let body = request.httpBody {
            let encryptedSchoolBody = request.url?.scheme == "https" && request.url?.host == "sso.bit.edu.cn"
                && request.url?.path == "/cas/api/protected/sms/getPhoneNumberByUserId"
                && request.value(forHTTPHeaderField: "hasCrypto")?.lowercased() == "true"
            if encryptedSchoolBody {
                let ambiguous = Set(occurrences.filter { $0.value > 1 }.keys).union(jsonAmbiguities)
                let values = parameters.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { !ambiguous.contains($0.key) }
                return (values, ambiguous.isEmpty ? nil : ambiguous.sorted(), bodyNames.sorted())
            }
            let projected = Self.jsonObject(body)
            jsonAmbiguities.formUnion(projected.ambiguous)
            for (name, value) in projected.object ?? [:] {
                occurrences[name, default: 0] += 1
                bodyNames.insert(name)
                guard allowed.contains(name) else { continue }
                let text: String
                if name == "detail" || name == "detailed" {
                    if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { text = String(flag.boolValue) }
                    else { text = "[REDACTED]" }
                }
                else if name == "conditions", let conditions = value as? [String: Any], conditions.isEmpty { text = "{}" }
                else if let string = value as? String { text = string }
                else if let number = value as? NSNumber { text = number.stringValue }
                else { text = "[REDACTED]" }
                let validObject = name != "obj" || text.range(of: "^(poster|paper|course|comment)[1-9][0-9]*$", options: .regularExpression) != nil
                parameters[name, default: []].append(validObject ? text : "[REDACTED]")
            }
        }
        let ambiguous = Set(occurrences.filter { $0.value > 1 }.keys).union(jsonAmbiguities)
        let values = parameters.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { !ambiguous.contains($0.key) }
        return (values, ambiguous.isEmpty ? nil : ambiguous.sorted(), bodyNames.sorted())
    }

    private static func jsonObject(_ data: Data) -> (object: [String: Any]?, ambiguous: Set<String>) {
        guard let source = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scanner = try? NSRegularExpression(pattern: #""(?:\\[\s\S]|[^"\\])*"|[{}\[\]:,]"#)
        else { return (nil, ["JSON"]) }
        // Foundation 验证 JSON 语法；词法扫描保留每个对象原始的成员键。
        let tokens = scanner.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        var objects: [Set<String>] = []
        var duplicateKeys = Set<String>()
        for (index, token) in tokens.enumerated() {
            if token == "{" { objects.append([]) }
            else if token == "}" { objects.removeLast() }
            else if token.hasPrefix("\""), index + 1 < tokens.count, tokens[index + 1] == ":",
                    let key = try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed) as? String {
                if !objects[objects.count - 1].insert(key).inserted { duplicateKeys.insert(key) }
            }
        }
        return (object, duplicateKeys)
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
        let coursePage: NetworkSmokeCoursePageEvidence?
        if request.url?.host == "zy-eclass.bit.edu.cn", request.url?.path == "/api/my-courses",
           let page = try? JSONDecoder().decode(CoursePageEvidence.self, from: body), page.courses.allSatisfy({ $0.id > 0 }) {
            courseIDs = page.courses.map { String($0.id) }
            coursePage = .init(page: page.page, pages: page.pages)
        } else { courseIDs = nil; coursePage = nil }
        let configuration: NetworkSmokeConfigurationEvidence?
        if request.url?.host == "update.aihelpme.dev", request.url?.path == "/emergency-update.json",
           let envelope = try? JSONDecoder().decode(EmergencyConfiguration.self, from: body), envelope.schemaVersion == 1 {
            configuration = .init(content: body.base64EncodedString(),
                enabled: envelope.enabled, noticeID: envelope.noticeID)
        } else { configuration = nil }
        var contentMissing: Bool?
        if request.httpMethod == "GET", request.url?.host == "bit101.flwfdd.xyz", response.url?.host == request.url?.host,
           response.url?.path == request.url?.path, [400, 404, 500].contains(response.statusCode) {
            let path = request.url?.path ?? ""
            let message = HTTPClient.errorMessage(from: body)
            if case .missingPoster? = await GalleryServiceError.communityResourceFailure(path: path, message: message) { contentMissing = true }
            if case .missingPaper? = await PaperServiceError.communityResourceFailure(path: path, message: message) { contentMissing = true }
        }
        return Self(request: request, response: response, responseMinimumID: cursor, responseCourseIDs: courseIDs,
            responseCoursePage: coursePage, responseConfiguration: configuration, responseContentMissing: contentMissing, finalRequest: finalRequest)
    }

    private struct EmergencyConfiguration: Decodable {
        let schemaVersion: Int
        let enabled: Bool
        let noticeID: String?
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", enabled, noticeID = "notice_id"
        }
    }

    private struct CoursePageEvidence: Decodable {
        struct Course: Decodable { let id: Int }
        let courses: [Course]
        let page: Int?
        let pages: Int?
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
            if let excluded = expectedParameters["excludedSearch"] {
                guard let included = expectedParameters["search"], !included.isEmpty, !excluded.isEmpty, included != excluded
                else { throw NetworkSmokeRequestError.parameterMismatch("search") }
                let expected = Set([included, excluded])
                let original = Set(requests.compactMap { $0.query["search"] })
                let final = Set(requests.compactMap { $0.finalQuery["search"] })
                guard original == expected, final == expected, requests.allSatisfy({ $0.query["search"] == $0.finalQuery["search"] })
                else { throw NetworkSmokeRequestError.parameterMismatch("search") }
            }
            for (key, expected) in expectedParameters where key != "resourceDigests" && key != "excludedSearch"
                && (key != "search" || expectedParameters["excludedSearch"] == nil) {
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
        let totalPages = pages.first?.responseCoursePage?.pages
        var seen = Set<String>()
        for (index, row) in pages.enumerated() {
            guard let ids = row.responseCourseIDs, let metadata = row.responseCoursePage,
                  row.query["page"] == String(index + 1), row.finalQuery["page"] == row.query["page"],
                  metadata.page == nil || metadata.page == index + 1, metadata.pages == totalPages,
                  ids.count <= 100, ids.isEmpty || ids.contains(where: { !seen.contains($0) })
            else { throw NetworkSmokeRequestError.parameterMismatch("page") }
            seen.formUnion(ids)
            if let totalPages {
                guard totalPages >= 0, pages.count == max(1, totalPages),
                      totalPages > 0 || ids.isEmpty, !ids.isEmpty || index == pages.count - 1
                else { throw NetworkSmokeRequestError.parameterMismatch("pages") }
            } else {
                guard index == pages.count - 1 ? ids.count < 100 : ids.count == 100
                else { throw NetworkSmokeRequestError.parameterMismatch("page") }
            }
        }
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
