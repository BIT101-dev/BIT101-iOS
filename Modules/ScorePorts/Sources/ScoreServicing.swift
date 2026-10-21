import ScoreDomain
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


/// 成绩缓存读取错误保留受保护文件与清理状态的恢复原因。
public nonisolated enum ScoreCacheReadError: LocalizedError {
    case unreadable
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unreadable: "本机成绩缓存读取受阻，原文件已保留。请解锁设备后重试，也可重新查询在线成绩。"
        case .unavailable: "本机数据清理处理中，请稍后重试。"
        }
    }
}

public nonisolated enum ScoreCacheWriteError: LocalizedError {
    case failed
    public var errorDescription: String? { "本机成绩缓存保存失败，原始记录已保留。请稍后重试同步。" }
}

/// 成绩场景消费的缓存能力，具体持久化由应用组装层选择。
@MainActor
public protocol ScoreCaching: AnyObject {
    /// 成功写入本地或云端快照后发布所属账号。
    var changes: AnyPublisher<AppStorageSession, Never> { get }
    func loadSnapshot(for session: AppStorageSession?) async throws -> ScoreCacheSnapshot?
    func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date?
    func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date?
}

/// 云同步消费版本快照，并在写入时核对读取时的本地内容。
@MainActor
public protocol ScoreCacheSynchronizing: ScoreCaching {
    var localSaves: AnyPublisher<AppStorageSession, Never> { get }
    func syncPayload(for session: AppStorageSession?) async throws -> ScoreCacheSyncPayload?
    func applySynced(_ payload: ScoreCacheSyncPayload, for session: AppStorageSession?, replacing expected: ScoreCacheSyncPayload?) async throws -> Bool
}

@MainActor
public protocol ScoreFilterPreferencesStoring: AnyObject {
    /// 本地保存和外部导入发布同一实例的账号变更。
    var changes: AnyPublisher<AppStorageSession, Never> { get }
    var hasUnreadableSnapshot: Bool { get }
    func load() -> ScoreFilterPreferenceSnapshot?
    @discardableResult
    func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) -> Bool
}

/// 可信成绩单按页数、传输字节和完整页面集合的位图预算准备。
public nonisolated struct TrustedTranscriptResourceLimits: Sendable {
    public let maximumPageCount: Int
    public let maximumEncodedBytes: Int
    public let maximumDecodedBytes: Int

    public init(maximumPageCount: Int = 64, maximumEncodedBytes: Int = 32 * 1_024 * 1_024,
                maximumDecodedBytes: Int = 48 * 1_024 * 1_024) {
        self.maximumPageCount = maximumPageCount
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}
