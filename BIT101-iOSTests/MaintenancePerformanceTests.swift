#if DEBUG
import XCTest
import Combine
@testable import BIT101_iOS
import UIKit
import SwiftUI
import DesignSystemKit
import CommunityCore
import CommunityTransport
import CommunityPersistence
@testable import MediaKit
import ImageIO
import UniformTypeIdentifiers
import ScheduleContracts
import ScheduleSharedStore
import ScheduleDomain
@testable import PaperFeature
@testable import MineFeature
@testable import GalleryFeature
import TransportCore
import StorageCore

private nonisolated final class PerformanceResponseProtocol: URLProtocol {
    static let bytes = Data(repeating: 1, count: 32 * 1_024 * 1_024)
    static let chunkBytes = 64 * 1_024
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.bytes.count)]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: Self.bytes.count, by: Self.chunkBytes) {
            autoreleasepool {
                client?.urlProtocol(self, didLoad: Self.bytes.subdata(in: offset ..< min(offset + Self.chunkBytes, Self.bytes.count)))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private struct PerformancePaperService: PaperListServicing {
    let pages: [[PaperSummary]]
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
        pages.indices.contains(page) ? pages[page] : []
    }
    func fetchPaper(id: Int) async throws -> PaperDetail { throw URLError(.unsupportedURL) }
    func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { throw URLError(.unsupportedURL) }
}

@MainActor
private final class RecoveryScanResponse: HTTPTransport {
    var calls = 0
    let large: Bool
    init(large: Bool) { self.large = large }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        if url.path == "/user/check" { return (Data(), response) }
        calls += 1
        let user: [String: Any] = ["id": 1, "create_time": "", "nickname": "fixture", "motto": "",
            "avatar": ["mid": "", "url": "", "low_url": ""],
            "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
        let values: [[String: Any]] = (1...(large ? NetworkSmokePaging.maximumSampleItems + 1 : 1)).map { offset in
            let id = large ? offset : calls
            if url.path == "/papers" {
                return ["id": id, "title": "fixture", "intro": "fixture", "like_num": 0, "comment_num": 0, "update_time": ""]
            }
            var item: [String: Any] = ["id": id, "user": user, "anonymous": false, "create_time": "", "update_time": "",
                "images": [], "like_num": 0, "comment_num": 0, "text": "fixture"]
            if url.path == "/posters" {
                item.merge(["claim": ["id": 0, "text": ""], "edit_time": "", "public": false, "tags": [], "title": "fixture"]) { _, new in new }
            } else {
                item.merge(["obj": "poster1", "like": false, "own": false, "rate": 0, "reply_user": user, "reply_obj": "", "sub": []]) { _, new in new }
            }
            return item
        }
        return (try JSONSerialization.data(withJSONObject: values), response)
    }
}

nonisolated final class MaintenancePerformanceTests: XCTestCase {

    func testLocalPhotoImportRejectsOversizedSourcesBeforeReading() async throws {
        let files = PreferenceMemoryFiles(), limit = RemoteImageResourceLimits.maximumEncodedBytes
        let url = files.temporaryDirectoryURL.appendingPathComponent("photo-source")
        try files.writeData(Data(repeating: 0, count: limit + 1), to: url, options: [])
        files.interceptNextRead { XCTFail("源文件超过预算时应在读取内容前结束") }
        do {
            _ = try await PickedImageData.readFile(at: url, using: files)
            XCTFail("照片源文件需要进入字节预算验收")
        } catch PickedImageData.ImportError.tooLarge {
            XCTAssertEqual(files.regularFileSize(at: url), limit + 1)
        }
    }

    @MainActor func testLocalPhotoImportKeepsTheUIResponsiveAndHonorsCancellation() async throws {
        let files = PreferenceMemoryFiles(), bytes = Data("photo-source".utf8)
        let url = files.temporaryDirectoryURL.appendingPathComponent("photo-source")
        try files.writeData(bytes, to: url, options: [])
        let reading = expectation(description: "photo disk read"), responsive = expectation(description: "photo UI response")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        files.interceptNextRead {
            XCTAssertFalse(Thread.isMainThread)
            reading.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        let read = Task { try await PickedImageData.readFile(at: url, using: files) }
        await fulfillment(of: [reading], timeout: 5)
        responsive.fulfill()
        await fulfillment(of: [responsive], timeout: 1)
        release.signal()
        let loaded = try await read.value
        XCTAssertEqual(loaded, bytes)
        files.interceptNextRead { XCTFail("已取消的导入应在读取前结束") }
        let cancelled = Task { try await PickedImageData.readFile(at: url, using: files) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("取消状态需要传递到照片文件读取") }
        catch is CancellationError { XCTAssertTrue(cancelled.isCancelled) }
    }

    @MainActor func testProductionWriteRecoveryUsesTheSharedScanBudget() async throws {
        for (kind, large) in [("poster", false), ("comments", false), ("poster", true), ("paper", true), ("comments", true)] {
            let route = RecoveryScanResponse(large: large)
            let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
                baseURL: AppURL.required("https://example.invalid"),
                credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
            let preferences = { CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                useWebView: false, hideMakeupOutliers: false) }
            let operations = CommunityWriteSmoke.Operations.production(papers: PaperService(session: session),
                gallery: GalleryService(session: session, preferences: preferences), mine: MineService(session: session, preferences: preferences))
            do {
                if kind == "comments" { _ = try await operations.comments("poster1", nil) }
                else { _ = try await operations.find(kind == "poster" ? .poster : .paper, "fixture") }
                XCTFail("恢复扫描达到预算时需要保留恢复记录并报告样本问题")
            } catch NetworkSmokePaging.SamplingError.budgetExceeded {
                XCTAssertEqual(route.calls, large ? 1 : NetworkSmokePaging.maximumSamplePages)
            }
        }
    }

    func testWatchSnapshotPersistenceKeepsMainActorResponsiveAndRetainsClearBoundary() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        let persistence = WatchSnapshotPersistence(store: store)
        let snapshot = ScheduleExternalSnapshot(revision: 1, isLoggedIn: true, studentID: "watch-owner",
            firstDayString: "2026-01-01", timeTable: [], courses: [])
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot), receivedAt = ContinuousClock.now
        let writing = expectation(description: "watch snapshot disk write"), responsive = expectation(description: "watch UI response")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        files.interceptNextWrite {
            XCTAssertFalse(Thread.isMainThread)
            writing.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        let receipt = Task { @MainActor in await persistence.receive(data, receivedAt: receivedAt, accountIdentifier: nil) }
        await fulfillment(of: [writing], timeout: 5)
        await MainActor.run { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        release.signal()
        let received = try await receipt.value.get()
        XCTAssertTrue(received)
        let cleared = await persistence.clear(at: .now)
        XCTAssertTrue(cleared)
        XCTAssertNil(store.load())
        let delayed = await persistence.receive(data, receivedAt: receivedAt, accountIdentifier: nil)
        XCTAssertEqual(delayed, .failure(.staleSnapshot))
        let stale = await persistence.receive(data, receivedAt: .now, accountIdentifier: nil)
        XCTAssertEqual(stale, .failure(.staleSnapshot))
        let newer = try XCTUnwrap(snapshot.advancingRevision(after: 1))
        let accepted = try await persistence.receive(ScheduleExternalSnapshotCodec.encode(newer), receivedAt: .now, accountIdentifier: nil).get()
        XCTAssertTrue(accepted)
    }

    func testConcurrentSharedSnapshotWritesKeepTheHighestRevision() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        for batch in 0..<8 {
            await withTaskGroup(of: Void.self) { group in
                for offset in 1...64 {
                    group.addTask {
                        let snapshot = ScheduleExternalSnapshot(revision: UInt64(batch * 64 + offset), isLoggedIn: true,
                            studentID: "watch-owner", firstDayString: "2026-01-01", timeTable: [], courses: [])
                        do { _ = try store.writeIfNewer(snapshot) }
                        catch ScheduleExternalSnapshotStoreError.staleSnapshot {
                            XCTAssertGreaterThanOrEqual(store.load()?.revision ?? 0, snapshot.revision)
                        }
                        catch { XCTFail(error.localizedDescription) }
                    }
                }
            }
            XCTAssertEqual(store.load()?.revision, UInt64((batch + 1) * 64))
        }
    }

    func testSharedSnapshotExportReadKeepsMainActorResponsive() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        let reader = ScheduleExternalSnapshotWriteQueue(store: store)
        let reading = expectation(description: "shared snapshot disk read")
        let responsive = expectation(description: "main actor during shared snapshot read")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        files.interceptNextRead {
            XCTAssertFalse(Thread.isMainThread)
            reading.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        let export = Task { @MainActor in
            await ScheduleWidgetExporter.syncFromCurrentCache(loadSnapshot: { await reader.load() })
        }
        await fulfillment(of: [reading], timeout: 5)
        let clear = Task { @MainActor in
            let cleared = await ScheduleWidgetExporter.clearSharedSnapshot(
                clearSnapshot: { snapshot, _ in (true, snapshot) }, publishSnapshot: { _ in })
            XCTAssertTrue(cleared)
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 1)
        release.signal()
        await clear.value
        await export.value
    }

    func testMessageReadQueriesAcrossRenderedPages() async throws {
        let workload = try PerformanceWorkload("message-read-queries", bundle: Bundle(for: Self.self))
        let count = try workload.value("idsPerType", as: Int.self), passes = try workload.value("passes", as: Int.self)
        let renderedCount = try workload.value("renderedIDsPerType", as: Int.self)
        XCTAssertGreaterThan(count, GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        XCTAssertEqual(renderedCount, GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        XCTAssertEqual(try workload.value("types", as: [String].self), GalleryMessageType.allCases.map(\.rawValue))
        XCTAssertEqual(try workload.value("cache", as: String.self), "cold-read-and-write-per-sample")
        let domain = "BIT101Performance.message-read-queries"
        let files = LocalAppFileService()
        let storageRoot = files.temporaryDirectoryURL.appending(path: "BIT101Performance-message-read", directoryHint: .isDirectory)
        try files.removeItemIfPresent(at: storageRoot)
        defer { do { try files.removeItemIfPresent(at: storageRoot) } catch { XCTFail("性能夹具清理失败：\(error)") } }
        _ = try await Task { @MainActor in
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defaults.removePersistentDomain(forName: domain)
            let store = GalleryMessageReadStore(files: files, storageRoot: storageRoot, defaults: defaults, session: { .init(accountIdentifier: "performance") })
            for type in GalleryMessageType.allCases {
                let saved = await store.replaceLatestIDs(Array(1...count), unreadCount: count, for: type)
                XCTAssertTrue(saved)
                let read = await store.markSeen(ids: Array(1...count / 2), for: type)
                XCTAssertTrue(read)
            }
            return store
        }.value
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "message row unread queries")
            Task { @MainActor in
                guard let defaults = UserDefaults(suiteName: domain) else { XCTFail("消息快照需要独立偏好仓库"); completed.fulfill(); return }
                let store = GalleryMessageReadStore(files: files, storageRoot: storageRoot, defaults: defaults,
                    session: { .init(accountIdentifier: "performance") })
                await store.prepareSnapshot()
                XCTAssertEqual(store.unreadCount(for: .comment), count / 2)
                let saved = await store.setPendingUnreadAfterID(count, for: .comment)
                XCTAssertTrue(saved)
                var unread = 0
                for _ in 0..<passes {
                    for type in GalleryMessageType.allCases {
                        for id in (count - renderedCount + 1)...count where store.isUnread(id: id, for: type) { unread += 1 }
                    }
                }
                XCTAssertEqual(unread, passes * GalleryMessageType.allCases.count * renderedCount)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
        await MainActor.run { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
    }

    func testImageQuotaEnumerationKeepsPreviewResponsiveAndRetainsLatePins() async throws {
        let files = PreferenceMemoryFiles(), ownership = PreviewFileOwnership(), owner = UUID()
        let directory = files.temporaryDirectoryURL.appending(path: "quota-preview")
        let file = directory.appending(path: "image.png")
        try files.createDirectory(at: directory)
        try files.writeData(Data(count: 2 * 1_024 * 1_024), to: file, options: [.atomic])
        let scanning = expectation(description: "cache enumeration"), opened = expectation(description: "preview opened")
        let release = DispatchSemaphore(value: 0)
        files.beforeNextEnumeration { scanning.fulfill(); _ = release.wait(timeout: .now() + 10) }
        let quota = ImageCacheDiskQuota(files: files, directories: [directory], cacheLimitMB: { 1 }, previewOwnership: ownership)
        let scan = Task.detached { await quota.enforce(force: true) }
        await fulfillment(of: [scanning], timeout: 5)
        let preview = Task { @MainActor in
            ownership.begin(owner)
            XCTAssertTrue(ownership.pin(file, using: files, owner: owner))
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 1)
        release.signal()
        await scan.value
        await preview.value
        XCTAssertTrue(files.fileExists(at: file))
        ownership.end(owner)
    }

    func testPreviewSessionsRemainResponsiveDuringDiskOperations() async throws {
        for writing in [false, true] {
            let files = PreferenceMemoryFiles(), ownership = PreviewFileOwnership(), owner = UUID()
            let directory = files.temporaryDirectoryURL.appending(path: "preview-disk-operations")
            let file = directory.appending(path: "image.png")
            try files.createDirectory(at: directory)
            try files.writeData(Data("preview".utf8), to: file, options: [.atomic])
            ownership.begin(owner)
            XCTAssertTrue(ownership.pin(file, using: files, owner: owner))
            let busy = expectation(description: "disk operation"), responsive = expectation(description: "preview state")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            if !writing { files.beforeNextEnumeration { busy.fulfill(); _ = release.wait(timeout: .now() + 10) } }
            let operation = Task.detached {
                if writing {
                    do {
                        try ownership.materializeAndPin(file, using: files, owner: owner) {
                            busy.fulfill()
                            _ = release.wait(timeout: .now() + 10)
                            try files.writeData(Data("updated".utf8), to: file, options: [.atomic])
                        }
                        XCTFail("Closed preview completed a pending write")
                    } catch { XCTAssertTrue(error is CancellationError) }
                } else { XCTAssertTrue(ownership.clearDirectory(directory, using: files)) }
            }
            await fulfillment(of: [busy], timeout: 5)
            let preview = Task { @MainActor in
                let anotherOwner = UUID()
                ownership.begin(anotherOwner)
                let cleanup = ownership.end(owner)
                ownership.end(anotherOwner)
                XCTAssertFalse(ownership.contains(owner))
                responsive.fulfill()
                return cleanup
            }
            await fulfillment(of: [responsive], timeout: 1)
            release.signal()
            await operation.value
            let cleanup = await preview.value
            await cleanup.value
            XCTAssertFalse(files.fileExists(at: file))
        }
    }

    func testDeferredPreviewCleanupFinishesAfterExternalFileRemoval() async throws {
        let files = LocalAppFileService(), ownership = PreviewFileOwnership()
        let directory = files.temporaryDirectoryURL.appending(path: "preview-deferred-cleanup")
        let file = directory.appending(path: "image.png")
        try files.removeItemIfPresent(at: directory)
        try files.createDirectory(at: directory)
        defer {
            do { try files.removeItemIfPresent(at: directory) }
            catch { XCTFail("Preview fixture cleanup failed: \(error)") }
        }
        let first = UUID(), second = UUID()
        ownership.begin(first)
        try ownership.materializeAndPin(file, using: files, owner: first) {
            try files.writeData(Data("original".utf8), to: file, options: [.atomic])
        }
        XCTAssertTrue(ownership.clearDirectory(directory, using: files))
        try files.removeItem(at: file)
        await ownership.end(first).value
        ownership.begin(second)
        let replacement = Data("replacement".utf8)
        try ownership.materializeAndPin(file, using: files, owner: second) {
            try files.writeData(replacement, to: file, options: [.atomic])
        }
        await ownership.end(second).value
        XCTAssertEqual(try files.readData(at: file), replacement)
    }

    func testImageQuotaScanAcrossDirectorySizes() async throws {
        let workload = try PerformanceWorkload("image-quota-scan", bundle: Bundle(for: Self.self))
        let files = LocalAppFileService()
        let root = files.temporaryDirectoryURL.appending(path: "quota-directory-scan")
        if files.fileExists(at: root) { try files.removeItem(at: root) }
        defer {
            do { try files.removeItem(at: root) }
            catch { XCTFail("Cache fixture cleanup failed: \(error)") }
        }
        let directories = [root.appending(path: "gallery"), root.appending(path: "avatars")]
        for directory in directories { try files.createDirectory(at: directory) }
        let quota = ImageCacheDiskQuota(files: files, directories: directories, cacheLimitMB: { 200 })
        let bytes = Data(repeating: 0, count: 2_048)
        var previousCount = 0
        var rows = ["files,medianMilliseconds"]
        for count in [100, 1_000, 10_000] {
            for index in previousCount..<count {
                try files.writeData(bytes, to: directories[index % 2].appending(path: "\(index).png"), options: [])
            }
            previousCount = count
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                await quota.enforce(force: true, protecting: [directories[0].appending(path: "0.png")])
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
            let usedBytes = await quota.usedBytes()
            XCTAssertEqual(usedBytes, Int64(count * bytes.count))
            rows.append("\(count),\(samples.sorted()[1])")
        }
        XCTAssertEqual(previousCount, try workload.value("files", as: Int.self))
        XCTAssertEqual(bytes.count, try workload.value("bytesPerFile", as: Int.self))
        XCTAssertEqual(directories.count, try workload.value("directories", as: Int.self))
        XCTAssertTrue(try workload.value("force", as: Bool.self))
        let protected = directories[0].appending(path: "0.png")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "production image quota scan")
            Task.detached {
                await quota.enforce(force: true, protecting: [protected])
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
        let report = rows.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "cache-directory-scan"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
    }

    @MainActor
    func testBoundedResponseAggregationPerformance() throws {
        let workload = try PerformanceWorkload("response-aggregation", bundle: Bundle(for: Self.self))
        XCTAssertEqual(PerformanceResponseProtocol.bytes.count, try workload.value("bytes", as: Int.self))
        XCTAssertEqual(PerformanceResponseProtocol.chunkBytes, try workload.value("chunkBytes", as: Int.self))
        XCTAssertEqual(try workload.value("transport", as: String.self), "URLSession")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerformanceResponseProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: session, observer: nil)
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://performance.invalid/media")))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "bounded response aggregation")
            Task { @MainActor in
                do {
                    let result = try await client.send(request, maximumBytes: PerformanceResponseProtocol.bytes.count)
                    XCTAssertEqual(result.data, PerformanceResponseProtocol.bytes)
                } catch { XCTFail("Bounded transport error: \(error)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
    }

    @MainActor
    func testCommunityPaginationPerformance() throws {
        let workload = try PerformanceWorkload("pagination", bundle: Bundle(for: Self.self))
        let pageCount = try workload.value("pages", as: Int.self)
        let itemsPerPage = try workload.value("itemsPerPage", as: Int.self)
        let passes = try workload.value("passes", as: Int.self)
        XCTAssertEqual(try workload.value("states", as: [String].self), ["PaperListViewModel", "GalleryMessageListState"])
        XCTAssertTrue(try workload.value("refreshEachPass", as: Bool.self))
        let pages = (0..<pageCount).map { page in (page * itemsPerPage ..< (page + 1) * itemsPerPage).map {
            PaperSummary(id: $0, title: "文章", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        } }
        let decoder = JSONDecoder()
        let messagePages = try pages.map { page in
            let rows = page.map { "{\"fromUser\":{},\"id\":\(pageCount * itemsPerPage - $0.id),\"linkObj\":\"\",\"obj\":\"\",\"text\":\"message\",\"updateTime\":\"\"}" }
            return try decoder.decode([GalleryMessage].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "production pagination")
            Task { @MainActor in
                let model = PaperListViewModel(service: PerformancePaperService(pages: pages))
                let observation = model.objectWillChange.sink { _ in }
                defer { observation.cancel() }
                var messages = GalleryMessageListState()
                for _ in 0..<passes {
                    await model.refresh()
                    for _ in 1..<pages.count { await model.loadMoreIfNeeded(currentPaper: model.state.items.last) }
                    messages.applyFirstCursorPage(messagePages[0])
                    for page in messagePages.dropFirst() { messages.appendCursorPage(page) }
                    XCTAssertEqual(messages.items.count, pageCount * itemsPerPage)
                    XCTAssertEqual(messages.nextCursor, 1)
                }
                XCTAssertEqual(model.state.items.count, pageCount * itemsPerPage)
                XCTAssertEqual(model.state.nextPage, pageCount)
                XCTAssertEqual(messages.items.count, pageCount * itemsPerPage)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
    }

    @MainActor
    func testLongCommentThreadPerformance() throws {
        let workload = try PerformanceWorkload("comment-thread", bundle: Bundle(for: Self.self))
        let threads = try workload.value("threads", as: Int.self)
        let replies = try workload.value("repliesPerThread", as: Int.self)
        let depth = try workload.value("depth", as: Int.self)
        let user = CommunityUser.placeholder(id: 1, nickname: "作者")
        func comment(_ id: Int, sub: [CommunityComment] = []) -> CommunityComment {
            .init(id: id, obj: "poster1", images: [], user: user, anonymous: false, createTime: "", updateTime: "",
                like: false, likeNum: 0, commentNum: 0, own: false, rate: 0, replyUser: user, replyObj: "",
                text: "回复 \(id)", sub: sub)
        }
        let roots = (0..<threads).map { thread in
            let base = (thread + 1) * (replies + depth)
            var nested = comment(base)
            for level in 0..<depth { nested = comment(base + replies + level, sub: [nested]) }
            return comment(thread + 1, sub: [nested] + (1..<replies).map { comment(base + $0) })
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var state = CommunityCommentState()
            state.items = roots
            for thread in 0..<threads {
                state.recordLike(.init(like: true, likeNum: 1), for: (thread + 1) * (replies + depth))
                let flattened = state.items[thread].flattenedReplies
                XCTAssertEqual(flattened.count, replies + depth)
                XCTAssertEqual(flattened.filter(\.like).count, 1)
            }
            let items = state.items
            window.rootViewController = UIHostingController(rootView: ScrollView {
                LazyVStack {
                    ForEach(items) { comment in
                        AppCommentThread(comment: comment, subcomments: comment.flattenedReplies) { reply, _ in
                            Text(reply.text)
                        }
                    }
                }
            })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
    }

    @MainActor
    func testConcurrentMediaPipelinePerformance() throws {
        let workload = try PerformanceWorkload("media-pipeline", bundle: Bundle(for: Self.self))
        let downloadCount = try workload.value("concurrentDownloads", as: Int.self)
        let displayedCount = try workload.value("displayedImages", as: Int.self)
        let side = try workload.value("imageSide", as: Int.self)
        let avatarSide = try workload.value("avatarSide", as: Int.self)
        let animatedCount = try workload.value("animatedImages", as: Int.self)
        let animatedSide = try workload.value("animatedSide", as: Int.self)
        let frames = try workload.value("animatedFrames", as: Int.self)
        XCTAssertEqual(downloadCount, MediaDownloadCoordinator.maximumConcurrentDownloads)
        XCTAssertEqual(try workload.value("encodedBytes", as: Int.self), RemoteImageResourceLimits.maximumEncodedBytes)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { $0.fill(CGRect(x: 0, y: 0, width: side, height: side)) }.pngData())
        let gif = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, frames, nil))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: animatedSide, height: animatedSide), format: format)
        for index in 0..<frames {
            let frame = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(frames), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: animatedSide, height: animatedSide))
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(frame.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerformanceResponseProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: session, observer: nil)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "combined media pipeline")
            Task { @MainActor in
                defer { completed.fulfill() }
                do {
                    let files = PreferenceMemoryFiles()
                    let media = AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files),
                        defaults: AppFileDirectories.defaults, imageHTTPClient: client, avatarHTTPClient: client)
                    var displays: [MediaDisplayedImage] = []
                    for index in 0..<displayedCount {
                        let file = files.temporaryDirectoryURL.appending(path: "media-\(index).png")
                        try files.writeData(png, to: file, options: [.atomic])
                        let decoded = await media.stillDecoder.image(at: file)
                        let image = try XCTUnwrap(decoded)
                        let display = MediaDisplayedImage()
                        XCTAssertTrue(display.set(image, budget: media.displayBudget))
                        displays.append(display)
                        let avatarURL = try XCTUnwrap(URL(string: "https://performance.invalid/avatar/\(index)"))
                        await media.avatars.store(png, for: avatarURL)
                        let avatar = await media.avatars.image(for: avatarURL, maximumPixelSize: avatarSide)
                        XCTAssertNotNil(avatar)
                        if index < animatedCount {
                            let animation = files.temporaryDirectoryURL.appending(path: "media-\(index).gif")
                            try files.writeData(gif as Data, to: animation, options: [.atomic])
                            let animated = await media.animatedDecoder.image(at: animation, reduceMotion: false)
                            XCTAssertNotNil(animated)
                        }
                    }
                    XCTAssertEqual(media.displayBudget.usedBytes, media.displayBudget.maximumBytes)
                    let downloads = (0..<downloadCount).map { index in
                        Task { @MainActor in
                            try await media.downloads.response(for: XCTUnwrap(URL(string: "https://performance.invalid/image/\(index)")),
                                source: index.isMultiple(of: 2) ? .avatar : .gallery)
                        }
                    }
                    defer { for task in downloads { task.cancel() } }
                    var responses: [HTTPResponse] = []
                    for task in downloads { responses.append(try await task.value) }
                    XCTAssertEqual(responses.count, downloadCount)
                    XCTAssertTrue(responses.allSatisfy { $0.data.count == RemoteImageResourceLimits.maximumEncodedBytes })
                    await media.releaseCachedImages()
                    XCTAssertTrue(displays.allSatisfy { $0.image != nil })
                    for display in displays { display.clear() }
                    XCTAssertEqual(media.displayBudget.usedBytes, 0)
                } catch { XCTFail("Combined media pipeline error: \(error)") }
            }
            wait(for: [completed], timeout: 60)
        }
    }

    func testStillImageDecodingPerformance() throws {
        let workload = try PerformanceWorkload("image-decoding", bundle: Bundle(for: Self.self))
        let width = try workload.value("width", as: Int.self), height = try workload.value("height", as: Int.self)
        XCTAssertEqual(try workload.value("format", as: String.self), "PNG")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = try XCTUnwrap(image.pngData())
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let decoded = BoundedStillImageDecoder.image(from: data)
            XCTAssertEqual(decoded?.size, image.size)
        }
    }

    @MainActor
    func testLocalPreviewFirstPagePerformance() throws {
        let workload = try PerformanceWorkload("local-preview", bundle: Bundle(for: Self.self))
        let pageCount = try workload.value("pages", as: Int.self)
        let width = try workload.value("width", as: Int.self), height = try workload.value("height", as: Int.self)
        let initialIndex = try workload.value("initialIndex", as: Int.self)
        XCTAssertEqual(try workload.value("storage", as: String.self), "disk")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let images = (0..<pageCount).map { index in renderer.image { context in
            UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 1, brightness: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: session, observer: nil)
        let media = AppMedia.makeEnvironment(files: AppFileDirectories.files,
            previewStorage: MediaPreviewStorage(files: AppFileDirectories.files), defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "local preview first page")
            Task { @MainActor in
                let request = ImagePreviewRequest(localImages: images, initialIndex: initialIndex)
                media.beginPreview(owner: request.id)
                defer { media.endPreview(owner: request.id); completed.fulfill() }
                do {
                    let prepared = try await coordinator.prepareInitialItems(for: request, media: media)
                    XCTAssertEqual(prepared.items.count, pageCount)
                    XCTAssertEqual(prepared.initialIndex, initialIndex)
                    let selected = prepared.items[initialIndex].url
                    XCTAssertTrue(prepared.items.enumerated().allSatisfy { $0.offset == initialIndex || $0.element.url != selected })
                } catch { XCTFail("Local preview error: \(error)") }
            }
            wait(for: [completed], timeout: 60)
        }
    }

    @MainActor
    func testLongArticleRenderingPerformance() throws {
        let workload = try PerformanceWorkload("long-article", bundle: Bundle(for: Self.self))
        let paragraphs = try workload.value("paragraphs", as: Int.self)
        XCTAssertEqual(paragraphs, PaperContentResourceLimits.maximumBlocks)
        XCTAssertEqual(try workload.value("inlineFormats", as: [String].self), ["bold", "italic", "link", "line-break"])
        let paragraph = String(repeating: "<b>文章正文</b><i>内联格式</i><a href=\"https://example.invalid/paper\">链接</a><br>",
            count: try workload.value("repetitionsPerParagraph", as: Int.self))
        let blocks = (0..<paragraphs).map { ["id": "block-\($0)", "type": "paragraph", "data": ["text": paragraph]] as [String: Any] }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]), as: UTF8.self)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rendered = PaperContentRenderer.blocks(from: content)
            XCTAssertEqual(rendered.count, paragraphs)
            XCTAssertTrue(PaperEditorContentBuilder.plainText(from: content).contains("文章正文"))
        }
    }

    func testGIFDecodingPerformance() throws {
        let workload = try PerformanceWorkload("gif-decoding", bundle: Bundle(for: Self.self))
        let frames = try workload.value("frames", as: Int.self)
        let width = try workload.value("width", as: Int.self), height = try workload.value("height", as: Int.self)
        XCTAssertEqual(try workload.value("cache", as: String.self), "cleared-per-sample")
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        for index in 0..<frames {
            let image = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(frames), saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let url = URL(fileURLWithPath: "/performance/image.gif")
        try files.writeData(data as Data, to: url, options: .atomic)
        let decoder = RemoteAnimatedImageDecoder(files: files)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "GIF decoding")
            Task.detached {
                await decoder.clear()
                let image = await decoder.image(at: url, reduceMotion: false)
                XCTAssertEqual(image?.images?.count, frames)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 5)
        }
    }

    @MainActor
    func testSingleCourseEditingPerformance() throws {
        let workload = try PerformanceWorkload("course-editing", bundle: Bundle(for: Self.self))
        let count = try workload.value("courses", as: Int.self)
        let original = try (0..<count).map { index in
            try XCTUnwrap(ScheduleCourseEditor.adding(CourseDraft(title: "课程\(index)", weeksText: "1-20"),
                to: [], term: "performance", id: "course-\(index)").first)
        }
        let selected = try workload.value("editedIndex", as: Int.self)
        let edited = try ScheduleCourseEditor.updatingArrangements([(original[selected].id, CourseDraft(title: original[selected].name, weekday: 2, weeksText: "1-20"))], in: original)
        let replacement = try XCTUnwrap(edited.last)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rules = ScheduleCourseEditor.updatingRules(existing: [], baselineCourses: original,
                previousCourses: original, currentCourses: edited)
            XCTAssertEqual(rules.count, 1)
            XCTAssertEqual(rules.first?.sourceCourses, [original[selected]])
            XCTAssertEqual(rules.first?.replacementCourses, [replacement])
        }
    }

    func testWidgetTimelinePerformance() throws {
        let workload = try PerformanceWorkload("widget-timeline", bundle: Bundle(for: Self.self))
        XCTAssertEqual(try workload.value("planning", as: String.self), "next-day-phone-timeline")
        let courseCount = try workload.value("courses", as: Int.self), weeks = try workload.value("weeks", as: Int.self)
        let expectedOccurrences = try workload.value("occurrences", as: Int.self)
        let slots = try workload.value("slots", as: Int.self), expectedEntries = try workload.value("timelineEntries", as: Int.self)
        let firstDay = "2024-02-26"
        let now = try XCTUnwrap(ScheduleSharedDateCodec.parseDate(firstDay))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "performance", firstDayString: firstDay,
            timeTable: (0..<slots).map { .init(id: $0 + 1, start: String(format: "%02d:00", $0 + 8), end: String(format: "%02d:45", $0 + 8)) },
            courses: (0..<courseCount).map { index in
                let section = (index / 7) % slots + 1
                return .init(id: "course-\(index)", name: "课程", classroom: "教学楼", teacher: "教师",
                    weeks: Array(1...weeks), weekday: index % 7 + 1, startSection: section, endSection: section)
            })
        XCTAssertEqual(ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now).count, expectedOccurrences)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let entries = ScheduleOccurrenceResolver.resolvedTimeline(from: snapshot, now: now, includeDisplayUntilDates: true, limit: 6)
            XCTAssertEqual(entries.first?.date, now)
            XCTAssertEqual(entries.last?.date, now.addingTimeInterval(24 * 60 * 60))
            XCTAssertEqual(entries.count, expectedEntries)
            XCTAssertTrue(entries.allSatisfy { $0.resolved.upcomingOccurrences.count <= 6 })
        }
    }
}
#endif
