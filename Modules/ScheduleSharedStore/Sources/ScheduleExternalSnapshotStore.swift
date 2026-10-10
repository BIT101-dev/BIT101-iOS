import StorageCore
import Foundation
import ScheduleContracts

public enum ScheduleExternalSnapshotStoreError: Error, Equatable {
    case sharedContainerUnavailable
    case invalidSnapshot
    case staleSnapshot
}

/// 跨 target 共享快照的磁盘仓库。
///
/// 主 App 写入这份快照，Widget 和 Watch 读取这份快照；
/// 纯数据模型和时间线规则保留在 `ScheduleContracts`。
public nonisolated struct ScheduleExternalSnapshotStore: Sendable {
    private let files: any AppFileService
    private let containerURL: URL?
    private let notificationCenter: NotificationCenter

    public init(files: any AppFileService, containerURL: URL?, notificationCenter: NotificationCenter = .default) {
        self.files = files
        self.containerURL = containerURL
        self.notificationCenter = notificationCenter
    }

    @discardableResult
    public func save(_ snapshot: ScheduleExternalSnapshot) -> Bool {
        do {
            try write(snapshot)
            return true
        } catch {
            return false
        }
    }

    public func write(_ snapshot: ScheduleExternalSnapshot) throws {
        guard let fileURL else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try files.createDirectory(at: fileURL.deletingLastPathComponent())
        let accountToken = AccountStorageIdentity.stableToken(for: snapshot.studentID)
        let data = try ScheduleExternalSnapshotCodec.encode(
            snapshot.replacingStudentID(with: accountToken),
            outputFormatting: [.prettyPrinted, .sortedKeys]
        )
        try files.writeData(
            data,
            to: fileURL,
            options: AppFileSystem.protectedDataWritingOptions
        )
        Task { @MainActor in
            notificationCenter.post(name: .scheduleExternalSnapshotDidChange, object: nil)
        }
    }

    @discardableResult
    public func writeIfNewer(_ snapshot: ScheduleExternalSnapshot) throws -> Bool {
        let snapshot = snapshot.replacingStudentID(with: AccountStorageIdentity.stableToken(for: snapshot.studentID))
        let current: ScheduleExternalSnapshot?
        do { current = try read() }
        catch ScheduleExternalSnapshotStoreError.invalidSnapshot { current = nil }
        if let current {
            if snapshot == current { return false }
            let newer = snapshot.revision == 0 && current.revision == 0
                ? snapshot.generatedAt > current.generatedAt : snapshot.revision > current.revision
            guard newer else { throw ScheduleExternalSnapshotStoreError.staleSnapshot }
        }
        try write(snapshot)
        return true
    }

    public func load() -> ScheduleExternalSnapshot? {
        try? read()
    }

    /// 返回缺失状态，并保留损坏数据和磁盘读取失败的错误分类。
    public func read() throws -> ScheduleExternalSnapshot? {
        guard let fileURL else { throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable }
        if let size = files.regularFileSize(at: fileURL), size > ScheduleExternalSnapshotCodec.maximumEncodedBytes {
            throw ScheduleExternalSnapshotStoreError.invalidSnapshot
        }
        let data: Data
        do { data = try files.readData(at: fileURL, maximumBytes: ScheduleExternalSnapshotCodec.maximumEncodedBytes) }
        catch where AppFileSystem.isMissingFile(error) { return nil }
        catch let error as CocoaError where error.code == .fileReadTooLarge { throw ScheduleExternalSnapshotStoreError.invalidSnapshot }
        let snapshot: ScheduleExternalSnapshot
        do { snapshot = try ScheduleExternalSnapshotCodec.decode(data) }
        catch { throw ScheduleExternalSnapshotStoreError.invalidSnapshot }
        let accountToken = AccountStorageIdentity.stableToken(for: snapshot.studentID)
        guard snapshot.studentID != accountToken else { return snapshot }
        return snapshot.replacingStudentID(with: accountToken)
    }

    @discardableResult
    public func clear() -> Bool {
        guard let fileURL else { return false }
        let succeeded: Bool
        do {
            try files.removeItemIfPresent(at: fileURL)
            succeeded = true
        } catch {
            succeeded = false
        }
        if succeeded {
            Task { @MainActor in
                notificationCenter.post(name: .scheduleExternalSnapshotDidChange, object: nil)
            }
        }
        return succeeded
    }

    public var fileURL: URL? {
        guard let containerURL else { return nil }
        return containerURL
            .appending(path: ScheduleSharedContainer.directoryName, directoryHint: .isDirectory)
            .appending(path: ScheduleSharedContainer.snapshotFileName)
    }
}
