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
/// iPhone 主 App 与 Watch 接收执行器分别写入所属设备的快照，Widget 从共享目录读取。
/// 每个设备的生产写者共用串行队列和仓库实例；纯数据模型和时间线规则保留在 `ScheduleContracts`。
public nonisolated struct ScheduleExternalSnapshotStore: Sendable {
    private let synchronization = NSRecursiveLock()
    private let files: any AppFileService
    private let containerURL: URL?
    private let notificationCenter: NotificationCenter
    private struct ClearedSnapshot: Codable {
        enum Kind: String, Codable { case cleared }
        let kind: Kind
        let revision: UInt64
        let generatedAt: Date
    }
    private enum StoredState {
        case snapshot(ScheduleExternalSnapshot), cleared(ClearedSnapshot), missing
    }

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
        synchronization.lock()
        defer { synchronization.unlock() }
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
        synchronization.lock()
        defer { synchronization.unlock() }
        let snapshot = snapshot.replacingStudentID(with: AccountStorageIdentity.stableToken(for: snapshot.studentID))
        let state: StoredState
        do { state = try readState() }
        catch ScheduleExternalSnapshotStoreError.invalidSnapshot { state = .missing }
        switch state {
        case .snapshot(let current):
            if snapshot == current { return false }
            let newer = snapshot.revision == 0 && current.revision == 0
                ? snapshot.generatedAt > current.generatedAt : snapshot.revision > current.revision
            guard newer else { throw ScheduleExternalSnapshotStoreError.staleSnapshot }
        case .cleared(let boundary):
            let newer = snapshot.revision == 0 && boundary.revision == 0
                ? snapshot.generatedAt > boundary.generatedAt : snapshot.revision > boundary.revision
            guard newer else { throw ScheduleExternalSnapshotStoreError.staleSnapshot }
        case .missing: break
        }
        try write(snapshot)
        return true
    }

    public func load() -> ScheduleExternalSnapshot? {
        try? read()
    }

    /// 返回缺失状态，并保留损坏数据和磁盘读取失败的错误分类。
    public func read() throws -> ScheduleExternalSnapshot? {
        if case .snapshot(let snapshot) = try readState() { return snapshot }
        return nil
    }

    public var latestRevision: UInt64 {
        switch try? readState() {
        case .snapshot(let snapshot): snapshot.revision
        case .cleared(let boundary): boundary.revision
        default: 0
        }
    }

    private func readState() throws -> StoredState {
        guard let fileURL else { throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable }
        if let size = files.regularFileSize(at: fileURL), size > ScheduleExternalSnapshotCodec.maximumEncodedBytes {
            throw ScheduleExternalSnapshotStoreError.invalidSnapshot
        }
        let data: Data
        do { data = try files.readData(at: fileURL, maximumBytes: ScheduleExternalSnapshotCodec.maximumEncodedBytes) }
        catch where AppFileSystem.isMissingFile(error) { return .missing }
        catch let error as CocoaError where error.code == .fileReadTooLarge { throw ScheduleExternalSnapshotStoreError.invalidSnapshot }
        let snapshot: ScheduleExternalSnapshot
        do { snapshot = try ScheduleExternalSnapshotCodec.decode(data) }
        catch {
            if let boundary = try? JSONDecoder().decode(ClearedSnapshot.self, from: data) { return .cleared(boundary) }
            throw ScheduleExternalSnapshotStoreError.invalidSnapshot
        }
        let accountToken = AccountStorageIdentity.stableToken(for: snapshot.studentID)
        return .snapshot(snapshot.replacingStudentID(with: accountToken))
    }

    @discardableResult
    public func clearRetainingVersion() -> Bool {
        synchronization.lock()
        defer { synchronization.unlock() }
        guard let fileURL else { return false }
        do {
            switch try readState() {
            case .snapshot(let snapshot):
                let boundary = ClearedSnapshot(kind: .cleared, revision: snapshot.revision, generatedAt: snapshot.generatedAt)
                try files.writeData(JSONEncoder().encode(boundary), to: fileURL, options: AppFileSystem.protectedDataWritingOptions)
                Task { @MainActor in notificationCenter.post(name: .scheduleExternalSnapshotDidChange, object: nil) }
                return true
            case .cleared: return true
            case .missing: return clear()
            }
        } catch ScheduleExternalSnapshotStoreError.invalidSnapshot {
            return clear()
        } catch { return false }
    }

    @discardableResult
    public func clear() -> Bool {
        synchronization.lock()
        defer { synchronization.unlock() }
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
