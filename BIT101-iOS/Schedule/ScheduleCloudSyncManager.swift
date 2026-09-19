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

    private struct CloudAccountContext: Equatable, Sendable {
        let studentID: String
        let accountIdentifier: String

        var recordID: CKRecord.ID {
            CKRecord.ID(recordName: "schedule-cache-\(accountIdentifier)")
        }
    }

    private struct LocalCloudState {
        let cache: ScheduleCache
        let account: CloudAccountContext
    }

    private struct PendingLocalCache {
        let cache: ScheduleCache
        let account: CloudAccountContext
    }

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
    private var pendingLocalCache: PendingLocalCache?
    private var isPushingLocalCache = false

    func refreshFromCloudIfNeeded() async {
        guard let localState = await currentLocalCloudState() else {
            logDebug("skip refresh: iCloud sync disabled")
            return
        }
        await reconcile(
            localCache: localState.cache,
            account: localState.account,
            allowCloudApply: true
        )
    }

    func reconcileAfterEnabling(localCache: ScheduleCache) async {
        guard localCache.iCloudSyncEnabled else { return }
        logDebug("reconcile after enabling")
        guard let localState = await currentLocalCloudState() else { return }
        await reconcile(
            localCache: localState.cache,
            account: localState.account,
            allowCloudApply: true
        )
    }

    func pushLatestLocalCacheIfNeeded() async {
        guard let localState = await currentLocalCloudState() else {
            logDebug("skip push: iCloud sync disabled")
            return
        }
        pendingLocalCache = PendingLocalCache(cache: localState.cache, account: localState.account)
        guard !isPushingLocalCache else { return }

        isPushingLocalCache = true
        defer { isPushingLocalCache = false }
        while let pendingLocalCache {
            self.pendingLocalCache = nil
            guard await isCurrentCloudState(for: pendingLocalCache.account),
                  await hasAvailableCloudAccount()
            else { continue }
            do {
                _ = try await upsert(
                    remoteWith: pendingLocalCache.cache,
                    account: pendingLocalCache.account,
                    expectedLocalUpdatedAt: pendingLocalCache.cache.updatedAt
                )
            } catch {
                logError("push latest local cache failed: \(describe(error))")
            }
        }
    }

    private func reconcile(
        localCache: ScheduleCache,
        account: CloudAccountContext,
        allowCloudApply: Bool
    ) async {
        guard localCache.iCloudSyncEnabled,
              await isCurrentCloudState(for: account),
              await hasAvailableCloudAccount()
        else { return }

        logDebug(
            "reconcile start record=\(account.recordID.recordName) localUpdatedAt=\(debugDate(localCache.updatedAt)) allowCloudApply=\(allowCloudApply)"
        )

        do {
            let remoteRecord = try await container.privateCloudDatabase.record(for: account.recordID)
            guard await isCurrentCloudState(for: account) else { return }
            guard let remoteCache = decodeCache(
                from: remoteRecord,
                expectedStudentID: account.studentID
            ) else {
                logError("reconcile abort: remote payload decode failed record=\(account.recordID.recordName)")
                return
            }
            guard let currentLocalState = await currentLocalCloudState(matching: account) else { return }

            logDebug(
                "reconcile fetched remoteUpdatedAt=\(debugDate(remoteCache.updatedAt)) localUpdatedAt=\(debugDate(currentLocalState.cache.updatedAt))"
            )

            switch ScheduleCacheReconciliationPolicy.decision(
                localUpdatedAt: currentLocalState.cache.updatedAt,
                remoteUpdatedAt: remoteCache.updatedAt,
                allowsRemoteApply: allowCloudApply
            ) {
            case .applyRemote:
                var cacheToApply = remoteCache
                cacheToApply.iCloudSyncEnabled = true
                logDebug("applying remote cache to local")
                _ = await applyRemoteCacheIfCurrent(
                    cacheToApply,
                    account: account,
                    expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                )
                return
            case .uploadLocal:
                logDebug("local cache newer than remote; uploading local copy")
                do {
                    _ = try await upsert(
                        remoteWith: currentLocalState.cache,
                        account: account,
                        expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                    )
                } catch {
                    logError("reconcile local upload failed: \(describe(error))")
                }
            case .noChange:
                logDebug("reconcile no-op: remote not newer and local not newer")
            }
        } catch let error as CKError {
            if error.code == .unknownItem {
                logDebug("remote record unavailable (\(error.code.rawValue)); uploading initial local cache")
                guard let currentLocalState = await currentLocalCloudState(matching: account) else { return }
                var initialUpload = currentLocalState.cache
                if initialUpload.updatedAt == .distantPast {
                    initialUpload.updatedAt = Date()
                }
                do {
                    let didUpload = try await upsert(
                        remoteWith: initialUpload,
                        account: account,
                        expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                    )
                    if didUpload, currentLocalState.cache.updatedAt == .distantPast {
                        await persistUpdatedAtIfCurrent(
                            initialUpload.updatedAt,
                            account: account,
                            expectedLocalUpdatedAt: .distantPast
                        )
                    }
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

    @discardableResult
    private func upsert(
        remoteWith cache: ScheduleCache,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date?
    ) async throws -> Bool {
        guard cache.iCloudSyncEnabled,
              await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt)
        else { return false }

        logDebug("upsert start record=\(account.recordID.recordName) updatedAt=\(debugDate(cache.updatedAt))")

        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: account.recordID)
            logDebug("upsert fetched existing remote record")
            guard let remoteCache = decodeCache(from: record, expectedStudentID: account.studentID) else {
                logError("upsert abort: remote payload decode failed record=\(account.recordID.recordName)")
                return false
            }
            guard cache.updatedAt > remoteCache.updatedAt else {
                logDebug("upsert skipped: remote cache is as new or newer")
                return false
            }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: account.recordID)
            logDebug("upsert will create new remote record after fetch error code=\(error.code.rawValue)")
        }

        return try await save(
            record,
            cache: cache,
            account: account,
            expectedLocalUpdatedAt: expectedLocalUpdatedAt,
            retryOnConflict: true
        )
    }

    private func save(
        _ record: CKRecord,
        cache: ScheduleCache,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date?,
        retryOnConflict: Bool
    ) async throws -> Bool {
        guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
            return false
        }

        let payloadJSON = try encodeCache(cache)
        record[FieldKey.studentID] = account.studentID as CKRecordValue
        record[FieldKey.updatedAt] = cache.updatedAt as CKRecordValue
        record[FieldKey.payloadJSON] = payloadJSON as CKRecordValue

        do {
            _ = try await container.privateCloudDatabase.save(record)
            logDebug("upsert saved remote record successfully")
            return true
        } catch let error as CKError where retryOnConflict && error.code == .serverRecordChanged {
            logDebug("upsert conflict detected; refetching remote record")
            let currentRemoteRecord = try await container.privateCloudDatabase.record(for: account.recordID)
            guard let currentRemoteCache = decodeCache(
                from: currentRemoteRecord,
                expectedStudentID: account.studentID
            ) else {
                logError("upsert conflict resolution aborted: remote payload decode failed")
                return false
            }
            guard cache.updatedAt > currentRemoteCache.updatedAt else {
                logDebug("upsert conflict resolution skipped: remote cache is newer")
                return false
            }
            return try await save(
                currentRemoteRecord,
                cache: cache,
                account: account,
                expectedLocalUpdatedAt: expectedLocalUpdatedAt,
                retryOnConflict: false
            )
        }
    }

    private func decodeCache(from record: CKRecord, expectedStudentID: String) -> ScheduleCache? {
        guard record.recordType == recordType,
              let storedStudentID = record[FieldKey.studentID] as? String,
              storedStudentID == expectedStudentID,
              let storedUpdatedAt = record[FieldKey.updatedAt] as? Date,
              let payloadJSON = record[FieldKey.payloadJSON] as? String,
              var cache = try? decoder.decode(ScheduleCache.self, from: Data(payloadJSON.utf8))
        else { return nil }

        // JSON ISO-8601 encoding can lose sub-second precision; accept that
        // serialization difference while rejecting unrelated timestamp values.
        guard abs(storedUpdatedAt.timeIntervalSince(cache.updatedAt)) <= 1.1 else { return nil }
        return cache
    }

    private func hasAvailableCloudAccount() async -> Bool {
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                logDebug("skip cloud operation: iCloud account status=\(status.rawValue)")
                return false
            }
            return true
        } catch {
            logError("cloud account status query failed: \(describe(error))")
            return false
        }
    }

    private func currentLocalCloudState() async -> LocalCloudState? {
        await MainActor.run {
            let cache = ScheduleCacheStore.load()
            guard cache.iCloudSyncEnabled else { return nil }

            let studentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !studentID.isEmpty else { return nil }

            let account = CloudAccountContext(
                studentID: studentID,
                accountIdentifier: ScheduleCacheStore.currentAccountIdentifier()
            )
            return LocalCloudState(cache: cache, account: account)
        }
    }

    private func currentLocalCloudState(matching account: CloudAccountContext) async -> LocalCloudState? {
        await MainActor.run {
            let cache = ScheduleCacheStore.load()
            let studentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: studentID,
                accountIdentifier: ScheduleCacheStore.currentAccountIdentifier()
            )
            guard currentAccount == account, cache.iCloudSyncEnabled else { return nil }
            return LocalCloudState(cache: cache, account: currentAccount)
        }
    }

    private func isCurrentCloudState(
        for account: CloudAccountContext,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        guard let localState = await currentLocalCloudState(matching: account) else { return false }
        guard let expectedUpdatedAt else { return true }
        return localState.cache.updatedAt == expectedUpdatedAt
    }

    private func applyRemoteCacheIfCurrent(
        _ cache: ScheduleCache,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date
    ) async -> Bool {
        await MainActor.run {
            let currentStudentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: currentStudentID,
                accountIdentifier: ScheduleCacheStore.currentAccountIdentifier()
            )
            guard currentAccount == account else { return false }

            let currentCache = ScheduleCacheStore.load()
            guard currentCache.iCloudSyncEnabled,
                  currentCache.updatedAt == expectedLocalUpdatedAt
            else { return false }

            ScheduleCacheStore.save(cache, source: .cloud)
            return true
        }
    }

    private func persistUpdatedAtIfCurrent(
        _ updatedAt: Date,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date
    ) async {
        await MainActor.run {
            let currentStudentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: currentStudentID,
                accountIdentifier: ScheduleCacheStore.currentAccountIdentifier()
            )
            guard currentAccount == account else { return }

            var currentCache = ScheduleCacheStore.load()
            guard currentCache.iCloudSyncEnabled,
                  currentCache.updatedAt == expectedLocalUpdatedAt
            else { return }

            currentCache.updatedAt = updatedAt
            ScheduleCacheStore.save(currentCache, source: .cloud)
        }
    }

    private func encodeCache(_ cache: ScheduleCache) throws -> String {
        let data = try encoder.encode(cache)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return json
    }

    private func debugDate(_ date: Date) -> String {
        if date == .distantPast {
            return "distantPast"
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            let userInfoKeys = ckError.userInfo.keys
                .map { String(describing: $0) }
                .sorted()
                .joined(separator: ", ")
            return "CKError(code=\(ckError.code.rawValue) \(ckError.code), localized=\(ckError.localizedDescription), userInfoKeys=[\(userInfoKeys)])"
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
