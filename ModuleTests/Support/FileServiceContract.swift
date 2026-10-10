import Foundation
import StorageCore
import Testing

public func waitForTestEvent(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        try Task.checkCancellation()
        if try await condition() { return }
        if clock.now >= deadline { throw URLError(.timedOut) }
        await Task.yield()
    }
}

public nonisolated func verifyFileServiceContract(
    _ files: any AppFileService,
    root: URL,
    setRemovalFailure: ((Bool) -> Void)? = nil
) throws {
    try files.createDirectory(at: root)
    defer { try? files.removeItem(at: root) }
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
    #expect(files.removeContents(of: root))
    #expect(files.fileExists(at: root))
    #expect(try files.contentsOfDirectory(at: root, options: []).isEmpty)
    setRemovalFailure?(true)
    #expect(files.removeContents(of: root))
    setRemovalFailure?(false)
}
