import Foundation
import os
import StorageCore

package nonisolated final class ModuleScoreFiles: AppFileService, Sendable {
    package init() {}
    private let state = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var data: [URL: Data] = [:]
        var dates: [URL: Date] = [:]
        var directories: Set<URL> = []
        var failsWriting = false
        var failsRemoval = false
        var options: [URL: Data.WritingOptions] = [:]
    }
    package func setFailures(writing: Bool = false, removal: Bool = false) {
        return state.withLock { state in
            state.failsWriting = writing
            state.failsRemoval = removal
        }
    }
    package func writingOptions(at url: URL) -> Data.WritingOptions? {
        return state.withLock { state in
            return state.options[url]
        }
    }
    package var temporaryDirectoryURL: URL { URL(fileURLWithPath: "/module-score") }
    package func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? { temporaryDirectoryURL }
    package func appGroupContainerURL(identifier: String) -> URL? { temporaryDirectoryURL }
    package func fileExists(at url: URL) -> Bool {
        return state.withLock { state in
            return state.data[url] != nil || state.directories.contains(url)
        }
    }
    package func readData(at url: URL) throws -> Data {
        return try state.withLock { state in
            guard let value = state.data[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return value
        }
    }
    package func writeData(_ value: Data, to url: URL, options: Data.WritingOptions) throws {
        return try state.withLock { state in
            if state.failsWriting { throw CocoaError(.fileWriteNoPermission) }
            state.data[url] = value
            state.dates[url] = Date()
            state.options[url] = options
        }
    }
    package func createDirectory(at url: URL) throws {
        return state.withLock { state in
            _ = state.directories.insert(url)
        }
    }
    package func removeItem(at url: URL) throws {
        return try state.withLock { state in
            if state.failsRemoval { throw CocoaError(.fileWriteNoPermission) }
            state.data.removeValue(forKey: url)
            state.dates.removeValue(forKey: url)
            state.directories.remove(url)
        }
    }
    package func setPrivateFileProtection(at url: URL) throws {}
    package func setExcludedFromBackup(at url: URL) throws {}
    package func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        return state.withLock { state in
            return Array(Set(state.data.keys).union(state.directories)).filter { $0.deletingLastPathComponent() == url }
        }
    }
    package func regularFileSize(at url: URL) -> Int? {
        return state.withLock { state in
            return state.data[url]?.count
        }
    }
    package func isRegularFile(at url: URL) -> Bool { regularFileSize(at: url) != nil }
    package func modificationDate(at url: URL) -> Date? {
        return state.withLock { state in
            return state.dates[url]
        }
    }
    package func setModificationDate(_ date: Date, at url: URL) throws {
        return state.withLock { state in
            state.dates[url] = date
        }
    }
    package func removeContents(of directory: URL) -> Bool {
        return state.withLock { state in
            let prefix = directory.path + "/"
            state.data = state.data.filter { !$0.key.path.hasPrefix(prefix) }
            state.dates = state.dates.filter { !$0.key.path.hasPrefix(prefix) }
            state.directories = Set(state.directories.filter { !$0.path.hasPrefix(prefix) })
            return true
        }
    }
    package func totalRegularFileSize(at directory: URL) -> Int64 {
        return state.withLock { state in
            return state.data.filter { $0.key.path.hasPrefix(directory.path + "/") }.values.reduce(0) { $0 + Int64($1.count) }
        }
    }
}
