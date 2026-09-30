import CommunityTransport
import CloudKit
import Foundation
import ScheduleDomain
import ScheduleSync
import StorageCore

/// CloudKit adaptation and production dependency selection belong to the App host.
actor AppScheduleCloudTransport: ScheduleCloudTransport {
    private var container: CKContainer { CKContainer.default() }

    func accountAvailable() async throws -> Bool {
        try await container.accountStatus() == .available
    }

    func record(named name: String) async throws -> ScheduleCloudRecord {
        do {
            let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: name))
            return encode(record)
        } catch { throw mapped(error) }
    }

    func save(_ value: ScheduleCloudRecord) async throws -> ScheduleCloudRecord {
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
        record["payloadJSON"] = value.payloadJSON as CKRecordValue?
        do { return encode(try await container.privateCloudDatabase.save(record)) }
        catch { throw mapped(error) }
    }

    private func encode(_ record: CKRecord) -> ScheduleCloudRecord {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        encoder.finishEncoding()
        return ScheduleCloudRecord(
            recordName: record.recordID.recordName,
            recordType: record.recordType,
            studentID: record["studentID"] as? String,
            updatedAt: record["updatedAt"] as? Date,
            payloadJSON: record["payloadJSON"] as? String,
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

extension ScheduleCloudSyncManager {
    @MainActor static let shared = ScheduleCloudSyncManager(
        local: ScheduleCloudLocalStore(
            currentAccount: {
                let credentials = LoginStorage.shared.communityCredentials
                let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !studentID.isEmpty else { return nil }
                return ScheduleCloudAccount(studentID: studentID, session: AppFileDirectories.currentSession,
                                            generation: credentials.identity.generation)
            },
            load: { await ScheduleCacheStore.loadResultAsync(for: $0) },
            save: { cache, source, account, expectedUpdatedAt in
                guard LoginStorage.shared.communityCredentials.identity.generation == account.generation,
                      AppFileDirectories.currentSession == account.session else { return false }
                return await ScheduleCacheStore.saveAndWait(cache, source: source,
                    expectedAccountIdentifier: account.accountIdentifier, expectedUpdatedAt: expectedUpdatedAt,
                    isCurrent: { LoginStorage.shared.communityCredentials.identity.generation == account.generation
                        && AppFileDirectories.currentSession == account.session })
            }
        ),
        transport: AppScheduleCloudTransport(),
        presentConflict: appConflictPresenter(prompts: .shared)
    )

    static func appConflictPresenter(prompts: AppPromptCoordinator) -> ScheduleCloudConflictPresenter {
        { signature, resolve in
            prompts.enqueue(AppPrompt(
                id: "schedule-cache-conflict-\(signature)-\(UUID().uuidString)",
                title: "本机和 iCloud 课表存在版本差异",
                message: "本机与 iCloud 中的手动调整、个人日程、DDL 或设置存在版本差异。请选择保留本机版本或使用 iCloud 版本；选择会替换另一侧这部分用户数据，学校抓取数据保留本机版本。",
                actions: [
                    AppPromptAction(id: "keep-local", title: "保留本机", isDefault: true) {
                        Task { await resolve(.keepLocal) }
                    },
                    AppPromptAction(id: "use-cloud", title: "使用 iCloud") {
                        Task { await resolve(.useCloud) }
                    },
                    AppPromptAction(id: "later", title: "稍后处理") {
                        Task { await resolve(nil) }
                    }
                ]
            ))
        }
    }
}
