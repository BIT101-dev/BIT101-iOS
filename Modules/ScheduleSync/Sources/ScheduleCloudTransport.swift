import Foundation
import ScheduleDomain
import StorageCore

/// Account identity and login generation captured for an entire sync operation.
public nonisolated struct ScheduleCloudAccount: Equatable, Sendable {
    public let studentID: String
    public let session: AppStorageSession
    public let generation: Int

    public init(studentID: String, session: AppStorageSession, generation: Int) {
        self.studentID = studentID
        self.session = session
        self.generation = generation
    }

    public var accountIdentifier: String { session.accountDirectoryName }
    public var recordName: String { "schedule-cache-\(accountIdentifier)" }
}

/// Transport-neutral record; system fields preserve the provider's optimistic-lock token.
public nonisolated struct ScheduleCloudRecord: Sendable {
    /// CloudKit 普通字段共享 1 MB；载荷预算为身份、日期和字段元数据预留空间。
    public static let maximumPayloadBytes = 1_000_000 - 1_024
    public let recordName: String
    public let recordType: String
    public var studentID: String?
    public var updatedAt: Date?
    public var payloadJSON: String?
    public var modificationDate: Date?
    public var recordChangeTag: String?
    public var systemFields: Data?

    public func validatePayloadSize() throws {
        guard (payloadJSON?.utf8.count ?? 0) <= Self.maximumPayloadBytes else {
            throw ScheduleCloudTransportError.capacityExceeded
        }
    }

    public init(recordName: String, recordType: String, studentID: String? = nil,
                updatedAt: Date? = nil, payloadJSON: String? = nil,
                modificationDate: Date? = nil, recordChangeTag: String? = nil,
                systemFields: Data? = nil) {
        self.recordName = recordName
        self.recordType = recordType
        self.studentID = studentID
        self.updatedAt = updatedAt
        self.payloadJSON = payloadJSON
        self.modificationDate = modificationDate
        self.recordChangeTag = recordChangeTag
        self.systemFields = systemFields
    }
}

public nonisolated enum ScheduleCloudTransportError: LocalizedError, Equatable {
    case unknownItem
    case serverRecordChanged
    case capacityExceeded

    public var errorDescription: String? {
        switch self {
        case .unknownItem: "日程云记录尚待建立。"
        case .serverRecordChanged: "日程云记录已更新，请重新同步。"
        case .capacityExceeded: "日程同步内容达到容量上限。请减少已导入的分享课表或历史日程后重试，本机数据持续保留。"
        }
    }
}

public nonisolated protocol ScheduleCloudTransport: Sendable {
    func accountAvailable() async throws -> Bool
    func record(named name: String) async throws -> ScheduleCloudRecord
    func save(_ record: ScheduleCloudRecord) async throws -> ScheduleCloudRecord
}

/// The local owner performs account-generation and disk-version checks at the write boundary.
public nonisolated struct ScheduleCloudLocalStore: Sendable {
    public let currentAccount: @MainActor @Sendable () -> ScheduleCloudAccount?
    public let load: @Sendable (AppStorageSession) async -> ScheduleCacheLoadResult
    public let save: @MainActor @Sendable (ScheduleCache, ScheduleCacheSaveSource, ScheduleCloudAccount, Date?) async -> Bool

    public init(currentAccount: @escaping @MainActor @Sendable () -> ScheduleCloudAccount?,
                load: @escaping @Sendable (AppStorageSession) async -> ScheduleCacheLoadResult,
                save: @escaping @MainActor @Sendable (ScheduleCache, ScheduleCacheSaveSource, ScheduleCloudAccount, Date?) async -> Bool) {
        self.currentAccount = currentAccount
        self.load = load
        self.save = save
    }
}

public typealias ScheduleCloudConflictPresenter = @MainActor @Sendable (
    _ signature: String,
    _ resolve: @escaping @Sendable (ScheduleCacheConflictResolution?) async -> Void
) -> Void
