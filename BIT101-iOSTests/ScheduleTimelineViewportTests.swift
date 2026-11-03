import DesignSystemKit
import Foundation
import ScheduleDomain
import StorageCore
import SwiftUI
import Testing
import TransportCore
import UIKit

@testable import BIT101_iOS
@testable import ScheduleFeature

@Suite("Schedule linear timeline viewport")
struct ScheduleTimelineViewportTests {
    @Test(
        "Calendar entries keep the same rendered height across display frames", .serialized,
        .timeLimit(.minutes(1)),
        arguments: [
            (false, DynamicTypeSize.large), (false, .xxxLarge), (false, .accessibility3),
            (true, .large),
        ])
    @MainActor func calendarEntryUsesOneSafeAreaProposal(fixture: (Bool, DynamicTypeSize))
        async throws
    {
        let (linear, textSize) = fixture
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        var cache = ScheduleCache()
        cache.currentTerm = "frame-fixture"
        cache.courseData.store(
            .init(
                term: cache.currentTerm, firstDayString: "2026-09-07", courses: [], exams: [],
                updatedAt: .now))
        let repository = ScheduleRepository(
            session: { .init(accountIdentifier: "calendar-frame-fixture") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        let service = SemesterStartDateService()
        let model = ScheduleViewModel(
            service: service, repository: repository, ddlService: service,
            classroomService: service,
            platformActions: RecordingSchedulePlatformActions(), newCustomScheduleDraft: { .init() }
        )
        await model.loadIfNeeded()
        let destinations = ScheduleDestinations(
            appStoreURL: AppURL.required("https://example.invalid"),
            academicCourse: { _, _ in AnyView(EmptyView()) }, openCourseLocation: { _ in false },
            resolveCourseShare: { _ in nil })
        let layout = AppWindowLayout(size: CGSize(width: 390, height: 844), interfaceIdiom: .phone)
        let previousMode = UserDefaults.standard.object(forKey: "schedule.calendar.axisMode")
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: "schedule.calendar.axisMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "schedule.calendar.axisMode")
            }
        }
        let schedule = CourseScheduleTabView(
            viewModel: model, resetSignal: 0, destinations: destinations)
        schedule.storedCalendarAxisMode =
            (linear ? ScheduleCalendarAxisMode.linear : .quantized).rawValue
        let host = UIHostingController(
            rootView: NavigationStack { schedule.frame(width: 390, height: 600) }
                .environment(\.appWindowLayout, layout).environment(\.dynamicTypeSize, textSize))
        let tabs = UITabBarController()
        tabs.viewControllers = [host, UIViewController()]
        tabs.selectedIndex = 1
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func collection(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView, list.numberOfSections > 1 { return list }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        for _ in 0..<2 {
            tabs.selectedIndex = 0
            let sampler = ScheduleRenderedFrameSampler {
                guard let list = collection(in: host.view), list.numberOfItems(inSection: 1) > 0,
                    let cell = list.cellForItem(at: IndexPath(item: 0, section: 1)),
                    let layer = cell.layer.presentation(), layer.bounds.height > 0
                else { return nil }
                return layer.bounds.size.height
            }
            let heights = await sampler.sample()
            print("Calendar entry rendered heights: \(heights)")
            #expect(heights.count >= 2, "逐帧验收需要真实渲染的课表行。")
            if let minimum = heights.min(), let maximum = heights.max() {
                #expect(maximum - minimum <= 1, "课表进入期间的渲染高度：\(heights)")
            }
            tabs.selectedIndex = 1
            await Task.yield()
        }
    }

    @Test("Calendar headers scale their text while preserving compact control geometry")
    func calendarHeadersFollowTextMetrics() {
        for lineHeight: CGFloat in [14, 18, 24, 40, 60] {
            let metrics = ScheduleCalendarHeaderMetrics(captionLineHeight: lineHeight)
            #expect(metrics.weekItemHeight == lineHeight + 21)
            #expect(metrics.weekSliderHeight == max(44, lineHeight + 29))
            #expect(metrics.dateHeaderHeight == max(26, lineHeight + 8))
            #expect(metrics.compactHeaderHeight == max(44, metrics.dateHeaderHeight))
        }
    }

    @Test("Initial position centers the current time")
    func initialPositionCentersCurrentTime() {
        let viewport = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: CGFloat(24) / CGFloat(13),
            currentMinute: 14 * 60 + 30
        )

        let visibleCenterMinute =
            (viewport.offsetY + viewport.viewportHeight / 2)
            / viewport.contentHeight * CGFloat(24 * 60)
        #expect(abs(visibleCenterMinute - CGFloat(14 * 60 + 30)) < 0.001)
    }

