//
//  ScheduleCloudSyncManager.swift
//  BIT101-iOS
//
//  CloudKit transport and reconciliation for the account-scoped schedule cache.
//

import Foundation
#if canImport(os)
import os
#endif
#if canImport(CloudKit)
import CloudKit

/// Timestamp-only conflict policy used by CloudKit reconciliation.
///
/// Keeping the decision pure makes the behavior testable without constructing a
/// signed CloudKit container or touching the current account's on-device cache.
nonisolated enum ScheduleCacheReconciliationDecision: Equatable {
    case applyRemote
    case uploadLocal
    case noChange
}

nonisolated enum ScheduleCacheReconciliationPolicy {
    static func decision(
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
}

actor ScheduleCloudSyncManager {
    static let shared = ScheduleCloudSyncManager()

    private enum FieldKey {
        static let studentID = "studentID"
        static let payloadJSON = "payloadJSON"
        static let updatedAt = "updatedAt"
    }

    /// CloudKit containers require a signed host carrying the iCloud entitlement.
    /// Resolve it only after the persisted opt-in check, so unit-test hosts and
    /// unsigned simulator builds can launch without touching CloudKit.
    private var container: CKContainer { CKContainer.default() }
    private let recordType = "ScheduleCacheSyncRecord"
    #if canImport(os)
    private let logger = Logger(subsystem: "BIT101", category: "ScheduleCloudSync")
    #endif
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func refreshFromCloudIfNeeded() async {
        let localCache = await MainActor.run { ScheduleCacheStore.load() }
        guard localCache.iCloudSyncEnabled else {
            logDebug("skip refresh: iCloud sync disabled")
            return
        }
        await reconcile(localCache: localCache, allowCloudApply: true)
    }

    func reconcileAfterEnabling(localCache: ScheduleCache) async {
        logDebug("reconcile after enabling")
        await reconcile(localCache: localCache, allowCloudApply: true)
    }

    func pushLatestLocalCacheIfNeeded() async {
        let localCache = await MainActor.run { ScheduleCacheStore.load() }
        guard localCache.iCloudSyncEnabled else {
            logDebug("skip push: iCloud sync disabled")
            return
        }
        do {
            _ = try await upsert(remoteWith: localCache)
        } catch {
            logError("push latest local cache failed: \(describe(error))")
        }
    }

    private func reconcile(localCache: ScheduleCache, allowCloudApply: Bool) async {
        guard let recordID = await currentRecordID() else {
            logDebug("skip reconcile: current student id is empty")
            return
        }

        let accountStatus = await accountStatusText()
        logDebug(
            "reconcile start record=\(recordID.recordName) accountStatus=\(accountStatus) localUpdatedAt=\(debugDate(localCache.updatedAt)) allowCloudApply=\(allowCloudApply)"
        )

        do {
            let remoteRecord = try await container.privateCloudDatabase.record(for: recordID)
            guard let remoteCache = decodeCache(from: remoteRecord) else {
                logError("reconcile abort: remote payload decode failed record=\(recordID.recordName)")
                return
            }

            logDebug(
                "reconcile fetched remoteUpdatedAt=\(debugDate(remoteCache.updatedAt)) localUpdatedAt=\(debugDate(localCache.updatedAt))"
            )

            switch ScheduleCacheReconciliationPolicy.decision(
                localUpdatedAt: localCache.updatedAt,
                remoteUpdatedAt: remoteCache.updatedAt,
                allowsRemoteApply: allowCloudApply
            ) {
            case .applyRemote:
                let cacheToApply: ScheduleCache = {
                    var cache = remoteCache
                    cache.iCloudSyncEnabled = true
                    return cache
                }()
                logDebug("applying remote cache to local")
                await MainActor.run {
                    ScheduleCacheStore.save(cacheToApply, source: .cloud)
                }
                return
            case .uploadLocal:
                logDebug("local cache newer than remote; uploading local copy")
                _ = try? await upsert(remoteWith: localCache)
            case .noChange:
                logDebug("reconcile no-op: remote not newer and local not newer")
            }
        } catch let error as CKError {
            if error.code == .unknownItem || error.code == .serverRejectedRequest {
                logDebug("remote record unavailable (\(error.code.rawValue)); uploading initial local cache")
                var initialUpload = localCache
                if initialUpload.updatedAt == .distantPast {
                    initialUpload.updatedAt = Date()
                }
                do {
                    _ = try await upsert(remoteWith: initialUpload)
                } catch {
                    logError("initial upload after unknownItem failed: \(describe(error))")
                }
            } else {
                logError("reconcile cloud error: \(describe(error))")
            }
        } catch {
            logError("reconcile failed: \(describe(error))")
        }
    }

    private func upsert(remoteWith cache: ScheduleCache) async throws -> CKRecord {
        guard let recordID = await currentRecordID() else {
            throw CKError(.badContainer)
        }

        logDebug("upsert start record=\(recordID.recordName) updatedAt=\(debugDate(cache.updatedAt))")

        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: recordID)
            logDebug("upsert fetched existing remote record")
        } catch let error as CKError where error.code == .unknownItem || error.code == .serverRejectedRequest {
            record = CKRecord(recordType: recordType, recordID: recordID)
            logDebug("upsert will create new remote record after fetch error code=\(error.code.rawValue)")
        }

        let payloadJSON = try await encodeCache(cache)
        record[FieldKey.studentID] = await currentStudentID() as CKRecordValue
        record[FieldKey.updatedAt] = cache.updatedAt as CKRecordValue
        record[FieldKey.payloadJSON] = payloadJSON as CKRecordValue
        let saved = try await container.privateCloudDatabase.save(record)
        logDebug("upsert saved remote record successfully")
        return saved
    }

    private func decodeCache(from record: CKRecord) -> ScheduleCache? {
        if let payloadJSON = record[FieldKey.payloadJSON] as? String {
            return try? decoder.decode(ScheduleCache.self, from: Data(payloadJSON.utf8))
        }
        return nil
    }

    private func currentRecordID() async -> CKRecord.ID? {
        let studentID = await currentStudentID()
        guard !studentID.isEmpty else { return nil }
        let account = await MainActor.run { ScheduleCacheStore.currentAccountIdentifier() }
        return CKRecord.ID(recordName: "schedule-cache-\(account)")
    }

    private func currentStudentID() async -> String {
        await MainActor.run {
            LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func encodeCache(_ cache: ScheduleCache) async throws -> String {
        let data = try encoder.encode(cache)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return json
    }

    private func accountStatusText() async -> String {
        do {
            let status = try await container.accountStatus()
            return switch status {
            case .available: "available"
            case .couldNotDetermine: "couldNotDetermine"
            case .noAccount: "noAccount"
            case .restricted: "restricted"
            case .temporarilyUnavailable: "temporarilyUnavailable"
            @unknown default: "unknown"
            }
        } catch {
            return "error:\(describe(error))"
        }
    }

    private func debugDate(_ date: Date) -> String {
        if date == .distantPast {
            return "distantPast"
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            let userInfoSummary = ckError.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            return "CKError(code=\(ckError.code.rawValue) \(ckError.code), localized=\(ckError.localizedDescription), userInfo=[\(userInfoSummary)])"
        }
        return error.localizedDescription
    }

    private func logDebug(_ message: String) {
        #if canImport(os)
        logger.debug("\(message, privacy: .private)")
        #endif
    }

    private func logError(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .private)")
        #endif
    }
}
#endif
