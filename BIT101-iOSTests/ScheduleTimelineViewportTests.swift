import DesignSystemKit
import Foundation
import ScheduleDomain
import ScheduleContracts
import StorageCore
import SwiftUI
import Testing
import TransportCore
import UIKit

@testable import BIT101_iOS
@testable import ScheduleFeature

@Suite("Schedule linear timeline viewport")
struct ScheduleTimelineViewportTests {
    @Test @MainActor func mapTargetTracksStartAndCourseEdits() throws {
        let firstDayString = "2026-09-07"
        let courses = try ScheduleCourseEditor.adding(
            CourseDraft(title: "高数", weekday: 1, weeksText: "1-20"),
            to: [], term: "2026-2027-1", id: "map-course")
        let snapshot = ScheduleCourseSnapshot(
            firstDayString: firstDayString, timeTable: TimeSlot.default, courses: courses)
        let firstDay = try #require(snapshot.firstDay)
        let slot = try #require(TimeSlot.default.first)
        let start = try #require(ScheduleSharedDateCodec.combine(
            firstDay: firstDay, week: 1, weekday: 1, time: slot.start))
        let projection = UpcomingCourseMapProjection()
        let before = try #require(
            projection.resolve(in: snapshot, now: start.addingTimeInterval(-1)))
        #expect(before.startDate == start)
        let after = try #require(projection.resolve(in: snapshot, now: start))
        #expect(after.startDate > start)
        #expect(projection.resolve(in: snapshot, now: start.addingTimeInterval(60)) == after)
        #expect(projection.resolve(in: snapshot, now: start.addingTimeInterval(-1)) == before)
        let cleared = ScheduleCourseSnapshot(
            firstDayString: firstDayString, timeTable: TimeSlot.default, courses: [])
        #expect(projection.resolve(in: cleared, now: start) == nil)
        #expect(projection.resolve(in: snapshot, now: start) != nil)
    }

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
        func calendar(in view: UIView) -> ScheduleCalendarCardsControl? {
            if let calendar = view as? ScheduleCalendarCardsControl { return calendar }
            return view.subviews.lazy.compactMap { calendar(in: $0) }.first
        }
        func viewport(for cards: UIView) -> UIView {
            guard linear else { return cards }
            var ancestor = cards.superview
            while let current = ancestor {
                if current is UIScrollView { return current }
                ancestor = current.superview
            }
            return cards
        }
        for _ in 0..<2 {
            tabs.selectedIndex = 0
            let sampler = ScheduleRenderedFrameSampler {
                guard let cards = calendar(in: host.view), cards.window != nil else { return nil }
                guard let layer = viewport(for: cards).layer.presentation(),
                    layer.bounds.height > 0,
                    layer.opacity > 0 else { return nil }
                return layer.bounds.height
            }
            let heights = await sampler.sample()
            #expect(heights.count >= 2, "逐帧验收需要真实渲染的课表。")
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
    @Test func calendarLayoutTracksCourseAndModeChanges() {
        func entry(_ id: String, title: String, start: CGFloat = 1) -> ScheduleCalendarEntry {
            ScheduleCalendarEntry(
                id: id, sourceID: id, sourceIDs: [id], dayOfWeek: 1,
                startSection: start, endSection: start + 2, title: title, subtitle: "",
                detailLines: [], kind: .course)
        }
        let projection = ScheduleCalendarPlacementProjection()
        let courses = [entry("a", title: "高数"), entry("b", title: "物理")]
        let separated = projection.resolve(entries: courses, separateOverlaps: true)
        #expect(separated.placements.map(\.columnCount) == [2, 2])
        let stacked = projection.resolve(entries: courses, separateOverlaps: false)
        #expect(stacked.placements.map(\.columnCount) == [1, 1])
        let updated = projection.resolve(
            entries: [entry("a", title: "新名称", start: 5)], separateOverlaps: true)
        #expect(updated.placements.count == 1)
        #expect(updated.placements.first?.entry.title == "新名称")
        #expect(updated.placements.first?.entry.startSection == 5)
        #expect(projection.resolve(entries: [], separateOverlaps: true).placements.isEmpty)
    }

    @Test func roomRemainsVisibleAcrossTextSizes() throws {
        let location = "文萃楼A\n101"
        for font in [
            UIFont.preferredFont(forTextStyle: .caption1),
            UIFont.preferredFont(forTextStyle: .title1),
        ] {
            for height: CGFloat in [18, 40, 120] {
                let view = ScheduleCardTextView()
                view.configure(
                    title: String(repeating: "计算机网络与通信原理", count: 5), location: location,
                    contentMode: .nameAndLocation, font: font, textColor: .label)
                view.layout(
                    size: CGSize(width: 72, height: height),
                    scale: UIGraphicsImageRendererFormat().scale)
                let title = view.titleLabel
                let room = view.locationLabel
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
            }
        }
    }

    @Test func courseControlRetainsTextAndOpensDetails() throws {
        let entry = ScheduleCalendarEntry(
            id: "course", sourceID: "course", sourceIDs: ["course"], dayOfWeek: 1,
            startSection: 1, endSection: 3, title: "高等数学", subtitle: "文萃楼A\n101",
            detailLines: [], kind: .course)
        let control = ScheduleBlankContextMenuControl(
            frame: CGRect(x: 0, y: 0, width: 72, height: 100))
        var opens = 0
        control.configure(
            entry: entry, contentMode: .nameAndLocation, onTap: { opens += 1 },
            onMenuWillPresent: nil, onShare: nil, interactionEvidence: nil)
        control.layoutIfNeeded()
        let text = try #require(control.cardText)
        let room = text.locationLabel
        #expect(room.text == entry.subtitle && !room.isHidden)
        #expect(control.cardText?.superview === control)
        #expect(control.accessibilityValue == "地点：\(entry.subtitle)")
        #expect(control.accessibilityActivate() && opens == 1)
        control.configureText(entry: entry, contentMode: .location)
        control.layoutIfNeeded()
        #expect(text.superview === control && control.cardText === text)
        #expect(text.titleLabel.isHidden && !room.isHidden)
        control.isContentVisible = false
        control.isContentVisible = true
        #expect(!control.layer.needsLayout())
        let visibleBounds = text.bounds
        control.isContentVisible = false
        control.bounds.size.width += 8
        control.layoutIfNeeded()
        #expect(text.bounds == visibleBounds)
        control.isContentVisible = true
        #expect(control.layer.needsLayout())
        control.layoutIfNeeded()
        #expect(text.bounds.width == visibleBounds.width + 8)
        control.configureText(entry: entry, contentMode: nil)
        #expect(control.cardText == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cardTextFollowsChangedTraits() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let control = ScheduleBlankContextMenuControl(
            frame: CGRect(x: 0, y: 0, width: 72, height: 100))
        controller.view.addSubview(control)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let entry = ScheduleCalendarEntry(
            id: "course", sourceID: "course", sourceIDs: ["course"], dayOfWeek: 1,
            startSection: 1, endSection: 3, title: "高等数学", subtitle: "文萃楼",
            detailLines: [], kind: .course)
        control.configureText(entry: entry, contentMode: .name)
        let text = try #require(control.cardText)
        control.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let expected = UIFont.preferredFont(
            forTextStyle: .caption1, compatibleWith: control.traitCollection)
        try await waitForTestEvent {
            control.layoutIfNeeded()
            return text.titleLabel.font == expected
        }
        #expect(
            control.traitCollection.preferredContentSizeCategory
                == .accessibilityExtraExtraExtraLarge)
        control.configureText(entry: entry, contentMode: .name)
        #expect(text.titleLabel.font == expected)
    }

    @Test func textKeepsDynamicSystemColor() {
        let text = ScheduleCardTextView()
        text.configure(
            title: "高等数学", location: "文萃楼A\n101", contentMode: .nameAndLocation,
            font: .preferredFont(forTextStyle: .caption1), textColor: .label)
        text.layout(size: CGSize(width: 72, height: 100), scale: 2)
        let light = text.titleLabel.textColor.resolvedColor(
            with: UITraitCollection { $0.userInterfaceStyle = .light })
        let dark = text.titleLabel.textColor.resolvedColor(
            with: UITraitCollection { $0.userInterfaceStyle = .dark })
        #expect(light != dark)
        #expect(text.titleLabel.superview === text && text.locationLabel.superview === text)
        #expect(text.titleLabel.text == "高等数学")
    }

    @Test(arguments: [CGFloat(1), CGFloat(2), CGFloat(3)])
    func cardTextKeepsNativeDisplayScale(scale: CGFloat) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for size in [CGSize(width: 72, height: 100), CGSize(width: 72.5, height: 100.5)] {
                for mode: ScheduleCardContentMode in [.name, .location, .nameAndLocation] {
                    let control = ScheduleBlankContextMenuControl(
                        frame: CGRect(origin: .zero, size: size))
                    controller.view.addSubview(control)
                    control.overrideUserInterfaceStyle = style
                    let entry = ScheduleCalendarEntry(
                        id: "course", sourceID: "course", sourceIDs: ["course"], dayOfWeek: 1,
                        startSection: 1, endSection: 3, title: "计算机网络与通信原理",
                        subtitle: "文萃楼A\n101", detailLines: [], kind: .course)
                    control.configureText(entry: entry, contentMode: mode)
                    control.contentScaleFactor = scale
                    control.layoutIfNeeded()
                    let text = try #require(control.cardText)
                    #expect(text.superview === control)
                    for label in [text.titleLabel, text.locationLabel] {
                        #expect(label.superview === text)
                        #expect(label.contentScaleFactor == window.screen.scale)
                        #expect(label.layer.contentsScale == window.screen.scale)
                    }
                    control.removeFromSuperview()
                }
            }
        }
    }

    @Test func sharedCourseMenuRetainsTarget() throws {
        let view = ScheduleCalendarCardsControl(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        var presented: [String] = []
        let cards = (0..<2).map { index in
            let entry = ScheduleCalendarEntry(
                id: "course-\(index)", sourceID: "\(index)", sourceIDs: ["\(index)"],
                dayOfWeek: 1, startSection: 1, endSection: 3, title: "课程\(index)",
                subtitle: "文萃楼", detailLines: [], kind: .course)
            return ScheduleCalendarCard(
                entry: entry, frame: CGRect(x: index * 100, y: 0, width: 60, height: 80),
                backgrounds: [])
        }
        view.update(cards: cards) { control, card in
            control.configure(
                entry: card.entry, contentMode: .name, onTap: {},
                onMenuWillPresent: { presented.append(card.entry.id) }, onShare: {},
                interactionEvidence: nil)
            #expect(!control.isContextMenuInteractionEnabled)
        }
        let menus = view.interactions.compactMap { $0 as? UIContextMenuInteraction }
        #expect(menus.count == 1)
        let menu = try #require(menus.first)
        for index in 0..<2 {
            let configuration = try #require(
                view.contextMenuInteraction(
                    menu, configurationForMenuAtLocation: CGPoint(x: index * 100 + 10, y: 10)))
            view.contextMenuInteraction(menu, willDisplayMenuFor: configuration, animator: nil)
        }
        #expect(presented == ["course-0", "course-1"])
        #expect(
            view.contextMenuInteraction(
                menu, configurationForMenuAtLocation: CGPoint(x: 190, y: 90)) == nil)
    }

    @Test func calendarCardReuseAndBlankHitTesting() throws {
        func card(_ id: String, title: String, zIndex: Double = 1) -> ScheduleCalendarCard {
            let entry = ScheduleCalendarEntry(
                id: id, sourceID: id, sourceIDs: [id], dayOfWeek: 1,
                startSection: 1, endSection: 3, title: title, subtitle: "文萃楼A\n101",
                detailLines: [], kind: .course)
            return ScheduleCalendarCard(
                entry: entry, frame: CGRect(x: 20, y: 20, width: 72, height: 100),
                backgrounds: [CGRect(x: 0, y: 0, width: 72, height: 100)], zIndex: zIndex)
        }
        let view = ScheduleCalendarCardsControl(
            frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        var opened: [String] = []
        func update(_ cards: [ScheduleCalendarCard]) {
            view.update(cards: cards) { control, card in
                control.configure(
                    entry: card.entry, contentMode: .nameAndLocation,
                    onTap: { opened.append(card.entry.title) },
                    onMenuWillPresent: nil, onShare: nil, interactionEvidence: nil)
                control.configureBackgrounds(card.backgrounds, entry: card.entry)
            }
            view.layoutIfNeeded()
        }
        update([card("above", title: "上层", zIndex: 2), card("course", title: "原课程")])
        let above = try #require(view.subviews.last as? ScheduleBlankContextMenuControl)
        let retained = try #require(view.subviews.first as? ScheduleBlankContextMenuControl)
        #expect(view.hitTest(CGPoint(x: 30, y: 30), with: nil) === above)
        #expect(view.hitTest(CGPoint(x: 180, y: 180), with: nil) == nil)
        #expect(view.gestureRecognizers?.filter { $0 is UITapGestureRecognizer }.count == 1)
        #expect(
            [above, retained].allSatisfy {
                $0.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } != true
            })
        update([card("course", title: "更新课程")])
        #expect(view.subviews.count == 1 && view.subviews.first === retained)
        #expect(retained.accessibilityLabel == "更新课程")
        #expect(retained.accessibilityActivate() && opened == ["更新课程"])
        let background = try #require(retained.layer.sublayers?.first?.sublayers?.first)
        #expect(background.frame == CGRect(x: 0, y: 0, width: 72, height: 100))
        #expect(background.cornerCurve == .continuous)
        update([])
        #expect(view.subviews.isEmpty && view.hitTest(CGPoint(x: 30, y: 30), with: nil) == nil)
    }

    @Test func changingCourseNamePreservesRoomSpace() throws {
        let view = ScheduleCardTextView()
        var size = CGSize(width: 72, height: 100)
        let scale = UIGraphicsImageRendererFormat().scale
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let location = "文萃楼A\n101"
        let title = view.titleLabel
        let room = view.locationLabel
        func configure(_ name: String, _ mode: ScheduleCardContentMode) {
            view.configure(
                title: name, location: location, contentMode: mode, font: font, textColor: .label)
            view.layout(size: size, scale: scale)
        }
        configure("高数", .nameAndLocation)
        let roomFrame = room.frame
        configure(String(repeating: "长课程名称", count: 20), .nameAndLocation)
        #expect(room.frame == roomFrame && !title.isHidden && room.numberOfLines >= 2)
        configure("高数", .name)
        #expect(room.isHidden && !title.isHidden)
        configure("高数", .location)
        #expect(title.isHidden && !room.isHidden && room.numberOfLines >= 2)
        size = CGSize(width: 144, height: 140)
        view.layout(size: size, scale: scale)
        #expect(room.frame.width == 144 && view.bounds.contains(room.frame))
        let largerFont = UIFont.preferredFont(forTextStyle: .title1)
        view.configure(
            title: "高数", location: location, contentMode: .location,
            font: largerFont, textColor: .systemRed)
        view.layout(size: size, scale: scale)
        #expect(room.font == largerFont && room.textColor == .systemRed)
    }
}
