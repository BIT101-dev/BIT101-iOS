#if DEBUG
import XCTest
import UIKit
import CommunityCore
@testable import MediaKit
import ImageIO
import UniformTypeIdentifiers
import ScheduleContracts
@testable import PaperFeature
@testable import MineFeature
@testable import GalleryFeature

nonisolated final class MaintenancePerformanceTests: XCTestCase {
    private nonisolated struct Item: Identifiable { let id: Int }

    @MainActor
    func testCommunityPaginationPerformance() throws {
        let pages = (0..<1_000).map { page in (page * 100 ..< (page + 1) * 100).map { Item(id: $0) } }
        let decoder = JSONDecoder()
        let messagePages = try pages.map { page in
            let rows = page.map { "{\"fromUser\":{},\"id\":\($0.id),\"linkObj\":\"\",\"obj\":\"\",\"text\":\"message\",\"updateTime\":\"\"}" }
            return try decoder.decode([GalleryMessage].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var mine = MinePagedState<Item>()
            var messages = GalleryMessageListState()
            for _ in 0..<2 {
                for page in pages { mine.appendPage(page) }
                for page in messagePages { messages.appendCursorPage(page) }
            }
            XCTAssertEqual(mine.items.count, 100_000)
            XCTAssertEqual(messages.items.count, 100_000)
        }
    }

    func testStillImageDecodingPerformance() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { context in
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        let data = try XCTUnwrap(image.pngData())
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let decoded = BoundedStillImageDecoder.image(from: data)
            XCTAssertEqual(decoded?.size, image.size)
        }
    }

    @MainActor
    func testLongArticleRenderingPerformance() throws {
        let paragraph = String(repeating: "文章正文与链接 ", count: 64)
        let blocks = (0..<40).map { ["id": "block-\($0)", "type": "paragraph", "data": ["text": paragraph]] as [String: Any] }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]), as: UTF8.self)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rendered = PaperContentRenderer.blocks(from: content)
            XCTAssertEqual(rendered.count, 40)
            XCTAssertTrue(PaperEditorContentBuilder.plainText(from: content).contains("文章正文"))
        }
    }

    func testGIFDecodingPerformance() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 24, nil))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        for index in 0..<24 {
            let image = renderer.image { context in
                UIColor(hue: CGFloat(index) / 24, saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
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
                XCTAssertEqual(image?.images?.count, 24)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 5)
        }
    }

    func testWidgetTimelinePerformance() throws {
        let firstDay = "2024-02-26"
        let now = try XCTUnwrap(ScheduleSharedDateCodec.parseDate(firstDay))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "performance", firstDayString: firstDay,
            timeTable: [.init(id: 1, start: "08:00", end: "08:45")], courses: (0..<200).map { index in
                .init(id: "course-\(index)", name: "课程", classroom: "教学楼", teacher: "教师",
                    weeks: Array(1...20), weekday: index % 7 + 1, startSection: 1, endSection: 1)
            })
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let occurrences = ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now)
            XCTAssertEqual(occurrences.count, 4_000)
            XCTAssertGreaterThan(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: occurrences, now: now,
                includeDisplayUntilDates: true, includeNextMidnight: true), now)
        }
    }
}
#endif
