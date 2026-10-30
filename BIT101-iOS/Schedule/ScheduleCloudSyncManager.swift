import CommunityTransport
import CloudKit
import Combine
import Foundation
import os
import ScheduleDomain
import ScheduleSync
import StorageCore

@MainActor
final class AppCloudAccountGeneration {
    static let shared = AppCloudAccountGeneration()
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        subscription = center.publisher(for: .CKAccountChanged).sink { @Sendable [counter] _ in
            counter.withLock { $0 &+= 1 }
        }
    }

    var value: Int { counter.withLock { $0 } }
}

/// CloudKit adaptation and production dependency selection belong to the App host.
actor AppScheduleCloudTransport: ScheduleCloudTransport {
    private var container: CKContainer { CKContainer.default() }
    private let files: any AppFileService
    private static let uploads = AppScheduleCloudUploadQueue()

    init(files: any AppFileService = LocalAppFileService()) { self.files = files }

    func accountAvailable() async throws -> Bool {
        try Task.checkCancellation()
        let status = try await container.accountStatus()
        try Task.checkCancellation()
        return status == .available
    }

    func record(named name: String) async throws -> ScheduleCloudRecord {
        do {
            try Task.checkCancellation()
            let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: name))
            try Task.checkCancellation()
            return try encode(record)
        } catch { throw mapped(error) }
    }

    func save(_ value: ScheduleCloudRecord) async throws -> ScheduleCloudRecord {
        try await Self.uploads.run { try await self.saveOwned(value) }
    }

    private func saveOwned(_ value: ScheduleCloudRecord) async throws -> ScheduleCloudRecord {
        try Task.checkCancellation()
        let payload = try value.imageAssetPayload()
        let assetURL = files.temporaryDirectoryURL.appendingPathComponent("schedule-cloud-images.json")
        defer { try? files.removeItemIfPresent(at: assetURL) }
        let record: CKRecord
        if let fields = value.systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
            decoder.requiresSecureCoding = true
            guard let restored = CKRecord(coder: decoder) else { throw CocoaError(.coderReadCorrupt) }
            decoder.finishDecoding()
            record = restored
        } else {
            record = CKRecord(recordType: value.recordType, recordID: CKRecord.ID(recordName: value.recordName))
        }
        record["studentID"] = value.studentID as CKRecordValue?
        record["updatedAt"] = value.updatedAt as CKRecordValue?
        record["payloadJSON"] = payload.metadataJSON as CKRecordValue?
        if let data = payload.imagesData {
            try files.writeData(data, to: assetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            record["ddlImagesAsset"] = CKAsset(fileURL: assetURL)
        } else { record["ddlImagesAsset"] = nil }
        try Task.checkCancellation()
        do { return try encode(try await container.privateCloudDatabase.save(record)) }
        catch { throw mapped(error) }
    }

    private func encode(_ record: CKRecord) throws -> ScheduleCloudRecord {
        let imageData: Data?
        if let asset = record["ddlImagesAsset"] as? CKAsset {
            guard let url = asset.fileURL else { throw CocoaError(.fileReadUnknown) }
            imageData = try files.readData(at: url, maximumBytes: ScheduleCloudRecord.maximumImageAssetBytes)
        } else { imageData = nil }
        let payload = try ScheduleCloudImagePayload.joining(metadataJSON: record["payloadJSON"] as? String, imagesData: imageData)
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        encoder.finishEncoding()
        return ScheduleCloudRecord(
            recordName: record.recordID.recordName,
            recordType: record.recordType,
            studentID: record["studentID"] as? String,
            updatedAt: record["updatedAt"] as? Date,
            payloadJSON: payload,
            modificationDate: record.modificationDate,
            recordChangeTag: record.recordChangeTag,
            systemFields: encoder.encodedData
        )
    }

    private func mapped(_ error: Error) -> Error {
        guard let error = error as? CKError else { return error }
        switch error.code {
        case .unknownItem: return ScheduleCloudTransportError.unknownItem
        case .serverRecordChanged: return ScheduleCloudTransportError.serverRecordChanged
        default: return error
        }
    }
}

actor AppScheduleCloudUploadQueue {
    private var pending: Task<ScheduleCloudRecord, Error>?
    private var generation = 0
    func run(_ save: @escaping @Sendable () async throws -> ScheduleCloudRecord) async throws -> ScheduleCloudRecord {
        let previous = pending
        generation &+= 1
        let current = generation
        let operation = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await save()
        }
        pending = operation
        defer { if current == generation { pending = nil } }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}

