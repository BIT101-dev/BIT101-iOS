import StorageCore
import ClientCore
import Combine
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
    var transcriptServiceIdentity: AnyHashable { get }
    func fetchTrustedTranscriptPages() async throws -> [Data]
    func submitTranscriptSMSCode(
        _ code: String,
        for challenge: BITLoginAuthenticationChallenge
    ) async throws -> [Data]
}

public extension TrustedTranscriptServicing where Self: AnyObject {
    var transcriptServiceIdentity: AnyHashable { ObjectIdentifier(self) }
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


/// 成绩场景消费的缓存能力，具体持久化由应用组装层选择。
@MainActor
public protocol ScoreCaching: AnyObject {
    /// 成功写入本地或云端快照后发布所属账号。
    var changes: AnyPublisher<AppStorageSession, Never> { get }
    func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot?
    func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date?
    func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date?
}

/// 云同步消费版本快照，并在写入时核对读取时的本地内容。
@MainActor
public protocol ScoreCacheSynchronizing: ScoreCaching {
    var localSaves: AnyPublisher<AppStorageSession, Never> { get }
    func syncPayload(for session: AppStorageSession?) async -> ScoreCacheSyncPayload?
    func applySynced(_ payload: ScoreCacheSyncPayload, for session: AppStorageSession?, replacing expected: ScoreCacheSyncPayload?) async -> Bool
}

@MainActor
public protocol ScoreFilterPreferencesStoring: AnyObject {
    /// 本地保存和外部导入发布同一实例的账号变更。
    var changes: AnyPublisher<AppStorageSession, Never> { get }
    func load() -> ScoreFilterPreferenceSnapshot?
    func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder)
}
