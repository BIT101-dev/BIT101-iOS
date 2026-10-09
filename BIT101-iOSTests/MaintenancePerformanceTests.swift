#if DEBUG
import XCTest
import UIKit
import CommunityCore
import MediaKit

nonisolated final class MaintenancePerformanceTests: XCTestCase {
    private nonisolated struct Item: Identifiable { let id: Int }

    func testCommunityPaginationPerformance() {
        let pages = (0..<1_000).map { page in (page * 100 ..< (page + 1) * 100).map { Item(id: $0) } }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var storage = CommunityPagedItems<Item>()
            for page in pages { storage.append(page) }
            for page in pages { storage.append(page) }
            XCTAssertEqual(storage.items.count, 100_000)
            XCTAssertEqual(storage.ids.count, 100_000)
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
