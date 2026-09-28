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

    static func hasConcurrentChanges(
        localHasUnpushedChanges: Bool,
        localBaselineRecordTag: String,
        remoteRecordTag: String
    ) -> Bool {
        guard localHasUnpushedChanges else { return false }
        return localBaselineRecordTag.isEmpty || remoteRecordTag.isEmpty
            || localBaselineRecordTag != remoteRecordTag
    }
}

nonisolated enum ScheduleCacheConflictResolution: Sendable {
    case keepLocal
    case useCloud
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

    private struct PendingCloudConflict {
        let localCache: ScheduleCache
        let remoteCache: ScheduleCache
        let account: CloudAccountContext
        let remoteModifiedAt: Date
        let remoteRecordTag: String
        let signature: String
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
    private var pendingCloudConflicts: [String: PendingCloudConflict] = [:]
    private var promptedConflictSignatures: Set<String> = []

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
            guard await isCurrentCloudState(
                for: account,
                expectedUpdatedAt: currentLocalState.cache.updatedAt
            ) else { return }
            let remoteModifiedAt = remoteRecord.modificationDate ?? remoteCache.cloudSyncBaselineAt
            let remoteRecordTag = remoteRecord.recordChangeTag ?? ""

            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: currentLocalState.cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: currentLocalState.cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                await enqueueCloudConflict(
                    localCache: currentLocalState.cache,
                    remoteCache: remoteCache,
                    account: account,
                    remoteModifiedAt: remoteModifiedAt,
                    remoteRecordTag: remoteRecordTag
                )
                return
            }

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
                    _ = try await upsert(
                        remoteWith: initialUpload,
                        account: account,
                        expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                    )
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

    private func enqueueCloudConflict(
        localCache: ScheduleCache,
        remoteCache: ScheduleCache,
        account: CloudAccountContext,
        remoteModifiedAt: Date,
        remoteRecordTag: String
    ) async {
        let signature = [
            account.accountIdentifier,
            String(localCache.updatedAt.timeIntervalSince1970.bitPattern),
            remoteRecordTag
        ].joined(separator: "-")
        if pendingCloudConflicts[account.accountIdentifier]?.signature != signature {
            pendingCloudConflicts[account.accountIdentifier] = PendingCloudConflict(
                localCache: localCache,
                remoteCache: remoteCache,
                account: account,
                remoteModifiedAt: remoteModifiedAt,
                remoteRecordTag: remoteRecordTag,
                signature: signature
            )
        }
        guard promptedConflictSignatures.insert(signature).inserted else { return }

        await MainActor.run {
            AppPromptCoordinator.shared.enqueue(AppPrompt(
                id: "schedule-cache-conflict-\(signature)-\(UUID().uuidString)",
                title: "课表在两台设备上都有修改",
                message: "本机内容和 iCloud 内容都在上次同步后发生变化。请选择保留本机版本或使用 iCloud 版本；选择后另一份内容会被替换。",
                actions: [
                    AppPromptAction(id: "keep-local", title: "保留本机", isDefault: true) {
                        Task {
                            await self.resolvePendingCloudConflict(
                                accountIdentifier: account.accountIdentifier,
                                signature: signature,
                                resolution: .keepLocal
                            )
                        }
                    },
                    AppPromptAction(id: "use-cloud", title: "使用 iCloud") {
                        Task {
                            await self.resolvePendingCloudConflict(
                                accountIdentifier: account.accountIdentifier,
                                signature: signature,
                                resolution: .useCloud
                            )
                        }
                    },
                    AppPromptAction(id: "later", title: "稍后处理") {
                        Task { await self.conflictPromptWasDismissed(signature) }
                    }
                ]
            ))
        }
    }

    private func conflictPromptWasDismissed(_ signature: String) {
        promptedConflictSignatures.remove(signature)
    }

    private func resolvePendingCloudConflict(
        accountIdentifier: String,
        signature: String,
        resolution: ScheduleCacheConflictResolution
    ) async {
        guard let conflict = pendingCloudConflicts[accountIdentifier],
              conflict.signature == signature
        else {
            promptedConflictSignatures.remove(signature)
            return
        }
        guard let currentLocalState = await currentLocalCloudState(matching: conflict.account) else {
            promptedConflictSignatures.remove(signature)
            return
        }
        guard currentLocalState.cache.updatedAt == conflict.localCache.updatedAt else {
            pendingCloudConflicts[accountIdentifier] = nil
            promptedConflictSignatures.remove(signature)
            await refreshFromCloudIfNeeded()
            return
        }

        do {
            let currentRemoteRecord = try await container.privateCloudDatabase.record(for: conflict.account.recordID)
            guard let currentRemoteCache = decodeCache(
                from: currentRemoteRecord,
                expectedStudentID: conflict.account.studentID
            ) else { return }
            let currentRemoteModifiedAt = currentRemoteRecord.modificationDate
                ?? currentRemoteCache.cloudSyncBaselineAt
            let currentRemoteRecordTag = currentRemoteRecord.recordChangeTag ?? ""
            guard currentRemoteModifiedAt == conflict.remoteModifiedAt,
                  currentRemoteRecordTag == conflict.remoteRecordTag
            else {
                pendingCloudConflicts[accountIdentifier] = nil
                promptedConflictSignatures.remove(signature)
                await reconcile(
                    localCache: currentLocalState.cache,
                    account: conflict.account,
                    allowCloudApply: true
                )
                return
            }
        } catch {
            logError("cloud conflict resolution could not verify the remote version: \(describe(error))")
            promptedConflictSignatures.remove(signature)
            return
        }

        switch resolution {
        case .keepLocal:
            var cache = currentLocalState.cache
            cache.cloudSyncBaselineAt = conflict.remoteModifiedAt
            cache.cloudSyncBaselineRecordTag = conflict.remoteRecordTag
            cache.hasUnpushedCloudChanges = true
            cache.updatedAt = ScheduleCacheTimestamp.next(
                after: max(cache.updatedAt, conflict.remoteModifiedAt),
                now: Date()
            )
            guard await ScheduleCacheStore.saveAndWait(
                cache,
                source: .localWithoutCloudPush,
                expectedAccountIdentifier: accountIdentifier,
                expectedUpdatedAt: currentLocalState.cache.updatedAt
            ) else {
                promptedConflictSignatures.remove(signature)
                return
            }
            pendingCloudConflicts[accountIdentifier] = nil
            promptedConflictSignatures.remove(signature)
            await pushLatestLocalCacheIfNeeded()
        case .useCloud:
            var cache = conflict.remoteCache
            cache.iCloudSyncEnabled = true
            cache.cloudSyncBaselineAt = conflict.remoteModifiedAt
            cache.cloudSyncBaselineRecordTag = conflict.remoteRecordTag
            cache.hasUnpushedCloudChanges = false
            cache.updatedAt = max(cache.updatedAt, conflict.remoteModifiedAt)
            guard await ScheduleCacheStore.saveAndWait(
                cache,
                source: .cloud,
                expectedAccountIdentifier: accountIdentifier,
                expectedUpdatedAt: currentLocalState.cache.updatedAt
            ) else {
                promptedConflictSignatures.remove(signature)
                return
            }
            pendingCloudConflicts[accountIdentifier] = nil
            promptedConflictSignatures.remove(signature)
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
            guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
                return false
            }
            let remoteModifiedAt = record.modificationDate ?? remoteCache.cloudSyncBaselineAt
            let remoteRecordTag = record.recordChangeTag ?? ""
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                await enqueueCloudConflict(
                    localCache: cache,
                    remoteCache: remoteCache,
                    account: account,
                    remoteModifiedAt: remoteModifiedAt,
                    remoteRecordTag: remoteRecordTag
                )
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
            let savedRecord = try await container.privateCloudDatabase.save(record)
            logDebug("upsert saved remote record successfully")
            if let modifiedAt = savedRecord.modificationDate {
                await persistCloudSyncStateIfCurrent(
                    modifiedAt,
                    recordTag: savedRecord.recordChangeTag ?? "",
                    account: account,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
            }
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
            guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
                return false
            }
            let remoteModifiedAt = currentRemoteRecord.modificationDate ?? currentRemoteCache.cloudSyncBaselineAt
            let remoteRecordTag = currentRemoteRecord.recordChangeTag ?? ""
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                await enqueueCloudConflict(
                    localCache: cache,
                    remoteCache: currentRemoteCache,
                    account: account,
                    remoteModifiedAt: remoteModifiedAt,
                    remoteRecordTag: remoteRecordTag
                )
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

        // JSON ISO-8601 can lose sub-second precision; keep the CloudKit date after validation.
        guard let restoredUpdatedAt = ScheduleCacheTimestamp.restored(
            recordDate: storedUpdatedAt,
            payloadDate: cache.updatedAt,
            serverDate: record.modificationDate
        ) else { return nil }
        cache.updatedAt = restoredUpdatedAt
        cache.cloudSyncBaselineAt = record.modificationDate ?? restoredUpdatedAt
        cache.cloudSyncBaselineRecordTag = record.recordChangeTag ?? ""
        cache.hasUnpushedCloudChanges = false
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
        let initialAccount = await MainActor.run {
            (
                studentID: LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines),
                accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName
            )
        }
        guard !initialAccount.studentID.isEmpty else { return nil }

        let loadResult = await ScheduleCacheStore.loadResultAsync()
        guard let cache = loadResult.cacheIfReadable else { return nil }
        return await MainActor.run {
            guard AppFileDirectories.currentSession.accountDirectoryName == initialAccount.accountIdentifier,
                  cache.iCloudSyncEnabled
            else { return nil }
            let account = CloudAccountContext(
                studentID: initialAccount.studentID,
                accountIdentifier: initialAccount.accountIdentifier
            )
            return LocalCloudState(cache: cache, account: account)
        }
    }

    private func currentLocalCloudState(matching account: CloudAccountContext) async -> LocalCloudState? {
        let loadResult = await ScheduleCacheStore.loadResultAsync()
        guard let cache = loadResult.cacheIfReadable else { return nil }
        return await MainActor.run { () -> LocalCloudState? in
            let studentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: studentID,
                accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName
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
        let loadResult = await ScheduleCacheStore.loadResultAsync()
        guard let currentCache = loadResult.cacheIfReadable else { return false }
        let isCurrent = await MainActor.run { () -> Bool in
            let currentStudentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: currentStudentID,
                accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName
            )
            guard currentAccount == account else { return false }

            guard currentCache.iCloudSyncEnabled,
                  currentCache.updatedAt == expectedLocalUpdatedAt
            else { return false }
            return true
        }
        guard isCurrent else { return false }
        return await ScheduleCacheStore.saveAndWait(
            cache,
            source: .cloud,
            expectedAccountIdentifier: account.accountIdentifier,
            expectedUpdatedAt: expectedLocalUpdatedAt
        )
    }

    private func persistCloudSyncStateIfCurrent(
        _ serverModifiedAt: Date,
        recordTag: String,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date
    ) async {
        guard !recordTag.isEmpty else { return }
        let loadResult = await ScheduleCacheStore.loadResultAsync()
        guard let currentCache = loadResult.cacheIfReadable else { return }
        let cacheToSave = await MainActor.run { () -> ScheduleCache? in
            let currentStudentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: currentStudentID,
                accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName
            )
            guard currentAccount == account else { return nil }

            guard currentCache.iCloudSyncEnabled,
                  currentCache.updatedAt == expectedLocalUpdatedAt
            else { return nil }

            var cacheToSave = currentCache
            cacheToSave.updatedAt = ScheduleCacheTimestamp.afterCloudSave(
                serverModifiedAt,
                currentDate: currentCache.updatedAt
            )
            cacheToSave.cloudSyncBaselineAt = serverModifiedAt
            cacheToSave.cloudSyncBaselineRecordTag = recordTag
            cacheToSave.hasUnpushedCloudChanges = false
            return cacheToSave
        }
        guard let cacheToSave else { return }
        _ = await ScheduleCacheStore.saveAndWait(
            cacheToSave,
            source: .cloud,
            expectedAccountIdentifier: account.accountIdentifier,
            expectedUpdatedAt: expectedLocalUpdatedAt
        )
    }

    private func encodeCache(_ cache: ScheduleCache) throws -> String {
        var cloudCache = cache
        cloudCache.cloudSyncBaselineAt = .distantPast
        cloudCache.cloudSyncBaselineRecordTag = ""
        cloudCache.hasUnpushedCloudChanges = false
        let data = try encoder.encode(cloudCache)
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
