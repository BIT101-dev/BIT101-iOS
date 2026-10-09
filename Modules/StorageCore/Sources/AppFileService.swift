import Foundation

/// 清理前暂停新访问，等待已接收的持久化操作结束。
@MainActor
public final class StorageOperationTracker {
    private var activeOperations = 0
    private var suspensions = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public nonisolated init() {}
    public func begin() -> Bool {
        guard suspensions == 0 else { return false }
        activeOperations += 1
        return true
    }
    public func finish() {
        activeOperations -= 1
        if activeOperations == 0 {
            let current = waiters
            waiters.removeAll()
            for waiter in current { waiter.resume() }
        }
    }
    public func suspendAndDrain() async {
        suspensions += 1
        while activeOperations > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    public func resume() { suspensions -= 1 }
}

/// 文件服务接口。业务仓库使用逻辑路径和原子读写能力。
public nonisolated protocol AppFileService: Sendable {
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL?
    func appGroupContainerURL(identifier: String) -> URL?
    var temporaryDirectoryURL: URL { get }
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func readData(at url: URL, maximumBytes: Int) throws -> Data
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func setPrivateFileProtection(at url: URL) throws
    func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func regularFileSize(at url: URL) -> Int?
    /// Identity of immutable bytes replaced through an atomic write.
    func atomicFileIdentity(at url: URL) -> String?
    func isRegularFile(at url: URL) -> Bool
    func modificationDate(at url: URL) -> Date?
    func setModificationDate(_ date: Date, at url: URL) throws
    func removeContents(of directory: URL) -> Bool
    func totalRegularFileSize(at directory: URL) -> Int64
    func canonicalFileURL(_ url: URL) -> URL
}

extension AppFileService {
    public nonisolated func readData(at url: URL, maximumBytes: Int) throws -> Data {
        guard let size = regularFileSize(at: url), size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try readData(at: url)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
    public nonisolated func setBackupExcluded(_ excluded: Bool, at url: URL) throws {
        try setBackupExcluded(excluded, at: url, recursively: false)
    }
    public nonisolated func canonicalFileURL(_ url: URL) -> URL { url.standardizedFileURL }
}

/// 本机文件系统的默认实现。
public nonisolated struct LocalAppFileService: AppFileService, Sendable {
    private let configureBackup: @Sendable (URL, Bool) throws -> Void

    public init() { configureBackup = Self.configureBackup }
    init(configureBackup: @escaping @Sendable (URL, Bool) throws -> Void) {
        self.configureBackup = configureBackup
    }

    private var manager: FileManager { .default }

    public func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        manager.urls(for: directory, in: .userDomainMask).first
    }

    public func appGroupContainerURL(identifier: String) -> URL? {
        manager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public var temporaryDirectoryURL: URL { manager.temporaryDirectory }
    public func canonicalFileURL(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
    public func fileExists(at url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    public func readData(at url: URL) throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try Data(contentsOf: url)
    }

    public func readData(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let size = regularFileSize(at: url), size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        }
        return data
    }

    public func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        // 目录承载备份策略；元数据准备成功后提交文件内容。
        try setBackupExcluded(false, at: url.deletingLastPathComponent())
        try data.write(to: url, options: options)
    }

    public func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try setBackupExcluded(false, at: url)
    }
    public func removeItem(at url: URL) throws { try manager.removeItem(at: url) }
    public func setPrivateFileProtection(at url: URL) throws {
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    public func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws {
        try configureBackup(url, excluded)
        if recursively {
            guard let entries = manager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let entry as URL in entries {
                if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
                try configureBackup(entry, excluded)
            }
        }
    }

    private static func configureBackup(_ url: URL, excluded: Bool) throws {
        var targetURL = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try targetURL.setResourceValues(values)
    }

    public func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options)
    }

    public func regularFileSize(at url: URL) -> Int? {
        guard isRegularFile(at: url) else { return nil }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    public func atomicFileIdentity(at url: URL) -> String? {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber], let inode = attributes[.systemFileNumber],
              let size = attributes[.size] else { return nil }
        return "\(device):\(inode):\(size)"
    }

    public func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func setModificationDate(_ date: Date, at url: URL) throws {
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    public func removeContents(of directory: URL) -> Bool {
        guard fileExists(at: directory) else { return true }
        guard let children = try? contentsOfDirectory(at: directory, options: []) else { return false }
        var succeeded = true
        for child in children {
            do {
                try removeItem(at: child)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    public func totalRegularFileSize(at directory: URL) -> Int64 {
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64(regularFileSize(at: url) ?? 0)
        }
        return total
    }
}

/// App 及其扩展共享的文件服务入口。
public nonisolated enum AppFileSystem {
    public static let files: any AppFileService = LocalAppFileService()
    public static let protectedDataWritingOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication,
    ]
}
