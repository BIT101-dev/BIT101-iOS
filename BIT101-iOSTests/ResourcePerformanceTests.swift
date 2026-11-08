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
@testable import ScheduleFeature

private typealias ShellSwitchTiming = (
    response: Double, selection: Double, display: Double, firstFrame: Double, gap: Double)

@MainActor
private final class PerformanceDisplayFrame: NSObject {
    private let keepsRunning: Bool
    private var displayLink: CADisplayLink?
    private var continuation: CheckedContinuation<Double, Never>?
    private var isReady: () -> Bool = { true }
    private var started: Double = 0
    private var previousFrame: Double = 0
    private(set) var firstFrame: Double?
    private(set) var maximumGap: Double = 0

    init(keepsRunning: Bool = false) { self.keepsRunning = keepsRunning }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func next(
        startedAt: Double? = nil, when isReady: @escaping () -> Bool = { true }
    ) async -> Double {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isReady = isReady
            started = startedAt ?? ProcessInfo.processInfo.systemUptime
            previousFrame = started
            firstFrame = nil
            maximumGap = 0
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        guard continuation != nil else { return }
        let displayed = ProcessInfo.processInfo.systemUptime
        if firstFrame == nil { firstFrame = displayed }
        maximumGap = max(maximumGap, displayed - previousFrame)
        previousFrame = displayed
        guard isReady() || displayed - started >= 1 else { return }
        if !keepsRunning { stop() }
        continuation?.resume(returning: displayed)
        continuation = nil
    }
}

extension MaintenancePerformanceTests {
    @MainActor
    func testNativeCommunityFirstContentPerformance() throws {
        try measureCommunityFirstContent(expanded: true)
    }

    @MainActor
    func testCompactCommunityFirstLoadPerformance() throws {
        try measureCommunityFirstContent(expanded: false)
    }

