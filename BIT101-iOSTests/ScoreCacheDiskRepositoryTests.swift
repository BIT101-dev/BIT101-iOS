import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
@testable import BIT101_iOS

@Suite("Score cache file safety")
struct ScoreCacheDiskRepositoryTests {
    @Test("Unreadable score snapshots block replacement and remain intact", .timeLimit(.minutes(1)))
    func preservesUnreadableSnapshot() async throws {
        let files = AppFileDirectories.files
        let root = files.temporaryDirectoryURL.appending(
            path: "score-cache-safety",
            directoryHint: .isDirectory
        )
        try files.removeItemIfPresent(at: root)
        let session = AppStorageSession(accountIdentifier: "score-store")
        let repository = ScoreCacheDiskRepository(files: files, storageRoot: root)
        defer {
            do {
                try files.removeItem(at: root)
                #expect(!files.fileExists(at: root))
            } catch { Issue.record(error) }
        }

        let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["离散数学"])]
        let saved = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: .empty
        )
        #expect(saved.isSaved)

        let fileURL = root
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
        let corruptData = Data("invalid score cache".utf8)
        try files.writeData(corruptData, to: fileURL, options: [.atomic])

        let loadResult = await repository.load(for: session, legacyData: .empty)
        #expect(loadResult.isUnreadable)

        let replacement = await repository.mutate(
            .rows([]),
            for: session,
            legacyData: .empty
        )
        #expect(replacement.isUnreadable)
        #expect(try files.readData(at: fileURL) == corruptData)
    }
}

