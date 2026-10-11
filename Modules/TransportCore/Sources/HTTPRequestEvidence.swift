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
}
