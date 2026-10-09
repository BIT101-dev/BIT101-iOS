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
            for (key, expected) in expectedParameters {
                let observed = requests.compactMap { $0.query[key] }
                guard !observed.isEmpty, observed.allSatisfy({ $0 == expected }) else {
                    throw NetworkSmokeRequestError.parameterMismatch(key)
                }
            }
        }
        return value
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