    @Test("Initial position clamps at both day boundaries")
    func initialPositionClampsAtDayBoundaries() {
        let morning = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: 2,
            currentMinute: 60
        )
        let evening = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: 2,
            currentMinute: 23 * 60
        )

        #expect(morning.offsetY == 0)
        #expect(evening.offsetY == evening.contentHeight - evening.viewportHeight)
    }

    @Test("Zoom keeps a stationary finger center on the same minute")
    func zoomPreservesStationaryAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: 1.5,
            offsetY: 260
        )
        let anchorY: CGFloat = 310
        let anchoredRatio = (initial.offsetY + anchorY) / initial.contentHeight
        let zoomed = initial.zoomed(
            to: 2.4,
            initialAnchorY: anchorY,
            currentAnchorY: anchorY
        )

        let zoomedRatio = (zoomed.offsetY + anchorY) / zoomed.contentHeight
        #expect(abs(zoomedRatio - anchoredRatio) < 0.001)
    }

    @Test("Zoom follows a moving finger center")
    func zoomTracksMovingAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: 1.5,
            offsetY: 240
        )
        let anchoredRatio = (initial.offsetY + 280) / initial.contentHeight
        let zoomed = initial.zoomed(
            to: 2.2,
            initialAnchorY: 280,
            currentAnchorY: 430
        )

        let zoomedRatio = (zoomed.offsetY + 430) / zoomed.contentHeight
        #expect(abs(zoomedRatio - anchoredRatio) < 0.001)
    }

    @Test("Zoom scale and offsets stay inside supported bounds")
    func zoomClampsScaleAndOffsets() {
        let top = ScheduleTimelineViewport(viewportHeight: 780, scale: 1, offsetY: 0)
            .zoomed(to: 0.1, initialAnchorY: 0, currentAnchorY: 600)
        let bottom = ScheduleTimelineViewport(viewportHeight: 780, scale: 3, offsetY: 1_560)
            .zoomed(to: 8, initialAnchorY: 780, currentAnchorY: 0)

        #expect(top.scale == ScheduleTimelineViewport.minimumScale)
        #expect(top.offsetY == 0)
        #expect(bottom.scale == ScheduleTimelineViewport.maximumScale)
        #expect(bottom.offsetY == bottom.contentHeight - bottom.viewportHeight)
    }

    @Test("Continuous zoom updates keep the original minute under the fingers")
    func continuousZoomPreservesAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: CGFloat(24) / CGFloat(13),
            offsetY: 430
        )
        let initialAnchorY: CGFloat = 360
        let anchoredRatio = (initial.offsetY + initialAnchorY) / initial.contentHeight
        let updates: [(scale: CGFloat, anchorY: CGFloat)] = [
            (2.0, 350),
            (2.25, 330),
            (2.6, 315),
            (2.15, 340),
            (1.9, 365),
        ]

        for update in updates {
            let viewport = initial.zoomed(
                to: update.scale,
                initialAnchorY: initialAnchorY,
                currentAnchorY: update.anchorY
            )
            let currentRatio = (viewport.offsetY + update.anchorY) / viewport.contentHeight
            #expect(abs(currentRatio - anchoredRatio) < 0.001)
            #expect(viewport.offsetY > 0)
        }
    }
}

@MainActor
private final class ScheduleRenderedFrameSampler: NSObject {
    private let height: () -> CGFloat?
    private var samples: [CGFloat] = []
    private var remaining = 12
    private var continuation: CheckedContinuation<[CGFloat], Never>?
    init(height: @escaping () -> CGFloat?) { self.height = height }
    func sample() async -> [CGFloat] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        if let value = height() { samples.append(value) }
        remaining -= 1
        if remaining == 0 {
            link.invalidate()
            continuation?.resume(returning: samples)
            continuation = nil
        }
    }
}

@MainActor
@Suite("Schedule card location priority")
struct ScheduleCardTextLayoutTests {
    @Test func building() throws {
        let location = "文萃楼A\n101"
        for font in [
            UIFont.preferredFont(forTextStyle: .caption1),
            UIFont.preferredFont(forTextStyle: .title1),
        ] {
            for height: CGFloat in [18, 40, 120] {
                let view = ScheduleCardTextView.AdaptiveCardTextView(
                    frame: CGRect(x: 0, y: 0, width: 72, height: height))
                view.configure(
                    title: String(repeating: "计算机网络与通信原理", count: 5), location: location,
                    contentMode: .nameAndLocation, font: font, textColor: .label)
                view.layoutIfNeeded()
                let labels = view.subviews.compactMap { $0 as? UILabel }
                let title = try #require(labels.first)
                let room = try #require(labels.last)
                #expect(!room.isHidden && room.text == location && room.numberOfLines >= 2)
                let fullRoom = UILabel()
                fullRoom.text = location
                fullRoom.font = room.font
                fullRoom.numberOfLines = 0
                let requiredHeight = fullRoom.sizeThatFits(
                    CGSize(width: room.bounds.width, height: .greatestFiniteMagnitude)
                ).height
                #expect(
                    room.bounds.height >= requiredHeight - 0.5 && view.bounds.contains(room.frame))
                #expect(room.font.pointSize <= font.pointSize)
                if title.isHidden {
                    #expect(title.frame == .zero)
                } else {
                    #expect(
                        title.font.pointSize == font.pointSize && view.bounds.contains(title.frame))
                    #expect(title.frame.maxY <= room.frame.minY)
                }
                #expect(view.accessibilityValue == "地点：\(location)")
            }
        }
    }

    @Test func changingCourseNamePreservesRoomSpace() throws {
        let view = ScheduleCardTextView.AdaptiveCardTextView(
            frame: CGRect(x: 0, y: 0, width: 72, height: 100))
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let location = "文萃楼A\n101"
        let labels = view.subviews.compactMap { $0 as? UILabel }
        let title = try #require(labels.first)
        let room = try #require(labels.last)
        func configure(_ name: String, _ mode: ScheduleCardContentMode) {
            view.configure(
                title: name, location: location, contentMode: mode, font: font, textColor: .label)
            view.layoutIfNeeded()
        }
        configure("高数", .nameAndLocation)
        let roomFrame = room.frame
        configure(String(repeating: "长课程名称", count: 20), .nameAndLocation)
        #expect(room.frame == roomFrame && !title.isHidden && room.numberOfLines >= 2)
        configure("高数", .name)
        #expect(room.isHidden && !title.isHidden)
        configure("高数", .location)
        #expect(title.isHidden && !room.isHidden && room.numberOfLines >= 2)
    }
}
