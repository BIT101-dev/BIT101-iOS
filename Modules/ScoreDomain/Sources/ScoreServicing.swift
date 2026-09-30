import ClientCore
import Foundation

public protocol ScoreListServicing {
    func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge
    func fetchScores(
        detail: Bool,
        authenticatedBy challenge: BITLoginAuthenticationChallenge
    ) async throws -> [ScoreRow]
    func submitScoreSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> BITLoginAuthenticationChallenge
}

public protocol TrustedTranscriptServicing {
    func fetchTrustedTranscriptPages() async throws -> [Data]
    func submitTranscriptSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data]
}

public enum ScoreServiceError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case requestTimedOut
    case secondFactorRequired(BITLoginAuthenticationChallenge)
    case challengeInvalid(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未找到已保存的学号和密码，请先重新登录。"
        case .invalidResponse:
            return "服务返回了无法识别的数据。"
        case .requestTimedOut:
            return "请求超时，请稍后重试。"
        case .secondFactorRequired:
            return "需要短信验证码才能继续执行此操作。"
        case let .challengeInvalid(message):
            return message
        case let .queryFailed(message):
            return message
        }
    }
}

