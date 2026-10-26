import Foundation
import CryptoKit

/// HTTP 方法、响应位置和状态的脱敏传输事实。
public nonisolated struct HTTPRequestEvidence: Codable, Sendable {
    public let method: String
    public let endpoint: String
    public let endpointDigest: String
    public let finalEndpoint: String
    public let finalMethod: String
    public let statusCode: Int

    public init(request: URLRequest, response: HTTPURLResponse, finalRequest: URLRequest? = nil) {
        method = request.httpMethod ?? "GET"
        if let finalRequest { finalMethod = finalRequest.httpMethod ?? "GET" }
        else if response.url == request.url { finalMethod = method }
        else { finalMethod = "" }
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
}

public nonisolated enum HTTPRequestEvidenceContext {
    @TaskLocal public static var didReceive: (@MainActor @Sendable (URLRequest, HTTPResponse) async -> Void)?
    @TaskLocal public static var willStart: (@MainActor @Sendable () -> Void)?
    @TaskLocal public static var didReceiveFinalRequest: (@MainActor @Sendable (URLRequest) -> Void)?
    @TaskLocal public static var didReceivePartialResponse: (@MainActor @Sendable (Data?, URLResponse?) -> Void)?

    @MainActor public static func withMutationOutcome<Value: Sendable>(
        isTrackingRequest: @escaping @MainActor @Sendable () -> Bool = { true },
        operation: () async throws -> Value
    ) async throws -> Value {
        var started = false
        var rejected = false
        let parentStart = willStart
        let parentReceive = didReceive
        do {
            return try await $willStart.withValue({
                if isTrackingRequest() { started = true; rejected = false }
                parentStart?()
            }) {
                try await $didReceive.withValue({ request, response in
                    if isTrackingRequest() {
                        let evidence = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest)
                        rejected = (400..<500).contains(evidence.statusCode) && evidence.statusCode != 408
                            && evidence.endpoint == evidence.finalEndpoint && evidence.method == evidence.finalMethod
                    }
                    await parentReceive?(request, response)
                }) {
                    try await operation()
                }
            }
        } catch {
            guard started, !rejected, !ErrorChain.contains(error, matching: { $0 is HTTPRequestNotSent }) else { throw error }
            throw HTTPMutationOutcomeUnknown(underlying: error)
        }
    }
}

public nonisolated struct HTTPMutationOutcomeUnknown: LocalizedError, CustomNSError {
    public let underlying: any Error
    public init(underlying: any Error) { self.underlying = underlying }
    public var errorDescription: String? { "请求已发出，操作结果待确认。" }
    public var errorUserInfo: [String: Any] {
        [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: errorDescription ?? "操作结果待确认。"]
    }
}