extension ScheduleCloudSyncManager {
    @MainActor static let shared = ScheduleCloudSyncManager(
        local: ScheduleCloudLocalStore(
            currentAccount: {
                let credentials = AppAccountSession.storage.communityCredentials
                let studentID = AppAccountSession.storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !studentID.isEmpty else { return nil }
                return ScheduleCloudAccount(studentID: studentID, session: AppFileDirectories.currentSession,
                    generation: credentials.identity.generation, cloudGeneration: AppCloudAccountGeneration.shared.value)
            },
            load: { await ScheduleCacheStore.loadResultAsync(for: $0) },
            save: { cache, source, account, expectedUpdatedAt in
                guard AppAccountSession.storage.communityCredentials.identity.generation == account.generation,
                      AppCloudAccountGeneration.shared.value == account.cloudGeneration,
                      AppFileDirectories.currentSession == account.session else { return false }
                return await ScheduleCacheStore.saveAndWait(cache, source: source,
                    expectedAccountIdentifier: account.accountIdentifier, expectedUpdatedAt: expectedUpdatedAt,
                    isCurrent: { AppAccountSession.storage.communityCredentials.identity.generation == account.generation
                        && AppCloudAccountGeneration.shared.value == account.cloudGeneration
                        && AppFileDirectories.currentSession == account.session })
            }
        ),
        transport: AppScheduleCloudTransport(),
        presentConflict: appConflictPresenter(prompts: .shared),
        reportStatus: { account, status in ScheduleCloudSyncPresentation.shared.receive(account: account, status: status) }
    )

    static func appConflictPresenter(
        prompts: AppPromptCoordinator,
        currentIdentity: @escaping @MainActor @Sendable () -> CommunitySessionIdentity = {
            AppAccountSession.storage.communityCredentials.identity
        },
        currentCloudGeneration: @escaping @MainActor @Sendable () -> Int = { AppCloudAccountGeneration.shared.value }
    ) -> ScheduleCloudConflictPresenter {
        { account, context, resolve in
            let identity = CommunitySessionIdentity(accountIdentifier: account.session.accountIdentifier,
                generation: account.generation)
            guard identity == currentIdentity(), account.cloudGeneration == currentCloudGeneration() else {
                Task { await resolve(nil) }
                return
            }
            var completed = false
            let complete: @MainActor (ScheduleCacheConflictResolution?) -> Void = { resolution in
                guard !completed else { return }
                completed = true
                let choice = identity == currentIdentity() && account.cloudGeneration == currentCloudGeneration() ? resolution : nil
                Task { await resolve(choice) }
            }
            prompts.enqueue(AppPrompt(
                id: "schedule-cache-conflict-\(context.signature)-\(UUID().uuidString)",
                title: "本机和 iCloud 课表存在版本差异",
                message: context.hasCommonBaseline
                    ? "双方独立修改的内容会合并。同一项手动调整、个人日程、DDL 或设置发生冲突时，采用你选择的一侧。学校抓取数据沿用本机版本。"
                    : "本次首次关联本机与 iCloud 的用户数据。请选择采用哪一侧的手动调整、个人日程、DDL 和设置，所选内容会同步到另一侧。学校抓取数据沿用本机版本。",
                actions: [
                    AppPromptAction(id: "keep-local", title: "采用本机", isDefault: true) {
                        complete(.keepLocal)
                    },
                    AppPromptAction(id: "use-cloud", title: "采用 iCloud") {
                        complete(.useCloud)
                    },
                    AppPromptAction(id: "later", title: "稍后处理") {
                        complete(nil)
                    }
                ],
                account: identity,
                onDismiss: { complete(nil) },
                onCancel: { complete(nil) }
            ))
        }
    }
}

extension ScheduleCloudSyncPresentation {
    static let shared = ScheduleCloudSyncPresentation(currentAccount: {
        let storage = AppAccountSession.storage
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else { return nil }
        return ScheduleCloudAccount(studentID: studentID, session: AppFileDirectories.currentSession,
            generation: storage.communityCredentials.identity.generation, cloudGeneration: AppCloudAccountGeneration.shared.value)
    }, accountChanges: AppAccountSession.storage.changes)
}
