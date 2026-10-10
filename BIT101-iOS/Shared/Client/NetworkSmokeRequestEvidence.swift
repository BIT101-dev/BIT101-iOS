import Foundation
import TransportCore

struct NetworkSmokeRequestEvidence: Codable {
    let probe: String
    let requests: [HTTPRequestEvidence]
    var expectedParameters: [String: String] = [:]
}

@MainActor
final class NetworkSmokeRequestCollector {
    private(set) var requests: [HTTPRequestEvidence] = []

    func perform<Value>(_ operation: () async throws -> Value, required: Bool, expectedParameters: [String: String] = [:]) async throws -> Value {
        requests = []
        let value = try await HTTPRequestEvidenceContext.$didReceive.withValue({ [self] in requests.append($0) }) {
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
            for (key, expected) in expectedParameters {
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
