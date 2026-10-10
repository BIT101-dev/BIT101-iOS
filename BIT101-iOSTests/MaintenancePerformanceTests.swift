#if DEBUG
import XCTest
import Combine
@testable import BIT101_iOS
import UIKit
import CommunityCore
@testable import MediaKit
import ImageIO
import UniformTypeIdentifiers
import ScheduleContracts
@testable import PaperFeature
@testable import MineFeature
@testable import GalleryFeature
import TransportCore

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

nonisolated final class MaintenancePerformanceTests: XCTestCase {

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
        let media = MediaEnvironment(files: AppFileDirectories.files,
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
