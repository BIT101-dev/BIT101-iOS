#if DEBUG
import XCTest
import UIKit
import CommunityCore
import MediaKit
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
}
#endif