    @MainActor
    private func measureCommunityFirstContent(expanded: Bool) throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            do { try self.runCommunityFirstContent(expanded: expanded) } catch {
                XCTFail("原生话廊首次内容测量失败：\(error)")
            }
        }
    }

    @MainActor
    private func runCommunityFirstContent(expanded: Bool) throws {
        let workloadID = expanded
            ? "native-community-first-content" : "compact-community-first-content"
        let workload = try PerformanceWorkload(workloadID, bundle: Bundle(for: Self.self))
        let items = try workload.value("items", as: Int.self)
        let maximumDelay = try workload.value("maximumResponseSeconds", as: Double.self)
        let factory = ExperimentalPreferenceCloudSyncTests()
        let domain = "BIT101Tests.community-first-content"
        let (sync, defaults, _, account) = try factory.context(domain: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        sync.settings.markStartupNoticeSeen()
        sync.settings.markThanksNoticeShown(for: account.session)
        let transport = RecoveryScanResponse(large: false, firstPageItems: items)
        let lifecycle = factory.lifecycle(
            sync: sync, account: account, displays: .init(), communityTransport: transport)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var content: [String: (Double, Int)] = [:]
        let controller = UIHostingController(
            rootView: shellPerformanceView(lifecycle, expanded: expanded)
                .environment(\.appPageLoadObserver, { page, stage, duration, count in
                    if stage == "content-ready" { content[page] = (duration, count) }
                }))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let completed = expectation(description: "原生话廊首次完整内容")
        var rows = ["page,entryToDisplaySeconds,constructionToContentSeconds,items"]
        Task { @MainActor in
            defer { completed.fulfill() }
            do {
                rows += try await self.measureCommunityPages(
                    in: controller, expanded: expanded, items: items,
                    maximumDelay: maximumDelay, content: { content })
                XCTAssertGreaterThan(transport.calls, 2)
            } catch { XCTFail("原生话廊首次内容失败：\(error)") }
        }
        wait(for: [completed], timeout: 30)
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = workloadID
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(rows.count, 3)
    }

    @MainActor
    private func measureCommunityPages(
        in controller: UIViewController, expanded: Bool, items: Int, maximumDelay: Double,
        content: () -> [String: (Double, Int)]
    ) async throws -> [String] {
        try await waitForTestEvent {
            self.shellTabs(in: controller).map {
                self.shellTabCount($0) == (expanded ? 8 : 5)
            } == true
        }
        let tabs = try XCTUnwrap(shellTabs(in: controller))
        let frame = PerformanceDisplayFrame(keepsRunning: true)
        defer { frame.stop() }
        _ = await frame.next()
        var rows: [String] = []
        for prefix in ["gallery.native.", "paper.native."] {
            let started = ProcessInfo.processInfo.systemUptime
            if prefix == "gallery.native." {
                try await selectShellTab(expanded ? 3 : 2, in: tabs, frame: frame)
            } else if expanded {
                try await selectShellTab(4, in: tabs, frame: frame)
            } else {
                let picker = try XCTUnwrap(communityPicker(in: controller.view))
                picker.selectedSegmentIndex = 1
                picker.sendActions(for: .valueChanged)
            }
            try await waitForTestEvent {
                content().contains { $0.key.hasPrefix(prefix) && $0.value.1 == items }
            }
            _ = await frame.next()
            let displayed = await frame.next()
            let entry = displayed - started
            let result = try XCTUnwrap(content().first { $0.key.hasPrefix(prefix) })
            rows.append("\(result.key),\(entry),\(result.value.0),\(result.value.1)")
            XCTAssertLessThan(entry, maximumDelay, "\(result.key): \(entry)s")
        }
        return rows
    }

    @MainActor
    private func communityPicker(in view: UIView) -> UISegmentedControl? {
        if let picker = view as? UISegmentedControl,
            picker.numberOfSegments == 2,
            picker.titleForSegment(at: 0) == "话题", picker.titleForSegment(at: 1) == "文章"
        { return picker }
        return view.subviews.lazy.compactMap { self.communityPicker(in: $0) }.first
    }

    @MainActor
    func testAppShellTabSwitchingPerformance() throws {
        try measureAppShellSwitching(workloadID: "app-shell-tab-switching", expanded: true)
    }

    @MainActor
    func testCompactAppShellTabSwitchingPerformance() throws {
        try measureAppShellSwitching(workloadID: "compact-app-shell-tab-switching", expanded: false)
    }

    @MainActor
    private func measureAppShellSwitching(
        workloadID: String, expanded: Bool
    ) throws {
        let workload = try PerformanceWorkload(workloadID, bundle: Bundle(for: Self.self))
        let passes = try workload.value("passes", as: Int.self)
        let maximumDelay = try workload.value("maximumResponseSeconds", as: Double.self)
        let maximumFirstDelay = try workload.value("maximumFirstResponseSeconds", as: Double.self)
        let tabCount = expanded ? 8 : 5
        let factory = ExperimentalPreferenceCloudSyncTests()
        let (sync, defaults, _, account) = try factory.context(
            domain: "BIT101Tests.shell-performance")
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.shell-performance") }
        sync.settings.markStartupNoticeSeen()
        sync.settings.markThanksNoticeShown(for: account.session)
        let lifecycle = factory.lifecycle(
            sync: sync, account: account, displays: .init(),
            scheduleCache: try shellPerformanceCache(
                courses: workload.value("courses", as: Int.self)))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: shellPerformanceView(lifecycle, expanded: expanded))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        if scene.activationState != .foregroundActive {
            UIApplication.shared.activateSceneSession(
                for: UISceneSessionActivationRequest(session: scene.session)
            ) { error in XCTFail("测试窗口激活失败：\(error)") }
        }
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let ready = expectation(description: "完整壳层就绪")
        var tabs: UITabBarController?
        var firstVisits: [String] = []
        let displayFrame = PerformanceDisplayFrame(keepsRunning: true)
        defer { displayFrame.stop() }
        Task { @MainActor in
            defer { ready.fulfill() }
            do {
                await lifecycle.scheduleViewModel.loadIfNeeded()
                try await waitForTestEvent {
                    scene.activationState == .foregroundActive
                        && self.shellTabs(in: controller).map {
                            self.shellTabCount($0) == tabCount
                        } == true
                }
                let mountedTabs = try XCTUnwrap(self.shellTabs(in: controller))
                XCTAssertEqual(self.shellTabCount(mountedTabs), tabCount)
                let initialPage = try XCTUnwrap(mountedTabs.selectedViewController)
                let initialStart = ProcessInfo.processInfo.systemUptime
                _ = await displayFrame.next {
                    self.shellViewIsDisplayed(initialPage.viewIfLoaded)
                }
                XCTAssertTrue(self.shellViewIsDisplayed(initialPage.viewIfLoaded))
                let initialDisplay = await displayFrame.next()
                let initialDuration = initialDisplay - initialStart
                firstVisits.append("initial,0,\(initialDuration),0,\(initialDuration)")
                for index in Array(1..<tabCount) + [0] {
                    let timing = try await self.selectShellTab(
                        index, in: mountedTabs, frame: displayFrame)
                    firstVisits.append(
                        "first-visit,\(index),\(timing.response),"
                            + "\(timing.selection),\(timing.display)")
                    XCTAssertLessThan(
                        timing.response, maximumFirstDelay,
                        "首次显示 Tab \(index): selection=\(timing.selection)s, "
                            + "display=\(timing.display)s, response=\(timing.response)s")
                }
                tabs = mountedTabs
            } catch { XCTFail("完整壳层就绪失败：\(error)") }
        }
        wait(for: [ready], timeout: 30)
        let mountedTabs = try XCTUnwrap(tabs)
        XCTAssertEqual(scene.activationState, .foregroundActive)
        var timings: [Int: [ShellSwitchTiming]] = [:]
        var frameOverheads: [Double] = []
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            let completed = expectation(description: "完整壳层切换")
            Task { @MainActor in
                defer { completed.fulfill() }
                do {
                    let controlStart = ProcessInfo.processInfo.systemUptime
                    let controlFrame = await displayFrame.next()
                    frameOverheads.append(controlFrame - controlStart)
                    let samples = try await self.sampleShellTabs(
                        passes: passes, tabs: mountedTabs, frame: displayFrame)
                    timings.merge(samples) { $0 + $1 }
                } catch { XCTFail("完整壳层切换失败：\(error)") }
            }
            wait(for: [completed], timeout: 30)
        }
        XCTAssertEqual(scene.activationState, .foregroundActive)
        let rows = (0..<tabCount).flatMap { index in
            (timings[index] ?? []).map {
                "measured,\(index),\($0.response),\($0.selection),\($0.display)"
            }
        }
        let attachment = XCTAttachment(
            string: (["phase,tab,responseSeconds,selectionSeconds,displaySeconds"]
                + firstVisits + rows).joined(separator: "\n"))
        attachment.name = workloadID
        attachment.lifetime = .keepAlways
        add(attachment)
        for index in 0..<tabCount {
            let samples = timings[index] ?? []
            XCTAssertFalse(samples.isEmpty)
            let maximum = try XCTUnwrap(samples.max { $0.response < $1.response })
            let details = [
                "selection=\(maximum.selection)s", "display=\(maximum.display)s",
                "firstFrame=\(maximum.firstFrame)s", "gap=\(maximum.gap)s",
                "emptyFrame=\(frameOverheads.max() ?? 0)s",
                "scene=\(scene.activationState.rawValue)", "responses=\(samples.map(\.response))",
            ].joined(separator: ", ")
            XCTAssertLessThan(
                maximum.response, maximumDelay, "Tab \(index): \(details)")
        }
    }

    @MainActor
    private func sampleShellTabs(
        passes: Int, tabs: UITabBarController, frame: PerformanceDisplayFrame
    ) async throws -> [Int: [ShellSwitchTiming]] {
        var samples: [Int: [ShellSwitchTiming]] = [:]
        for _ in 0..<passes {
            for index in 0..<shellTabCount(tabs) {
                samples[index, default: []].append(
                    try await selectShellTab(index, in: tabs, frame: frame))
            }
        }
        return samples
    }

    @MainActor
    private func shellPerformanceView(
        _ lifecycle: AppAccountLifecycle, expanded: Bool
    ) -> some View {
        let size = expanded ? CGSize(width: 1024, height: 768) : CGSize(width: 390, height: 844)
        return AppShellView(
            transcriptService: lifecycle.transcriptService, studentID: "performance", onLogout: {})
            .environment(lifecycle.communityDestinations)
            .environment(lifecycle.community)
            .environment(lifecycle.communityDestinations.media)
            .environment(lifecycle.scheduleViewModel)
            .environment(lifecycle)
            .environment(lifecycle.scheduleViewModel.ddl)
            .environment(lifecycle.scoreViewModel)
            .environment(lifecycle.settings)
            .environment(lifecycle.preferenceCloudSync)
            .environment(lifecycle.prompts)
            .environment(
                \.appWindowLayout,
                AppWindowLayout(
                    size: size, isRegularWidth: expanded,
                    interfaceIdiom: expanded ? .pad : .phone))
            .frame(width: size.width, height: size.height)
    }

    @MainActor
    private func shellTabs(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.shellTabs(in: $0) }.first
    }

    @MainActor
    private func shellTabCount(_ tabs: UITabBarController) -> Int {
        if #available(iOS 18.0, *), !tabs.tabs.isEmpty { return tabs.tabs.count }
        return tabs.viewControllers?.count ?? 0
    }

    @MainActor
    @discardableResult
    private func selectShellTab(
        _ index: Int, in tabs: UITabBarController, frame: PerformanceDisplayFrame? = nil
    ) async throws -> ShellSwitchTiming {
        let start = ProcessInfo.processInfo.systemUptime
        let destination: UIViewController
        if #available(iOS 18.0, *), !tabs.tabs.isEmpty {
            let previous = tabs.selectedTab
            let tab = tabs.tabs[index]
            tabs.selectedTab = tab
            tabs.delegate?.tabBarController?(tabs, didSelectTab: tab, previousTab: previous)
            destination = try XCTUnwrap(tab.viewController)
        } else {
            destination = try XCTUnwrap(tabs.viewControllers?[index])
            tabs.selectedViewController = destination
            tabs.delegate?.tabBarController?(tabs, didSelect: destination)
        }
        let selected = ProcessInfo.processInfo.systemUptime
        let frame = frame ?? PerformanceDisplayFrame()
        let displayed = await frame.next(startedAt: start) {
            self.shellViewIsDisplayed(destination.viewIfLoaded)
        }
        XCTAssertTrue(shellViewIsDisplayed(destination.viewIfLoaded))
        return (
            displayed - start, selected - start, displayed - selected,
            try XCTUnwrap(frame.firstFrame) - start, frame.maximumGap)
    }

    @MainActor
    private func shellViewIsDisplayed(_ view: UIView?) -> Bool {
        guard let view, let window = view.window,
            let presentation = view.layer.presentation(), !presentation.isHidden,
            presentation.opacity > 0,
            view.convert(view.bounds, to: window).intersects(window.bounds)
        else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha == 0
                || current.layer.presentation()?.opacity == 0 {
                return false
            }
            ancestor = current.superview
        }
        return true
    }

    private func shellPerformanceCache(courses count: Int) throws -> ScheduleCache {
        let term = "2026-2027-1"
        let courses = try (0..<count).map { index in
            let position = index / 4
            let section = TimeSlot.default[(position / 7) % TimeSlot.default.count].id
            return try XCTUnwrap(
                ScheduleCourseEditor.adding(
                    CourseDraft(
                        title: "课程\(index)", classroom: "良乡校区文萃楼A-201",
                        weekday: position % 7 + 1, startSection: section, endSection: section,
                        weeksText: "1-20"),
                    to: [], term: term, id: "course-\(index)").first)
        }
        var cache = ScheduleCache()
        cache.currentTerm = term
        cache.courseData.store(
            .init(
                term: term, firstDayString: "2026-09-07", courses: courses, exams: [],
                updatedAt: .now))
        return cache
    }

    @MainActor
    func testArticleTabSwitchingPerformance() throws {
        let workload = try PerformanceWorkload(
            "article-tab-switching", bundle: Bundle(for: Self.self))
        let pairs = try workload.value("switchPairs", as: Int.self)
        let maximumDelay = try workload.value("maximumResponseSeconds", as: Double.self)
        let factory = FeatureCompositionTests()
        let source = factory.paper(FeatureCompositionTests.TraceTransport())
        let service = FeatureCompositionTests.PaperPreviewService()
        let dependencies = PaperDependencies(
            list: service, detail: source.detail, composer: source.composer,
            drafts: source.drafts, networkPath: source.networkPath,
            currentIdentity: source.currentIdentity)
        let route = FeatureCompositionTests.TabRoute()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: FeatureCompositionTests.PaperTabs(
                route: route, dependencies: dependencies, media: factory.media()))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            service.pending?.resume(
                returning: .init(authorName: "author", avatarURL: nil, isAnonymous: false))
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let ready = expectation(description: "预热文章 Tab")
        Task { @MainActor in
            defer { ready.fulfill() }
            do {
                try await waitForTestEvent { service.pending != nil }
                let pending = service.pending
                service.pending = nil
                pending?.resume(
                    returning: .init(authorName: "author", avatarURL: nil, isAnonymous: false))
                for selection in [1, 0] {
                    route.selection = selection
                    try await waitForTestEvent { route.visibleSelection == selection }
                }
            } catch { XCTFail("文章预热失败：\(error)") }
        }
        wait(for: [ready], timeout: 30)
        let subscriptions = service.resourcePublisherRequests
        let pageRequests = service.pages.count
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            let completed = expectation(description: "文章 Tab 切换")
            Task { @MainActor in
                defer { completed.fulfill() }
                do {
                    try await self.switchArticleTabs(
                        route: route, pairs: pairs, maximumDelay: maximumDelay)
                } catch { XCTFail("文章 Tab 切换失败：\(error)") }
            }
            wait(for: [completed], timeout: 30)
        }
        XCTAssertEqual(service.resourcePublisherRequests, subscriptions)
        XCTAssertEqual(service.pages.count, pageRequests)
    }

    @MainActor
    private func switchArticleTabs(
        route: FeatureCompositionTests.TabRoute, pairs: Int, maximumDelay: Double
    ) async throws {
        for _ in 0..<pairs {
            for selection in [1, 0] {
                let start = ProcessInfo.processInfo.systemUptime
                route.selection = selection
                try await waitForTestEvent { route.visibleSelection == selection }
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, maximumDelay)
            }
        }
    }

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
