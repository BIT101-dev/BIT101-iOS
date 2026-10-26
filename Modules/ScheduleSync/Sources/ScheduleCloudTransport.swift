import Foundation
import ScheduleDomain
import StorageCore

/// Account identity and login generation captured for an entire sync operation.
public nonisolated struct ScheduleCloudAccount: Equatable, Sendable {
    public let studentID: String
    public let session: AppStorageSession
    public let generation: Int
    public let cloudGeneration: Int

    public init(studentID: String, session: AppStorageSession, generation: Int, cloudGeneration: Int = 0) {
        self.studentID = studentID
        self.session = session
        self.generation = generation
        self.cloudGeneration = cloudGeneration
    }

    public var accountIdentifier: String { session.accountDirectoryName }
    public var recordName: String { "schedule-cache-\(accountIdentifier)" }
}

/// Transport-neutral record; system fields preserve the provider's optimistic-lock token.
public nonisolated struct ScheduleCloudRecord: Sendable {
    /// CloudKit 普通字段共享 1 MB；载荷预算为身份、日期和字段元数据预留空间。
    public static let maximumPayloadBytes = 1_000_000 - 1_024
    public static let maximumDecodedPayloadBytes = ScheduleCache.maximumEncodedBytes
    public static let maximumImageAssetBytes = (DDLImagePolicy.maximumTotalBytes + 2) / 3 * 4 + maximumPayloadBytes
    public let recordName: String
    public let recordType: String
    public var studentID: String?
    public var updatedAt: Date?
    public var payloadJSON: String?
    public var modificationDate: Date?
    public var recordChangeTag: String?
    public var systemFields: Data?

    public func validatePayloadSize() throws {
        _ = try imageAssetPayload()
    }

    public func imageAssetPayload() throws -> ScheduleCloudImagePayload {
        guard (payloadJSON?.utf8.count ?? 0) <= Self.maximumDecodedPayloadBytes else {
            throw ScheduleCloudTransportError.capacityExceeded
        }
        let parts = try ScheduleCloudImagePayload.detach(payloadJSON)
        guard (parts.metadataJSON?.utf8.count ?? 0) <= Self.maximumPayloadBytes,
              (parts.imagesData?.count ?? 0) <= Self.maximumImageAssetBytes else { throw ScheduleCloudTransportError.capacityExceeded }
        return parts
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

public nonisolated struct ScheduleCloudImagePayload: Sendable {
    public let metadataJSON: String?
    public let imagesData: Data?

    fileprivate static func detach(_ json: String?) throws -> Self {
        guard let json, var envelope = decode(json),
              envelope.payload.state.manualDDLEvents.contains(where: { $0.images?.isEmpty == false }) else {
            return Self(metadataJSON: json, imagesData: nil)
        }
        var images: [String: [DDLImageAttachment]] = [:]
        var state = envelope.payload.state
        var total = 0
        for index in state.manualDDLEvents.indices {
            let event = state.manualDDLEvents[index]
            guard let values = event.images, !values.isEmpty else { continue }
            guard DDLImagePolicy.isValid(values) else { throw ScheduleCloudTransportError.capacityExceeded }
            total += values.reduce(0) { $0 + $1.data.count }
            images[event.id] = values
            state.manualDDLEvents[index].images = nil
        }
        guard total <= DDLImagePolicy.maximumTotalBytes else { throw ScheduleCloudTransportError.capacityExceeded }
        envelope = ScheduleCloudSyncEnvelope(schemaVersion: envelope.schemaVersion,
            payload: .init(updatedAt: envelope.payload.updatedAt, state: state))
        let metadata = try encoder().encode(envelope)
        return Self(metadataJSON: String(decoding: metadata, as: UTF8.self), imagesData: try encoder().encode(images))
    }

    public static func joining(metadataJSON: String?, imagesData: Data?) throws -> String? {
        guard let imagesData else { return metadataJSON }
        guard imagesData.count <= ScheduleCloudRecord.maximumImageAssetBytes,
              let metadataJSON, var envelope = decode(metadataJSON) else { throw CocoaError(.coderReadCorrupt) }
        let images = try JSONDecoder().decode([String: [DDLImageAttachment]].self, from: imagesData)
        guard images.values.allSatisfy({ DDLImagePolicy.isValid($0) }),
              images.values.reduce(0, { $0 + $1.reduce(0) { $0 + $1.data.count } }) <= DDLImagePolicy.maximumTotalBytes else {
            throw ScheduleCloudTransportError.capacityExceeded
        }
        var state = envelope.payload.state
        for index in state.manualDDLEvents.indices {
            state.manualDDLEvents[index].images = images[state.manualDDLEvents[index].id]
        }
        envelope = ScheduleCloudSyncEnvelope(schemaVersion: envelope.schemaVersion,
            payload: .init(updatedAt: envelope.payload.updatedAt, state: state))
        let restored = try encoder().encode(envelope)
        guard restored.count <= ScheduleCloudRecord.maximumDecodedPayloadBytes else { throw ScheduleCloudTransportError.capacityExceeded }
        return String(decoding: restored, as: UTF8.self)
    }

    private static func decode(_ json: String) -> ScheduleCloudSyncEnvelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScheduleCloudSyncEnvelope.self, from: Data(json.utf8))
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
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
        case .capacityExceeded: "日程同步内容达到容量上限。请减少图片、已导入的分享课表或历史日程后重试，本机数据持续保留。"
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
    _ account: ScheduleCloudAccount,
    _ signature: String,
    _ resolve: @escaping @Sendable (ScheduleCacheConflictResolution?) async -> Void
) -> Void
