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
    public let recordName: String
    public let recordType: String
    public var studentID: String?
    public var updatedAt: Date?
    public var payloadJSON: String?
    public var modificationDate: Date?
    public var recordChangeTag: String?
    public var systemFields: Data?

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

public nonisolated enum ScheduleCloudTransportError: Error, Equatable {
    case unknownItem
    case serverRecordChanged
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
