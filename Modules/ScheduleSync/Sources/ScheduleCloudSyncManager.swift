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

    public init(local: ScheduleCloudLocalStore, transport: any ScheduleCloudTransport,
                presentConflict: @escaping ScheduleCloudConflictPresenter) {
        self.local = local
        self.transport = transport
        self.presentConflict = presentConflict
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
    private var isPushingLocalCache = false
    private var isReconciling = false
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

        isPushingLocalCache = true
        defer {
            isPushingLocalCache = false
            scheduleQueuedReconciliation()
        }
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
        isReconciling = true
        defer {
            isReconciling = false
            scheduleQueuedReconciliation()
            if pendingLocalCache != nil {
                Task { await self.pushLatestLocalCacheIfNeeded() }
            }
        }
        guard localCache.iCloudSyncEnabled,
              await isCurrentCloudState(for: account),
              await hasAvailableCloudAccount()
        else { return }

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
                logDebug("reconcile: timestamps match")
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
        } catch let error as ScheduleCloudTransportError {
            if error == .unknownItem {
                logDebug("remote record unavailable (\(error)); uploading initial local cache")
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
            String(account.generation),
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

        await presentConflict(signature) { resolution in
            if let resolution {
                await self.resolvePendingCloudConflict(
                    accountIdentifier: account.accountIdentifier,
                    signature: signature,
                    resolution: resolution
                )
            } else {
                await self.conflictPromptWasDismissed(signature)
            }
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
            let currentRemoteRecord = try await transport.record(named: conflict.account.recordName)
            guard let currentRemote = decodeCache(
                from: currentRemoteRecord,
                account: conflict.account
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
            guard await local.save(cache, .localWithoutCloudPush, conflict.account, currentLocalState.cache.updatedAt) else {
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
            guard await local.save(cache, .cloud, conflict.account, currentLocalState.cache.updatedAt) else {
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

        logDebug("upsert start record=\(account.recordName) updatedAt=\(debugDate(cache.updatedAt))")

        var record: ScheduleCloudRecord
        do {
            record = try await transport.record(named: account.recordName)
            logDebug("upsert fetched existing remote record")
            guard let decodedRemote = decodeCache(from: record, account: account) else {
                logError("upsert abort: remote payload decode failed record=\(account.recordName)")
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

        do {
            let savedRecord = try await transport.save(record)
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
        let cache: ScheduleCache
        let requiresPayloadMigration: Bool
        if let envelope = try? decoder.decode(ScheduleCloudSyncEnvelope.self, from: payloadData) {
            guard envelope.schemaVersion == ScheduleCloudSyncEnvelope.currentSchemaVersion else { return nil }
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
        do { return try await transport.accountAvailable() }
        catch {
            logError("cloud account status query failed: \(describe(error))")
            return false
        }
    }

    private func currentLocalCloudState() async -> LocalCloudState? {
        guard let account = await local.currentAccount(), !account.studentID.isEmpty else { return nil }
        return await currentLocalCloudState(matching: account)
    }

    private func currentLocalCloudState(matching account: CloudAccountContext) async -> LocalCloudState? {
        guard await local.currentAccount() == account else { return nil }
        let result = await local.load(account.session)
        guard let cache = result.cacheIfReadable, cache.iCloudSyncEnabled,
              await local.currentAccount() == account else { return nil }
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
        mergedCache.cloudSyncBaselineAt = cache.cloudSyncBaselineAt
        mergedCache.cloudSyncBaselineRecordTag = cache.cloudSyncBaselineRecordTag
        mergedCache.hasUnpushedCloudChanges = false
        mergedCache.updatedAt = max(state.cache.updatedAt, cache.updatedAt)
        return await local.save(mergedCache, .cloud, account, expectedLocalUpdatedAt)
    }

    private func persistCloudSyncStateIfCurrent(
        _ serverModifiedAt: Date,
        recordTag: String,
        account: CloudAccountContext,
        expectedLocalUpdatedAt: Date
    ) async {
        guard !recordTag.isEmpty,
              let state = await currentLocalCloudState(matching: account) else { return }
        var cache = state.cache
        cache.cloudSyncBaselineAt = serverModifiedAt
        cache.cloudSyncBaselineRecordTag = recordTag
        let source: ScheduleCacheSaveSource
        if state.cache.updatedAt == expectedLocalUpdatedAt {
            cache.updatedAt = ScheduleCacheTimestamp.afterCloudSave(serverModifiedAt, currentDate: state.cache.updatedAt)
            cache.hasUnpushedCloudChanges = false
            source = .cloud
        } else {
            guard state.cache.hasUnpushedCloudChanges else { return }
            source = .cloudBaseline
        }
        _ = await local.save(cache, source, account, state.cache.updatedAt)
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
