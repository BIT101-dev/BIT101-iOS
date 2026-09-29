import Foundation

/// 文件服务接口。业务仓库使用逻辑路径和原子读写能力，不直接依赖 FileManager。
nonisolated protocol AppFileService: Sendable {
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL?
    func appGroupContainerURL(identifier: String) -> URL?
    var temporaryDirectoryURL: URL { get }
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func setPrivateFileProtection(at url: URL) throws
    func setExcludedFromBackup(at url: URL) throws
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func regularFileSize(at url: URL) -> Int?
    func isRegularFile(at url: URL) -> Bool
    func modificationDate(at url: URL) -> Date?
    func setModificationDate(_ date: Date, at url: URL) throws
    func removeContents(of directory: URL) -> Bool
    func totalRegularFileSize(at directory: URL) -> Int64
}

/// 本机文件系统的默认实现。
nonisolated struct LocalAppFileService: AppFileService, Sendable {
    private var manager: FileManager { .default }

    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        manager.urls(for: directory, in: .userDomainMask).first
    }

    func appGroupContainerURL(identifier: String) -> URL? {
        manager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    var temporaryDirectoryURL: URL { manager.temporaryDirectory }
    func fileExists(at url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    func readData(at url: URL) throws -> Data {
        try setExcludedFromBackup(at: url)
        return try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
        try setExcludedFromBackup(at: url)
    }

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try setExcludedFromBackup(at: url)
    }
    func removeItem(at url: URL) throws { try manager.removeItem(at: url) }
    func setPrivateFileProtection(at url: URL) throws {
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func setExcludedFromBackup(at url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var targetURL = url
        try targetURL.setResourceValues(resourceValues)
    }

    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options)
    }

    func regularFileSize(at url: URL) -> Int? {
        guard isRegularFile(at: url) else { return nil }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func setModificationDate(_ date: Date, at url: URL) throws {
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func removeContents(of directory: URL) -> Bool {
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

    func totalRegularFileSize(at directory: URL) -> Int64 {
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
nonisolated enum AppFileSystem {
    static let files: any AppFileService = LocalAppFileService()
    static let protectedDataWritingOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUntilFirstUserAuthentication,
    ]
}
