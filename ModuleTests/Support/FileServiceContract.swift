import Foundation
import StorageCore
import Testing

public func waitForTestEvent(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () throws -> Bool
) async throws {
    try await waitForAsyncTestEvent(timeout: timeout, isolation: isolation) { try condition() }
}

public func waitForAsyncTestEvent(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        try Task.checkCancellation()
        let complete = try await condition()
        if clock.now >= deadline { throw URLError(.timedOut) }
        if complete { return }
        try await clock.sleep(for: .milliseconds(1))
    }
}

public func waitForTestEvent<Owner: Actor>(
    isolation: isolated Owner,
    timeout: Duration = .seconds(5),
    _ condition: @Sendable (isolated Owner) throws -> Bool
) async throws {
    try await waitForTestEvent(timeout: timeout, isolation: isolation) { try condition(isolation) }
}

public nonisolated func verifyFileServiceContract(
    _ files: any AppFileService,
    root: URL,
    setRemovalFailure: ((Bool) -> Void)? = nil
) throws {
    try files.removeItemIfPresent(at: root)
    try files.createDirectory(at: root)
    defer { do { try files.removeItem(at: root) } catch { Issue.record(error) } }
    let nested = root.appendingPathComponent("nested/child", isDirectory: true)
    let folder = nested.deletingLastPathComponent()
    let item = nested.appendingPathComponent("value")
    let hidden = root.appendingPathComponent(".hidden")
    let absent = root.appendingPathComponent("absent")
    do { _ = try files.readData(at: absent, maximumBytes: 10); Issue.record("缺失文件读取需要返回缺失错误") }
    catch { #expect(AppFileSystem.isMissingFile(error)) }
    try files.removeItemIfPresent(at: absent)
    try files.createDirectory(at: nested)
    try files.writeData(Data([1, 2, 3]), to: item, options: .atomic)
    let identity = try #require(files.atomicFileIdentity(at: item))
    try files.setModificationDate(Date(), at: item)
    #expect(files.atomicFileIdentity(at: item) == identity)
    try files.writeData(Data([3, 2, 1]), to: item, options: .atomic)
    #expect(files.atomicFileIdentity(at: item) != identity)
    #expect(files.atomicFileIdentity(at: nested) == nil)
    try files.writeData(Data([4]), to: hidden, options: .atomic)
    #expect(files.fileExists(at: root))
    #expect(files.fileExists(at: folder))
    #expect(files.fileExists(at: nested))
    #expect(!files.isRegularFile(at: nested))
    #expect(Set(try files.contentsOfDirectory(at: root, options: []).map(\.lastPathComponent)) == ["nested", ".hidden"])
    #expect(try files.contentsOfDirectory(at: root, options: .skipsHiddenFiles).map(\.lastPathComponent) == ["nested"])
    #expect(try files.regularFileMetadata(in: root).isEmpty)
    let metadata = try #require(files.regularFileMetadata(in: nested).first)
    #expect(metadata.url == files.canonicalFileURL(item))
    #expect(metadata.size == 3)
    #expect(metadata.modificationDate == (files.modificationDate(at: item) ?? .distantPast))
    if files is LocalAppFileService {
        let alias = root.appendingPathComponent("directory-alias")
        let link = nested.appendingPathComponent("file-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item)
        let entries = try files.regularFileMetadata(in: alias)
        #expect(entries.map(\.url) == [files.canonicalFileURL(item)])
        try files.removeItem(at: alias)
        try files.removeItem(at: link)
    }
    #expect(files.totalRegularFileSize(at: root) == 4)
    try files.removeItem(at: folder)
    #expect(!files.fileExists(at: folder))
    #expect(!files.fileExists(at: nested))
    #expect(!files.fileExists(at: item))
    #expect(files.totalRegularFileSize(at: root) == 1)
    if let setRemovalFailure {
        setRemovalFailure(true)
        #expect(!files.removeContents(of: root))
        #expect(files.fileExists(at: hidden))
        #expect(throws: CocoaError.self) { try files.removeItem(at: hidden) }
        setRemovalFailure(false)
    }
    if files is LocalAppFileService {
        let manager = FileManager.default
        let permissions = try #require(manager.attributesOfItem(atPath: root.path)[.posixPermissions])
        defer {
            do { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
            catch { Issue.record(error) }
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(!files.removeContents(of: root))
        #expect(try files.readData(at: hidden) == Data([4]))
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        #expect(!files.removeContents(of: root))
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
        #expect(try files.readData(at: hidden) == Data([4]))
    }
    #expect(files.removeContents(of: root))
    #expect(files.fileExists(at: root))
    #expect(try files.contentsOfDirectory(at: root, options: []).isEmpty)
    setRemovalFailure?(true)
    #expect(files.removeContents(of: root))
    setRemovalFailure?(false)
}
