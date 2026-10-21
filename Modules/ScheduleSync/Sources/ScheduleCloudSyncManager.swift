import Foundation
import ScheduleDomain
import StorageCore
#if canImport(os)
import os
#endif

public actor ScheduleCloudSyncManager {
    private typealias CloudAccountContext = ScheduleCloudAccount
    private let local: ScheduleCloudLocalStore
    private let transport: any ScheduleCloudTransport
    private let presentConflict: ScheduleCloudConflictPresenter
    private let reportStatus: @MainActor @Sendable (ScheduleCloudAccount, ScheduleCloudSyncStatus) -> Void
    private var reportedStatus: (ScheduleCloudAccount, ScheduleCloudSyncStatus)?

    public init(local: ScheduleCloudLocalStore, transport: any ScheduleCloudTransport,
                presentConflict: @escaping ScheduleCloudConflictPresenter,
                reportStatus: @escaping @MainActor @Sendable (ScheduleCloudAccount, ScheduleCloudSyncStatus) -> Void = { _, _ in }) {
        self.local = local
        self.transport = transport
        self.presentConflict = presentConflict
        self.reportStatus = reportStatus
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
    private enum Phase { case idle, pushing, reconciling }
    private var phase = Phase.idle
    private var isPushingLocalCache: Bool { phase == .pushing }
    private var isReconciling: Bool { phase == .reconciling }
    private var needsReconciliation = false
    private var pendingCloudConflicts: [String: PendingCloudConflict] = [:]
    private var promptedConflictSignatures: Set<String> = []

    public func refreshFromCloudIfNeeded() async {
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

    public func reconcileAfterEnabling() async {
        logDebug("reconcile after enabling")
        guard let localState = await currentLocalCloudState() else { return }
        await reconcile(
            localCache: localState.cache,
            account: localState.account,
            allowCloudApply: true
        )
    }

    public func pushLatestLocalCacheIfNeeded() async {
        guard let localState = await currentLocalCloudState() else {
            logDebug("skip push: iCloud sync disabled")
            return
        }
        pendingLocalCache = PendingLocalCache(account: localState.account)
        guard !isPushingLocalCache, !isReconciling else { return }

        phase = .pushing
        defer {
            phase = .idle
            scheduleQueuedReconciliation()
        }
        while let pendingLocalCache {
            self.pendingLocalCache = nil
            guard await isCurrentCloudState(for: pendingLocalCache.account),
                  await hasAvailableCloudAccount(for: pendingLocalCache.account)
            else { continue }
            guard let latestState = await currentLocalCloudState(matching: pendingLocalCache.account) else {
                continue
            }
            await publishStatus(.syncing, for: pendingLocalCache.account)
            do {
                try await uploadAndReport(
                    remoteWith: latestState.cache,
                    account: pendingLocalCache.account,
                    expectedLocalUpdatedAt: latestState.cache.updatedAt
                )
                await finishStatus(for: pendingLocalCache.account)
            } catch {
                await publishStatus(.failed(error.localizedDescription), for: pendingLocalCache.account)
                logError("push latest local cache failed: \(describe(error))")
            }
        }
    }

    private func scheduleQueuedReconciliation() {
        guard needsReconciliation, !isReconciling, !isPushingLocalCache else { return }
        needsReconciliation = false
        Task { await self.refreshFromCloudIfNeeded() }
    }

    private func reconcile(
        localCache: ScheduleCache,
        account: CloudAccountContext,
        allowCloudApply: Bool
    ) async {
        guard !isReconciling, !isPushingLocalCache else {
            needsReconciliation = true
            return
        }
        phase = .reconciling
        defer {
            phase = .idle
            scheduleQueuedReconciliation()
            if pendingLocalCache != nil {
                Task { await self.pushLatestLocalCacheIfNeeded() }
            }
        }
        guard localCache.iCloudSyncEnabled,
              await isCurrentCloudState(for: account),
              await hasAvailableCloudAccount(for: account)
        else { return }

        await publishStatus(.syncing, for: account)
        await performReconciliation(localCache: localCache, account: account, allowCloudApply: allowCloudApply)
        await finishStatus(for: account)
    }

    private func performReconciliation(localCache: ScheduleCache, account: CloudAccountContext, allowCloudApply: Bool) async {
        logDebug(
            "reconcile start record=\(account.recordName) localUpdatedAt=\(debugDate(localCache.updatedAt)) allowCloudApply=\(allowCloudApply)"
        )

        do {
            let remoteRecord = try await transport.record(named: account.recordName)
            guard await isCurrentCloudState(for: account) else { return }
            guard let decodedRemote = decodeCache(
                from: remoteRecord,
                account: account
            ) else {
                await publishStatus(.failed("云端日程数据需要更新后重试。"), for: account)
                logError("reconcile abort: remote payload decode failed record=\(account.recordName)")
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
                    baseline: remoteCache,
                    expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                )
                return
            }

            if !currentLocalState.cache.applyingCloudSyncState(from: remoteCache).hasSupportedCourseSections {
                await enqueueCloudConflict(localCache: currentLocalState.cache, remoteCache: remoteCache,
                    requiresPayloadMigration: decodedRemote.requiresPayloadMigration, account: account,
                    remoteModifiedAt: remoteModifiedAt, remoteRecordTag: remoteRecordTag)
                return
            }

            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: currentLocalState.cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: currentLocalState.cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                if try await mergeConcurrentChanges(localCache: currentLocalState.cache, remoteCache: remoteCache,
                    record: remoteRecord, account: account) { return }
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
                localHasUnpushedChanges: currentLocalState.cache.hasUnpushedCloudChanges,
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
                if !didApply, reportedStatus?.1 == .syncing { await publishStatus(.pending, for: account) }
                if didApply, decodedRemote.requiresPayloadMigration {
                    await pushLatestLocalCacheIfNeeded()
                }
                return
            case .uploadLocal:
                logDebug("local cache newer than remote; uploading local copy")
                do {
                    try await uploadAndReport(
                        remoteWith: currentLocalState.cache,
                        account: account,
                        expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                    )
                } catch {
                    await publishStatus(.failed(error.localizedDescription), for: account)
                    logError("reconcile local upload failed: \(describe(error))")
                }
            case .noChange:
                logDebug("reconcile: timestamps match")
                if decodedRemote.requiresPayloadMigration {
                    do {
                        try await uploadAndReport(
                            remoteWith: currentLocalState.cache,
                            account: account,
                            expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                        )
                    } catch {
                        await publishStatus(.failed(error.localizedDescription), for: account)
                        logError("legacy payload migration failed: \(describe(error))")
                    }
                }
            }
        } catch let error as ScheduleCloudTransportError {
            if error == .unknownItem {
                logDebug("remote record unavailable (\(error)); uploading initial local cache")
                guard let currentLocalState = await currentLocalCloudState(matching: account) else { return }
                var initialUpload = currentLocalState.cache
                if initialUpload.updatedAt == .distantPast {
                    initialUpload.updatedAt = Date()
                }
                do {
                    try await uploadAndReport(
                        remoteWith: initialUpload,
                        account: account,
                        expectedLocalUpdatedAt: currentLocalState.cache.updatedAt
                    )
                } catch {
                    await publishStatus(.failed(error.localizedDescription), for: account)
                    logError("initial upload after unknownItem failed: \(describe(error))")
                }
            } else {
                await publishStatus(.failed(error.localizedDescription), for: account)
                logError("reconcile cloud error: \(describe(error))")
            }
        } catch {
            await publishStatus(.failed(error.localizedDescription), for: account)
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
        guard await isCurrentCloudState(for: account) else { return }
        await publishStatus(.conflict, for: account)
        guard !Task.isCancelled else { return }
        let signature = [
            account.accountIdentifier,
            String(account.generation),
            String(account.cloudGeneration),
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

        await presentConflict(account, signature) { resolution in
            if let resolution {
                await self.resolvePendingCloudConflict(
                    accountIdentifier: account.accountIdentifier,
                    signature: signature,
                    resolution: resolution
                )
            } else {
                await self.conflictPromptWasDismissed(accountIdentifier: account.accountIdentifier, signature: signature)
            }
        }
    }

    private func conflictPromptWasDismissed(accountIdentifier: String, signature: String) {
        if pendingCloudConflicts[accountIdentifier]?.signature == signature {
            pendingCloudConflicts[accountIdentifier] = nil
        }
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
            conflictPromptWasDismissed(accountIdentifier: accountIdentifier, signature: signature)
            return
        }
        guard currentLocalState.cache.updatedAt == conflict.localCache.updatedAt else {
            pendingCloudConflicts[accountIdentifier] = nil
            promptedConflictSignatures.remove(signature)
            await refreshFromCloudIfNeeded()
            return
        }

        do {
            let currentRemoteRecord = try await transport.record(named: conflict.account.recordName)
            guard let currentRemote = decodeCache(
                from: currentRemoteRecord,
                account: conflict.account
            ) else { throw CocoaError(.coderReadCorrupt) }
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
            await publishStatus(.failed(error.localizedDescription), for: conflict.account)
            logError("cloud conflict resolution could not verify the remote version: \(describe(error))")
            promptedConflictSignatures.remove(signature)
            return
        }

        do {
            var cache = currentLocalState.cache
            if let baseline = cache.syncData.cloudSyncBaselineUserState {
                guard let merged = try ScheduleCloudStateMerge.merge(local: ScheduleCloudSyncState(cache: cache),
                    remote: ScheduleCloudSyncState(cache: conflict.remoteCache), baseline: baseline, resolution: resolution)
                else { throw CocoaError(.coderReadCorrupt) }
                merged.apply(to: &cache)
            } else if resolution == .useCloud {
                cache = cache.applyingCloudSyncState(from: conflict.remoteCache)
            }
            guard cache.hasSupportedCourseSections else {
                promptedConflictSignatures.remove(signature)
                await publishStatus(.failed("iCloud 节次时间表与本机课程存在差异，请重新同步学校课表后重试，或选择保留本机版本。"), for: conflict.account)
                return
            }
            let containsLocalChanges = try !ScheduleCloudSyncState.matches(cache, conflict.remoteCache)
            let needsUpload = resolution == .keepLocal || conflict.requiresPayloadMigration || containsLocalChanges
            cache.cloudSyncBaselineAt = conflict.remoteModifiedAt
            cache.cloudSyncBaselineRecordTag = conflict.remoteRecordTag
            cache.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: conflict.remoteCache)
            cache.hasUnpushedCloudChanges = needsUpload
            cache.updatedAt = needsUpload
                ? ScheduleCacheTimestamp.next(after: max(cache.updatedAt, conflict.remoteModifiedAt), now: Date())
                : max(cache.updatedAt, conflict.remoteCache.updatedAt)
            try Task.checkCancellation()
            guard await local.save(cache, needsUpload ? .cloudBaseline : .cloud, conflict.account, currentLocalState.cache.updatedAt) else {
                promptedConflictSignatures.remove(signature)
                await publishStatus(.failed("日程同步状态保存失败，请重试同步。"), for: conflict.account)
                return
            }
            pendingCloudConflicts[accountIdentifier] = nil
            promptedConflictSignatures.remove(signature)
            if needsUpload {
                await pushLatestLocalCacheIfNeeded()
            } else {
                await publishStatus(.synchronized, for: conflict.account)
            }
        } catch {
            promptedConflictSignatures.remove(signature)
            await publishStatus(.failed(error.localizedDescription), for: conflict.account)
            logError("cloud conflict resolution failed: \(describe(error))")
        }
    }

    private func uploadAndReport(remoteWith cache: ScheduleCache, account: CloudAccountContext, expectedLocalUpdatedAt: Date?) async throws {
        let saved = try await upsert(remoteWith: cache, account: account, expectedLocalUpdatedAt: expectedLocalUpdatedAt)
        if !saved, reportedStatus?.0 == account, reportedStatus?.1 == .syncing {
            await publishStatus(.pending, for: account)
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

        logDebug("upsert start record=\(account.recordName) updatedAt=\(debugDate(cache.updatedAt))")

        var record: ScheduleCloudRecord
        do {
            record = try await transport.record(named: account.recordName)
            logDebug("upsert fetched existing remote record")
            guard let decodedRemote = decodeCache(from: record, account: account) else {
                await publishStatus(.failed("云端日程数据需要更新后重试。"), for: account)
                logError("upsert abort: remote payload decode failed record=\(account.recordName)")
                return false
            }
            let remoteCache = decodedRemote.cache
            guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
                return false
            }
            let remoteModifiedAt = record.modificationDate ?? remoteCache.cloudSyncBaselineAt
            let remoteRecordTag = record.recordChangeTag ?? ""
            let statesMatch = try ScheduleCloudSyncState.matches(cache, remoteCache)
            if !decodedRemote.requiresPayloadMigration, statesMatch {
                return await persistCloudSyncStateIfCurrent(
                    remoteModifiedAt,
                    recordTag: remoteRecordTag,
                    account: account,
                    baseline: remoteCache,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
            }
            guard cache.hasUnpushedCloudChanges || statesMatch else { return false }
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                if try await mergeConcurrentChanges(localCache: cache, remoteCache: remoteCache,
                    record: record, account: account) { return true }
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
        } catch let error as ScheduleCloudTransportError where error == .unknownItem {
            record = ScheduleCloudRecord(recordName: account.recordName, recordType: recordType)
            logDebug("upsert will create new remote record after fetch error code=\(error)")
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
        _ record: ScheduleCloudRecord,
        cache: ScheduleCache,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date?,
        retryOnConflict: Bool
    ) async throws -> Bool {
        guard await isCurrentCloudState(for: account, expectedUpdatedAt: expectedLocalUpdatedAt) else {
            return false
        }

        let payloadJSON = try encodeCache(cache)
        var record = record
        record.studentID = account.studentID
        record.updatedAt = cache.updatedAt
        record.payloadJSON = payloadJSON
        try record.validatePayloadSize()

        do {
            let savedRecord = try await transport.save(record)
            logDebug("upsert saved remote record successfully")
            if let modifiedAt = savedRecord.modificationDate {
                return await persistCloudSyncStateIfCurrent(
                    modifiedAt,
                    recordTag: savedRecord.recordChangeTag ?? "",
                    account: account,
                    baseline: cache,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
            }
            return true
        } catch let error as ScheduleCloudTransportError where retryOnConflict && error == .serverRecordChanged {
            logDebug("upsert conflict detected; refetching remote record")
            let currentRemoteRecord = try await transport.record(named: account.recordName)
            guard let currentRemote = decodeCache(
                from: currentRemoteRecord,
                account: account
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
            let statesMatch = try ScheduleCloudSyncState.matches(cache, currentRemoteCache)
            if !currentRemote.requiresPayloadMigration, statesMatch {
                await persistCloudSyncStateIfCurrent(
                    remoteModifiedAt,
                    recordTag: remoteRecordTag,
                    account: account,
                    baseline: currentRemoteCache,
                    expectedLocalUpdatedAt: expectedLocalUpdatedAt ?? cache.updatedAt
                )
                return true
            }
            guard cache.hasUnpushedCloudChanges || statesMatch else { return false }
            if ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
                localHasUnpushedChanges: cache.hasUnpushedCloudChanges,
                localBaselineRecordTag: cache.cloudSyncBaselineRecordTag,
                remoteRecordTag: remoteRecordTag
            ) {
                if try await mergeConcurrentChanges(localCache: cache, remoteCache: currentRemoteCache,
                    record: currentRemoteRecord, account: account) { return true }
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
        from record: ScheduleCloudRecord,
        account: CloudAccountContext
    ) -> DecodedScheduleCloudCache? {
        guard record.recordName == account.recordName, record.recordType == recordType,
              let storedStudentID = record.studentID,
              storedStudentID == account.studentID,
              let storedUpdatedAt = record.updatedAt,
              let payloadJSON = record.payloadJSON
        else { return nil }

        let payloadData = Data(payloadJSON.utf8)
        guard payloadData.count <= ScheduleCloudRecord.maximumPayloadBytes else { return nil }
        let cache: ScheduleCache
        let requiresPayloadMigration: Bool
        if let envelope = try? decoder.decode(ScheduleCloudSyncEnvelope.self, from: payloadData) {
            guard (2...ScheduleCloudSyncEnvelope.currentSchemaVersion).contains(envelope.schemaVersion),
                  envelope.payload.state.hasValidManualDDLEvents else { return nil }
            var projectedCache = ScheduleCache()
            envelope.payload.state.apply(to: &projectedCache)
            projectedCache.updatedAt = envelope.payload.updatedAt
            cache = projectedCache
            requiresPayloadMigration = envelope.schemaVersion < ScheduleCloudSyncEnvelope.currentSchemaVersion
        } else if let legacyCache = try? decoder.decode(ScheduleCache.self, from: payloadData) {
            var projectedCache = ScheduleCache()
            ScheduleCloudSyncState(cache: legacyCache).apply(to: &projectedCache)
            projectedCache.updatedAt = legacyCache.updatedAt
            cache = projectedCache
            requiresPayloadMigration = true
        } else {
            return nil
        }

        guard cache.isValidForPersistence else { return nil }
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

    private func mergeConcurrentChanges(localCache: ScheduleCache, remoteCache: ScheduleCache,
                                        record: ScheduleCloudRecord, account: CloudAccountContext) async throws -> Bool {
        guard let baseline = localCache.syncData.cloudSyncBaselineUserState,
              let merged = try ScheduleCloudStateMerge.merge(local: ScheduleCloudSyncState(cache: localCache),
                  remote: ScheduleCloudSyncState(cache: remoteCache), baseline: baseline) else { return false }
        var cache = localCache
        merged.apply(to: &cache)
        guard cache.hasSupportedCourseSections else { return false }
        cache.cloudSyncBaselineAt = remoteCache.cloudSyncBaselineAt
        cache.cloudSyncBaselineRecordTag = remoteCache.cloudSyncBaselineRecordTag
        cache.syncData.cloudSyncBaselineUserState = try ScheduleCloudStateMerge.baseline(for: remoteCache)
        cache.hasUnpushedCloudChanges = true
        cache.updatedAt = ScheduleCacheTimestamp.next(after: max(localCache.updatedAt, remoteCache.updatedAt), now: Date())
        guard !Task.isCancelled, await local.save(cache, .cloudBaseline, account, localCache.updatedAt),
              let current = await currentLocalCloudState(matching: account) else { return false }
        return try await save(record, cache: current.cache, account: account,
            expectedLocalUpdatedAt: current.cache.updatedAt, retryOnConflict: false)
    }

    private func hasAvailableCloudAccount(for account: CloudAccountContext) async -> Bool {
        do {
            try Task.checkCancellation()
            let available = try await transport.accountAvailable()
            try Task.checkCancellation()
            if !available { await publishStatus(.unavailable, for: account) }
            return available
        } catch {
            await publishStatus(.failed(error.localizedDescription), for: account)
            logError("cloud account status query failed: \(describe(error))")
            return false
        }
    }

    private func publishStatus(_ status: ScheduleCloudSyncStatus, for account: CloudAccountContext) async {
        guard await local.currentAccount() == account, !Task.isCancelled else { return }
        reportedStatus = (account, status)
        await reportStatus(account, status)
    }

    private func finishStatus(for account: CloudAccountContext) async {
        guard reportedStatus?.0 == account, reportedStatus?.1 == .syncing else { return }
        guard let state = await currentLocalCloudState(matching: account) else {
            await publishStatus(.failed("本机日程需要恢复后继续同步。"), for: account)
            return
        }
        await publishStatus(state.cache.hasUnpushedCloudChanges ? .pending : .synchronized, for: account)
    }

    private func currentLocalCloudState() async -> LocalCloudState? {
        guard !Task.isCancelled else { return nil }
        guard let account = await local.currentAccount(), !account.studentID.isEmpty else {
            pendingCloudConflicts.removeAll()
            promptedConflictSignatures.removeAll()
            return nil
        }
        return await currentLocalCloudState(matching: account)
    }

    private func currentLocalCloudState(matching account: CloudAccountContext) async -> LocalCloudState? {
        guard !Task.isCancelled else { return nil }
        let current = await local.currentAccount()
        for (identifier, conflict) in pendingCloudConflicts where conflict.account != current {
            pendingCloudConflicts[identifier] = nil
            promptedConflictSignatures.remove(conflict.signature)
        }
        guard current == account, !Task.isCancelled else { return nil }
        let result = await local.load(account.session)
        if case .recovered = result { return nil }
        guard let cache = result.cacheIfReadable, cache.iCloudSyncEnabled,
              await local.currentAccount() == account, !Task.isCancelled else { return nil }
        return LocalCloudState(cache: cache, account: account)
    }

    private func isCurrentCloudState(
        for account: CloudAccountContext,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        guard let state = await currentLocalCloudState(matching: account) else { return false }
        guard let expectedUpdatedAt else { return true }
        return state.cache.updatedAt == expectedUpdatedAt
    }

    private func applyRemoteCacheIfCurrent(
        _ cache: ScheduleCache,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date
    ) async -> Bool {
        guard let state = await currentLocalCloudState(matching: account),
              state.cache.updatedAt == expectedLocalUpdatedAt else { return false }
        var mergedCache = state.cache.applyingCloudSyncState(from: cache)
        guard mergedCache.hasSupportedCourseSections else {
            await publishStatus(.failed("iCloud 节次时间表与本机课程存在差异，请重新同步学校课表后重试，或选择保留本机版本。"), for: account)
            return false
        }
        mergedCache.cloudSyncBaselineAt = cache.cloudSyncBaselineAt
        mergedCache.cloudSyncBaselineRecordTag = cache.cloudSyncBaselineRecordTag
        mergedCache.syncData.cloudSyncBaselineUserState = try? ScheduleCloudStateMerge.baseline(for: cache)
        mergedCache.hasUnpushedCloudChanges = false
        mergedCache.updatedAt = max(state.cache.updatedAt, cache.updatedAt)
        return await local.save(mergedCache, .cloud, account, expectedLocalUpdatedAt)
    }

    @discardableResult
    private func persistCloudSyncStateIfCurrent(
        _ serverModifiedAt: Date,
        recordTag: String,
        account: CloudAccountContext,
        baseline: ScheduleCache,
        expectedLocalUpdatedAt: Date
    ) async -> Bool {
        guard !recordTag.isEmpty else {
            await publishStatus(.failed("iCloud 同步版本信息需要重新获取，请重试同步。"), for: account)
            return false
        }
        guard let state = await currentLocalCloudState(matching: account) else { return false }
        var cache = state.cache
        cache.cloudSyncBaselineAt = serverModifiedAt
        cache.cloudSyncBaselineRecordTag = recordTag
        cache.syncData.cloudSyncBaselineUserState = try? ScheduleCloudStateMerge.baseline(for: baseline)
        let source: ScheduleCacheSaveSource
        if state.cache.updatedAt == expectedLocalUpdatedAt {
            cache.updatedAt = ScheduleCacheTimestamp.afterCloudSave(serverModifiedAt, currentDate: state.cache.updatedAt)
            cache.hasUnpushedCloudChanges = false
            source = .cloud
        } else {
            guard state.cache.hasUnpushedCloudChanges else { return false }
            source = .cloudBaseline
        }
        guard await local.save(cache, source, account, state.cache.updatedAt) else {
            await publishStatus(.failed("日程同步状态保存失败，请重试同步。"), for: account)
            return false
        }
        return true
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
