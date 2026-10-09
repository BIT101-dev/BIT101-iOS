import Foundation
import TransportCore

struct NetworkSmokeRequestEvidence: Codable {
    let probe: String
    let requests: [HTTPRequestEvidence]
}

@MainActor
final class NetworkSmokeRequestCollector {
    private(set) var requests: [HTTPRequestEvidence] = []

    func perform<Value>(_ operation: () async throws -> Value, required: Bool) async throws -> Value {
        requests = []
        let value = try await HTTPRequestEvidenceContext.$didReceive.withValue({ [self] in requests.append($0) }) {
            try await operation()
        }
        if required && requests.isEmpty { throw NetworkSmokeRequestError.missingResponse }
        return value
    }
}

nonisolated enum NetworkSmokeRequestError: LocalizedError {
    case missingResponse
    var errorDescription: String? { "探针需要实际请求端点与 HTTP 响应记录。" }
}
