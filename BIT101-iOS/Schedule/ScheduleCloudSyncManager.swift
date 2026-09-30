import SchedulePersistence
import StorageCore
import ScheduleDomain
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
        let account: CloudAccountContext
    }

    private struct PendingCloudConflict {
        let localCache: ScheduleCache
        let remoteCache: ScheduleCache
        let requiresPayloadMigration: Bool
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
    private var isReconciling = false
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
        pendingLocalCache = PendingLocalCache(account: localState.account)
        guard !isPushingLocalCache, !isReconciling else { return }

        isPushingLocalCache = true
        defer { isPushingLocalCache = false }
        while let pendingLocalCache {
            self.pendingLocalCache = nil
            guard await isCurrentCloudState(for: pendingLocalCache.account),
                  await hasAvailableCloudAccount()
            else { continue }
            guard let latestState = await currentLocalCloudState(matching: pendingLocalCache.account) else {
                continue
            }
            do {
                _ = try await upsert(
                    remoteWith: latestState.cache,
                    account: pendingLocalCache.account,
                    expectedLocalUpdatedAt: latestState.cache.updatedAt
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
        guard !isReconciling, !isPushingLocalCache else { return }
        isReconciling = true
        defer {
            isReconciling = false
            if pendingLocalCache != nil {
                Task { await self.pushLatestLocalCacheIfNeeded() }
            }
        }
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
            guard let decodedRemote = decodeCache(
                from: remoteRecord,
                expectedStudentID: account.studentID
            ) else {
                logError("reconcile abort: remote payload decode failed record=\(account.recordID.recordName)")
                return
            }
            let remoteCache = decodedRemote.cache
            guard let currentLocalState = await currentLocalCloudState(matching: account) else { return }
            guard await isCurrentCloudState(
                for: account,
                expectedUpdatedAt: currentLocalState.cache.updatedAt
            ) else { return }
            let remoteModifiedAt = remoteRecord.modificationDate ?? remoteCache.cloudSyncBaselineAt
            let remoteRecordTag = remoteRecord.recordChangeTag ?? ""

            if !decodedRemote.requiresPayloadMigration,
               try ScheduleCloudSyncState.matches(currentLocalState.cache, remoteCache) {
                await persistCloudSyncStateIfCurrent(
                    remoteModifiedAt,
                    recordTag: remoteRecordTag,
                    account: account,
                    expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                )
                return
            }

            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: currentLocalState.cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: currentLocalState.cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag,
                localUpdatedAt: currentLocalState.cache.updatedAt,
                remoteUpdatedAt: remoteCache.updatedAt
            ) {
                await enqueueCloudConflict(
                    localCache: currentLocalState.cache,
                    remoteCache: remoteCache,
                    requiresPayloadMigration: decodedRemote.requiresPayloadMigration,
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
                logDebug("applying remote cache to local")
                let didApply = await applyRemoteCacheIfCurrent(
                    remoteCache,
                    account: account,
                    expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                )
                if didApply, decodedRemote.requiresPayloadMigration {
                    await pushLatestLocalCacheIfNeeded()
                }
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
                if decodedRemote.requiresPayloadMigration {
                    do {
                        _ = try await upsert(
                            remoteWith: currentLocalState.cache,
                            account: account,
                            expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                        )
                    } catch {
                        logError("legacy payload migration failed: \(describe(error))")
                    }
                }
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
        requiresPayloadMigration: Bool,
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
                requiresPayloadMigration: requiresPayloadMigration,
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
                title: "本机和 iCloud 课表存在版本差异",
                message: "本机与 iCloud 中的手动调整、个人日程、DDL 或设置存在版本差异。请选择保留本机版本或使用 iCloud 版本；选择会替换另一侧这部分用户数据，学校抓取数据保留本机版本。",
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
            guard let currentRemote = decodeCache(
                from: currentRemoteRecord,
                expectedStudentID: conflict.account.studentID
            ) else { return }
            let currentRemoteCache = currentRemote.cache
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
            var cache = currentLocalState.cache.applyingCloudSyncState(from: conflict.remoteCache)
            cache.cloudSyncBaselineAt = conflict.remoteModifiedAt
            cache.cloudSyncBaselineRecordTag = conflict.remoteRecordTag
            cache.hasUnpushedCloudChanges = false
            cache.updatedAt = max(currentLocalState.cache.updatedAt, conflict.remoteCache.updatedAt)
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
            if conflict.requiresPayloadMigration {
                await pushLatestLocalCacheIfNeeded()
            }
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

        var record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: account.recordID)
            logDebug("upsert fetched existing remote record")
            guard let decodedRemote = decodeCache(from: record, expectedStudentID: account.studentID) else {
                logError("upsert abort: remote payload decode failed record=\(account.recordID.recordName)")
                return false
            }
            let remoteCache = decodedRemote.cache
            guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
                return false
            }
            let remoteModifiedAt = record.modificationDate ?? remoteCache.cloudSyncBaselineAt
            let remoteRecordTag = record.recordChangeTag ?? ""
            if !decodedRemote.requiresPayloadMigration,
               try ScheduleCloudSyncState.matches(cache, remoteCache) {
                await persistCloudSyncStateIfCurrent(
                    remoteModifiedAt,
                    recordTag: remoteRecordTag,
                    account: account,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
                return true
            }
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag,
                localUpdatedAt: cache.updatedAt,
                remoteUpdatedAt: remoteCache.updatedAt
            ) {
                await enqueueCloudConflict(
                    localCache: cache,
                    remoteCache: remoteCache,
                    requiresPayloadMigration: decodedRemote.requiresPayloadMigration,
                    account: account,
                    remoteModifiedAt: remoteModifiedAt,
                    remoteRecordTag: remoteRecordTag
                )
                return false
            }
            guard cache.updatedAt > remoteCache.updatedAt || decodedRemote.requiresPayloadMigration else {
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
            guard let currentRemote = decodeCache(
                from: currentRemoteRecord,
                expectedStudentID: account.studentID
            ) else {
                logError("upsert conflict resolution aborted: remote payload decode failed")
                return false
            }
            let currentRemoteCache = currentRemote.cache
            guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
                return false
            }
            let remoteModifiedAt = currentRemoteRecord.modificationDate ?? currentRemoteCache.cloudSyncBaselineAt
            let remoteRecordTag = currentRemoteRecord.recordChangeTag ?? ""
            if !currentRemote.requiresPayloadMigration,
               try ScheduleCloudSyncState.matches(cache, currentRemoteCache) {
                await persistCloudSyncStateIfCurrent(
                    remoteModifiedAt,
                    recordTag: remoteRecordTag,
                    account: account,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
                return true
            }
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag,
                localUpdatedAt: cache.updatedAt,
                remoteUpdatedAt: currentRemoteCache.updatedAt
            ) {
                await enqueueCloudConflict(
                    localCache: cache,
                    remoteCache: currentRemoteCache,
                    requiresPayloadMigration: currentRemote.requiresPayloadMigration,
                    account: account,
                    remoteModifiedAt: remoteModifiedAt,
                    remoteRecordTag: remoteRecordTag
                )
                return false
            }
            guard cache.updatedAt > currentRemoteCache.updatedAt || currentRemote.requiresPayloadMigration else {
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

    private func decodeCache(
        from record: CKRecord,
        expectedStudentID: String
    ) -> DecodedScheduleCloudCache? {
        guard record.recordType == recordType,
              let storedStudentID = record[FieldKey.studentID] as? String,
              storedStudentID == expectedStudentID,
              let storedUpdatedAt = record[FieldKey.updatedAt] as? Date,
              let payloadJSON = record[FieldKey.payloadJSON] as? String
        else { return nil }

        let payloadData = Data(payloadJSON.utf8)
        let cache: ScheduleCache
        let requiresPayloadMigration: Bool
        if let envelope = try? decoder.decode(ScheduleCloudSyncEnvelope.self, from: payloadData),
           envelope.schemaVersion == ScheduleCloudSyncEnvelope.currentSchemaVersion {
            var projectedCache = ScheduleCache()
            envelope.payload.state.apply(to: &projectedCache)
            projectedCache.updatedAt = envelope.payload.updatedAt
            cache = projectedCache
            requiresPayloadMigration = false
        } else if let legacyCache = try? decoder.decode(ScheduleCache.self, from: payloadData) {
            var projectedCache = ScheduleCache()
            ScheduleCloudSyncState(cache: legacyCache).apply(to: &projectedCache)
            projectedCache.updatedAt = legacyCache.updatedAt
            cache = projectedCache
            requiresPayloadMigration = true
        } else {
            return nil
        }

        var restoredCache = cache

        // JSON ISO-8601 can lose sub-second precision; keep the CloudKit date after validation.
        guard let restoredUpdatedAt = ScheduleCacheTimestamp.restored(
            recordDate: storedUpdatedAt,
            payloadDate: restoredCache.updatedAt,
            serverDate: record.modificationDate
        ) else { return nil }
        restoredCache.updatedAt = restoredUpdatedAt
        restoredCache.cloudSyncBaselineAt = record.modificationDate ?? restoredUpdatedAt
        restoredCache.cloudSyncBaselineRecordTag = record.recordChangeTag ?? ""
        restoredCache.hasUnpushedCloudChanges = false
        return DecodedScheduleCloudCache(
            cache: restoredCache,
            requiresPayloadMigration: requiresPayloadMigration
        )
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
        var mergedCache = currentCache.applyingCloudSyncState(from: cache)
        mergedCache.cloudSyncBaselineAt = cache.cloudSyncBaselineAt
        mergedCache.cloudSyncBaselineRecordTag = cache.cloudSyncBaselineRecordTag
        mergedCache.hasUnpushedCloudChanges = false
        mergedCache.updatedAt = max(currentCache.updatedAt, cache.updatedAt)
        return await ScheduleCacheStore.saveAndWait(
            mergedCache,
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
        let baselineUpdate = await MainActor.run {
            () -> (cache: ScheduleCache, expectedUpdatedAt: Date, source: ScheduleCacheSaveSource)? in
            let currentStudentID = LoginStorage.shared.currentStudentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentAccount = CloudAccountContext(
                studentID: currentStudentID,
                accountIdentifier: AppFileDirectories.currentSession.accountDirectoryName
            )
            guard currentAccount == account else { return nil }

            guard currentCache.iCloudSyncEnabled else { return nil }

            var cacheToSave = currentCache
            cacheToSave.cloudSyncBaselineAt = serverModifiedAt
            cacheToSave.cloudSyncBaselineRecordTag = recordTag
            if currentCache.updatedAt == expectedLocalUpdatedAt {
                cacheToSave.updatedAt = ScheduleCacheTimestamp.afterCloudSave(
                    serverModifiedAt,
                    currentDate: currentCache.updatedAt
                )
                cacheToSave.hasUnpushedCloudChanges = false
                return (cacheToSave, expectedLocalUpdatedAt, .cloud)
            }

            guard currentCache.hasUnpushedCloudChanges else { return nil }
            return (cacheToSave, currentCache.updatedAt, .cloudBaseline)
        }
        guard let baselineUpdate else { return }
        _ = await ScheduleCacheStore.saveAndWait(
            baselineUpdate.cache,
            source: baselineUpdate.source,
            expectedAccountIdentifier: account.accountIdentifier,
            expectedUpdatedAt: baselineUpdate.expectedUpdatedAt
        )
    }

    private func encodeCache(_ cache: ScheduleCache) throws -> String {
        let envelope = ScheduleCloudSyncEnvelope(
            schemaVersion: ScheduleCloudSyncEnvelope.currentSchemaVersion,
            payload: ScheduleCloudSyncEnvelope.Payload(
                updatedAt: cache.updatedAt,
                state: ScheduleCloudSyncState(cache: cache)
            )
        )
        let data = try encoder.encode(envelope)
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
