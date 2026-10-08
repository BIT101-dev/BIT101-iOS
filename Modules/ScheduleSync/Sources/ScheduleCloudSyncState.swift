import ScheduleDomain
import Foundation

public nonisolated enum ScheduleCloudSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case pending
    case synchronized
    case unavailable
    case conflict
    case failed(String)
}


/// Baseline tags identify known concurrent writes; timestamps resolve incomplete baselines.
public nonisolated enum ScheduleCacheReconciliationDecision: Equatable {
    case applyRemote
    case uploadLocal
    case noChange
}

public nonisolated enum ScheduleCacheReconciliationPolicy {
    public static func decision(
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        allowsRemoteApply: Bool
    ) -> ScheduleCacheReconciliationDecision {
        if allowsRemoteApply, remoteUpdatedAt > localUpdatedAt {
            return .applyRemote
        }
        if localUpdatedAt > remoteUpdatedAt {
            return .uploadLocal
        }
        return .noChange
    }

    public static func hasConcurrentChanges(
        localHasUnpushedChanges: Bool,
        localBaselineRecordTag: String,
        remoteRecordTag: String,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date
    ) -> Bool {
        guard localHasUnpushedChanges else { return false }
        guard !localBaselineRecordTag.isEmpty, !remoteRecordTag.isEmpty else {
            return remoteUpdatedAt > localUpdatedAt
        }
        return localBaselineRecordTag != remoteRecordTag
    }
}

/// Versioned envelope keeps older-client reads distinct from the local cache format.
nonisolated struct ScheduleCloudSyncEnvelope: Codable {
    let schemaVersion: Int
    // Keep the timestamp nested so legacy decoders treat this as a distinct payload format.
    let payload: Payload

    static let currentSchemaVersion = 2

    nonisolated struct Payload: Codable, Sendable {
        let updatedAt: Date
        let state: ScheduleCloudSyncState
    }
}

nonisolated struct DecodedScheduleCloudCache {
    let cache: ScheduleCache
    let requiresPayloadMigration: Bool
}
