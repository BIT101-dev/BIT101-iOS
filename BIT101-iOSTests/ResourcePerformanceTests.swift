#if DEBUG
import XCTest
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

extension MaintenancePerformanceTests {
    @MainActor
    func testLocalPreviewFirstPagePerformance() throws {
        let workload = try PerformanceWorkload("local-preview", bundle: Bundle(for: Self.self))
        let pageCount = try workload.value("pages", as: Int.self)
        let width = try workload.value("width", as: Int.self)
        let height = try workload.value("height", as: Int.self)
        let initialIndex = try workload.value("initialIndex", as: Int.self)
        XCTAssertEqual(try workload.value("storage", as: String.self), "disk")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        let images = (0..<pageCount).map { index in
            renderer.image { context in
                UIColor(
                    hue: CGFloat(index) / CGFloat(pageCount), saturation: 1, brightness: 1,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: session, observer: nil)
        let media = AppMedia.makeEnvironment(
            files: AppFileDirectories.files,
            previewStorage: MediaPreviewStorage(files: AppFileDirectories.files),
            defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let completed = expectation(description: "local preview first page")
            Task { @MainActor in
                let request = ImagePreviewRequest(
                    localImages: images, initialIndex: initialIndex)
                media.beginPreview(owner: request.id)
                defer {
                    media.endPreview(owner: request.id)
                    completed.fulfill()
                }
                do {
                    let prepared = try await coordinator.prepareInitialItems(
                        for: request, media: media)
                    XCTAssertEqual(prepared.items.count, pageCount)
                    XCTAssertEqual(prepared.initialIndex, initialIndex)
                    let selected = prepared.items[initialIndex].url
                    XCTAssertTrue(
                        prepared.items.enumerated().allSatisfy {
                            $0.offset == initialIndex || $0.element.url != selected
                        })
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
        XCTAssertEqual(
            try workload.value("inlineFormats", as: [String].self),
            ["bold", "italic", "link", "line-break"])
        let paragraph = String(
            repeating:
                "<b>文章正文</b><i>内联格式</i><a href=\"https://example.invalid/paper\">链接</a><br>",
            count: try workload.value("repetitionsPerParagraph", as: Int.self))
        let blocks = (0..<paragraphs).map {
            ["id": "block-\($0)", "type": "paragraph", "data": ["text": paragraph]]
                as [String: Any]
        }
        let content = String(
            decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]),
            as: UTF8.self)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rendered = PaperContentRenderer.blocks(from: content)
            XCTAssertEqual(rendered.count, paragraphs)
            XCTAssertTrue(PaperEditorContentBuilder.plainText(from: content).contains("文章正文"))
        }
    }

    func testGIFDecodingPerformance() throws {
        let workload = try PerformanceWorkload("gif-decoding", bundle: Bundle(for: Self.self))
        let frames = try workload.value("frames", as: Int.self)
        let width = try workload.value("width", as: Int.self)
        let height = try workload.value("height", as: Int.self)
        XCTAssertEqual(try workload.value("cache", as: String.self), "cleared-per-sample")
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data, UTType.gif.identifier as CFString, frames, nil))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        for index in 0..<frames {
            let image = renderer.image { context in
                UIColor(
                    hue: CGFloat(index) / CGFloat(frames), saturation: 1, brightness: 1,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(
                destination, try XCTUnwrap(image.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]]
                    as CFDictionary)
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
            try XCTUnwrap(
                ScheduleCourseEditor.adding(
                    CourseDraft(title: "课程\(index)", weeksText: "1-20"),
                    to: [], term: "performance", id: "course-\(index)"
                ).first)
        }
        let selected = try workload.value("editedIndex", as: Int.self)
        let edited = try ScheduleCourseEditor.updatingArrangements(
            [
                (
                    original[selected].id,
                    CourseDraft(title: original[selected].name, weekday: 2, weeksText: "1-20")
                )
            ], in: original)
        let replacement = try XCTUnwrap(edited.last)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let rules = ScheduleCourseEditor.updatingRules(
                existing: [], baselineCourses: original,
                previousCourses: original, currentCourses: edited)
            XCTAssertEqual(rules.count, 1)
            XCTAssertEqual(rules.first?.sourceCourses, [original[selected]])
            XCTAssertEqual(rules.first?.replacementCourses, [replacement])
        }
    }

    func testWidgetTimelinePerformance() throws {
        let workload = try PerformanceWorkload(
            "widget-timeline", bundle: Bundle(for: Self.self))
        XCTAssertEqual(
            try workload.value("planning", as: String.self), "next-day-phone-timeline")
        let courseCount = try workload.value("courses", as: Int.self)
        let weeks = try workload.value("weeks", as: Int.self)
        let expectedOccurrences = try workload.value("occurrences", as: Int.self)
        let slots = try workload.value("slots", as: Int.self)
        let expectedEntries = try workload.value("timelineEntries", as: Int.self)
        let firstDay = "2024-02-26"
        let now = try XCTUnwrap(ScheduleSharedDateCodec.parseDate(firstDay))
        let snapshot = ScheduleExternalSnapshot(
            isLoggedIn: true, studentID: "performance", firstDayString: firstDay,
            timeTable: (0..<slots).map {
                .init(
                    id: $0 + 1, start: String(format: "%02d:00", $0 + 8),
                    end: String(format: "%02d:45", $0 + 8))
            },
            courses: (0..<courseCount).map { index in
                let section = (index / 7) % slots + 1
                return .init(
                    id: "course-\(index)", name: "课程", classroom: "教学楼", teacher: "教师",
                    weeks: Array(1...weeks), weekday: index % 7 + 1, startSection: section,
                    endSection: section)
            })
        XCTAssertEqual(
            ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now).count,
            expectedOccurrences)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let entries = ScheduleOccurrenceResolver.resolvedTimeline(
                from: snapshot, now: now, includeDisplayUntilDates: true, limit: 6)
            XCTAssertEqual(entries.first?.date, now)
            XCTAssertEqual(entries.last?.date, now.addingTimeInterval(24 * 60 * 60))
            XCTAssertEqual(entries.count, expectedEntries)
            XCTAssertTrue(entries.allSatisfy { $0.resolved.upcomingOccurrences.count <= 6 })
        }
    }
}
#endif