nonisolated final class PreferenceMemoryFiles: AppFileService, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let requireExistingParentDirectories: Bool
    private let separatesDirectories: Bool
    private struct State {
        var data: [URL: Data] = [:]
        var revisions: [URL: UInt64] = [:]
        var revision: UInt64 = 0
        var reads: [URL: Int] = [:]
        var metadataScans = 0
        var backupMetadataWrites = 0
        var failsBackupMetadata = false
        var directories: Set<URL> = []
        var failsRemoval = false
        var failsWriting = false
        var failsReading = false
        var failsMetadata = false
        var protectedRemovalPaths: Set<URL> = []
        var nextRead: (@Sendable () -> Void)?
        var nextWrite: (@Sendable () -> Void)?
        var nextEnumeration: (@Sendable () -> Void)?
    }
    init(requireExistingParentDirectories: Bool = false, separatesDirectories: Bool = false) {
        self.requireExistingParentDirectories = requireExistingParentDirectories
        self.separatesDirectories = separatesDirectories
    }
    func setFailures(removal: Bool = false, writing: Bool = false, reading: Bool = false, metadata: Bool = false) {
        state.withLock {
            $0.failsRemoval = removal; $0.failsWriting = writing; $0.failsReading = reading; $0.failsMetadata = metadata
        }
    }
    func protectRemoval(of directories: Set<URL>) {
        state.withLock { $0.protectedRemovalPaths = directories }
    }
    private var root: URL { URL(fileURLWithPath: "/preference-sync") }
    var temporaryDirectoryURL: URL { separatesDirectories ? root.appending(path: "Temporary") : root }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
        separatesDirectories ? root.appending(path: String(directory.rawValue)) : root
    }
    func appGroupContainerURL(identifier: String) -> URL? { temporaryDirectoryURL }
    func fileExists(at url: URL) -> Bool {
        state.withLock { !$0.failsMetadata && ($0.data[url] != nil || $0.directories.contains { $0.path == url.path }) }
    }
    func readData(at url: URL) throws -> Data {
        let intercept = state.withLock { state in
            let callback = state.nextRead
            state.nextRead = nil
            return callback
        }
        intercept?()
        return try state.withLock { state in
            state.reads[url, default: 0] += 1
            if state.failsReading { throw CocoaError(.fileReadNoPermission) }
            guard let value = state.data[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return value
        }
    }
    func interceptNextRead(_ callback: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextRead = callback }
    }
    func writeData(_ value: Data, to url: URL, options: Data.WritingOptions) throws {
        let intercept = try state.withLock { state -> (@Sendable () -> Void)? in
            if state.failsWriting { throw CocoaError(.fileWriteNoPermission) }
            if requireExistingParentDirectories && !state.directories.contains(url.deletingLastPathComponent()) {
                throw CocoaError(.fileNoSuchFile)
            }
            state.data[url] = value
            state.revision &+= 1
            state.revisions[url] = state.revision
            let callback = state.nextWrite
            state.nextWrite = nil
            return callback
        }
        intercept?()
    }
    func interceptNextWrite(_ callback: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextWrite = callback }
    }
    func removeItem(at url: URL) throws {
        try state.withLock { state in
            if state.failsRemoval || state.protectedRemovalPaths.contains(url) { throw CocoaError(.fileWriteNoPermission) }
            let prefix = url.path + "/"
            state.data = state.data.filter { $0.key.path != url.path && !$0.key.path.hasPrefix(prefix) }
            state.revisions = state.revisions.filter { state.data[$0.key] != nil }
            state.directories = state.directories.filter { $0.path != url.path && !$0.path.hasPrefix(prefix) }
        }
    }
    func createDirectory(at url: URL) throws {
        state.withLock { state in
            var directory = url
            while directory.path != "/" {
                state.directories.insert(directory)
                directory.deleteLastPathComponent()
            }
        }
    }
    func setPrivateFileProtection(at url: URL) throws {}
    var backupMetadataWriteCount: Int { state.withLock { $0.backupMetadataWrites } }
    func failBackupMetadata(_ failed: Bool) { state.withLock { $0.failsBackupMetadata = failed } }
    func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws {
        try state.withLock {
            $0.backupMetadataWrites += 1
            if $0.failsBackupMetadata { throw CocoaError(.fileWriteNoPermission) }
        }
    }
    func beforeNextEnumeration(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextEnumeration = action }
    }
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        let intercept = state.withLock { state in
            let callback = state.nextEnumeration
            state.nextEnumeration = nil
            return callback
        }
        intercept?()
        return state.withLock { state in
            Array(Set(state.data.keys).union(state.directories)).filter {
                $0.deletingLastPathComponent().path == url.path &&
                    (!options.contains(.skipsHiddenFiles) || !$0.lastPathComponent.hasPrefix("."))
            }
        }
    }
    func regularFileSize(at url: URL) -> Int? { state.withLock { $0.data[url]?.count } }
    var metadataScanCount: Int { state.withLock { $0.metadataScans } }
    func regularFileMetadata(in directory: URL) throws -> [AppRegularFileMetadata] {
        state.withLock { $0.metadataScans += 1 }
        return try contentsOfDirectory(at: directory, options: .skipsHiddenFiles).compactMap { url in
            regularFileSize(at: url).map { AppRegularFileMetadata(url: canonicalFileURL(url), size: $0,
                modificationDate: modificationDate(at: url) ?? .distantPast) }
        }
    }
    func isRegularFile(at url: URL) -> Bool { regularFileSize(at: url) != nil }
    func readCount(at url: URL) -> Int { state.withLock { $0.reads[url] ?? 0 } }
    func atomicFileIdentity(at url: URL) -> String? {
        state.withLock { state in state.data[url].flatMap { _ in state.revisions[url].map(String.init) } }
    }
    func modificationDate(at url: URL) -> Date? { nil }
    func setModificationDate(_ date: Date, at url: URL) throws {}
    func removeContents(of directory: URL) -> Bool {
        return state.withLock { state in
            let hasContents = state.data.keys.contains { $0.path.hasPrefix(directory.path + "/") } ||
                state.directories.contains { $0.path.hasPrefix(directory.path + "/") }
            guard hasContents else { return true }
            guard !state.failsRemoval,
                  !state.protectedRemovalPaths.contains(where: { $0.path.hasPrefix(directory.path + "/") }) else { return false }
            state.data = state.data.filter { !$0.key.path.hasPrefix(directory.path + "/") }
            state.revisions = state.revisions.filter { state.data[$0.key] != nil }
            state.directories = state.directories.filter { !$0.path.hasPrefix(directory.path + "/") }
            return true
        }
    }
    func totalRegularFileSize(at directory: URL) -> Int64 {
        return state.withLock { state in
            return state.data.filter { $0.key.path.hasPrefix(directory.path + "/") }.values.reduce(0) { $0 + Int64($1.count) }
        }
    }
}
