import SwiftUI
import UIKit

/// 线性时间轴视图。
struct LinearScheduleCalendarView: View {
    let entries: [ScheduleCalendarEntry]
    let week: Int
    let availableWeeks: [Int]
    let displayMode: ScheduleDisplayMode
    let cardContentMode: ScheduleCardContentMode
    let firstDay: Date
    let timeTable: [TimeSlot]
    let currentWeek: Int
    let showSaturday: Bool
    let showSunday: Bool
    let showHighlightToday: Bool
    let showDivider: Bool
    let showCurrentTime: Bool
    let showBorder: Bool
    @Binding var zoomScale: CGFloat
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onSelectDay: (Date, Int) -> Void
    let onSelectWeekValue: (Int) -> Void
    let onLongPressCourse: (ScheduleCalendarEntry) -> Void
    let onPrepareCourseShare: (ScheduleCalendarEntry) -> Void
    let onShareSchedule: () -> Void
    let onImportSchedule: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let weekSliderHeight = AppDesignSystem.Schedule.weekSlider.sliderHeight
            let dateHeaderHeight = AppDesignSystem.Schedule.weekSlider.dateHeaderHeight
            let headerHeight = displayMode == .weekly
                ? weekSliderHeight + dateHeaderHeight
                : AppDesignSystem.Schedule.weekSlider.compactHeaderHeight

            VStack(spacing: AppDesignSystem.Spacing.none) {
                LinearScheduleHeader(
                    week: week,
                    availableWeeks: availableWeeks,
                    displayMode: displayMode,
                    firstDay: firstDay,
                    showSaturday: showSaturday,
                    showSunday: showSunday,
                    onSelectDay: onSelectDay,
                    onSelectWeekValue: onSelectWeekValue
                )

                LinearTimelineScrollContainer(
                    configuration: LinearScheduleCalendarConfiguration(
                        entries: entries,
                        timeTable: timeTable,
                        displayMode: displayMode,
                        cardContentMode: cardContentMode,
                        currentWeek: currentWeek,
                        week: week,
                        showSaturday: showSaturday,
                        showSunday: showSunday,
                        showHighlightToday: showHighlightToday,
                        showDivider: showDivider,
                        showCurrentTime: showCurrentTime,
                        showBorder: showBorder,
                        onSelect: onSelect,
                        onLongPressCourse: onLongPressCourse,
                        onPrepareCourseShare: onPrepareCourseShare,
                        onShareSchedule: onShareSchedule,
                        onImportSchedule: onImportSchedule
                    ),
                    zoomScale: $zoomScale
                )
                .frame(height: max(proxy.size.height - headerHeight, 1))
            }
            .background(AppDesignSystem.Palette.systemBackground)
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped))
        }
    }
}

private struct LinearScheduleHeader: View {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M.d"
        return formatter
    }()

    let week: Int
    let availableWeeks: [Int]
    let displayMode: ScheduleDisplayMode
    let firstDay: Date
    let showSaturday: Bool
    let showSunday: Bool
    let onSelectDay: (Date, Int) -> Void
    let onSelectWeekValue: (Int) -> Void

    var body: some View {
        let visibleWeekdays = visibleWeekdayValues
        let weekDates = visibleWeekdays.compactMap {
            ScheduleDateCodec.calendar.date(
                byAdding: .day,
                value: ($0 - 1) + ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7,
                to: firstDay
            )
        }
        VStack(spacing: AppDesignSystem.Spacing.none) {
            if displayMode == .weekly {
                ScheduleInlineWeekSlider(
                    weeks: availableWeeks,
                    currentWeek: week,
                    highlightedWeek: resolvedCurrentWeek(firstDay: firstDay),
                    onSelectWeek: onSelectWeekValue
                )
                .frame(maxWidth: .infinity)
                .frame(height: AppDesignSystem.Schedule.weekSlider.sliderHeight)
                .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                GeometryReader { proxy in
                    let dayWidth = max(proxy.size.width / CGFloat(visibleWeekdays.count + 1), 1)
                    HStack(spacing: AppDesignSystem.Spacing.none) {
                        Text("第\(week)周")
                            .font(AppDesignSystem.Typography.caption2Emphasis)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: dayWidth, height: AppDesignSystem.Schedule.weekSlider.dateHeaderHeight)
                            .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                        ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
                            Button {
                                onSelectDay(date, visibleWeekdays[index])
                            } label: {
                                Text(Self.monthDayFormatter.string(from: date))
                                    .font(AppDesignSystem.Typography.caption2)
                                    .foregroundStyle(.primary)
                                    .frame(width: dayWidth, height: AppDesignSystem.Schedule.weekSlider.dateHeaderHeight)
                                    .background(AppDesignSystem.Palette.secondaryGroupedBackground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: AppDesignSystem.Schedule.weekSlider.dateHeaderHeight)
            } else {
                GeometryReader { proxy in
                    let dayWidth = max(proxy.size.width / CGFloat(visibleWeekdays.count + 1), 1)
                    HStack(spacing: AppDesignSystem.Spacing.none) {
                        Color.clear
                            .frame(width: dayWidth, height: AppDesignSystem.Schedule.weekSlider.compactHeaderHeight)
                            .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                        ForEach(visibleWeekdays, id: \.self) { weekday in
                            Text(weekdayTitle(weekday))
                                .font(AppDesignSystem.Typography.caption2)
                                .foregroundStyle(.primary)
                                .frame(width: dayWidth, height: AppDesignSystem.Schedule.weekSlider.compactHeaderHeight)
                                .background(AppDesignSystem.Palette.secondaryGroupedBackground)
                        }
                    }
                }
                .frame(height: AppDesignSystem.Schedule.weekSlider.compactHeaderHeight)
            }
        }
    }

    private var visibleWeekdayValues: [Int] {
        (1 ... 7).filter {
            if $0 == 6 { return showSaturday }
            if $0 == 7 { return showSunday }
            return true
        }
    }

    private func weekdayTitle(_ weekday: Int) -> String {
        let titles = ["一", "二", "三", "四", "五", "六", "日"]
        guard titles.indices.contains(weekday - 1) else { return "?" }
        return "周\(titles[weekday - 1])"
    }
}

private struct LinearScheduleCalendarConfiguration {
    let entries: [ScheduleCalendarEntry]
    let timeTable: [TimeSlot]
    let displayMode: ScheduleDisplayMode
    let cardContentMode: ScheduleCardContentMode
    let currentWeek: Int
    let week: Int
    let showSaturday: Bool
    let showSunday: Bool
    let showHighlightToday: Bool
    let showDivider: Bool
    let showCurrentTime: Bool
    let showBorder: Bool
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onLongPressCourse: (ScheduleCalendarEntry) -> Void
    let onPrepareCourseShare: (ScheduleCalendarEntry) -> Void
    let onShareSchedule: () -> Void
    let onImportSchedule: () -> Void
}

private struct LinearTimelineScrollContainer: UIViewRepresentable {
    let configuration: LinearScheduleCalendarConfiguration
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, zoomScale: $zoomScale)
    }

    func makeUIView(context: Context) -> LinearTimelineScrollView {
        let scrollView = LinearTimelineScrollView()
        context.coordinator.install(in: scrollView)
        scrollView.setScale(zoomScale, preserveVisibleCenter: false)
        return scrollView
    }

    func updateUIView(_ uiView: LinearTimelineScrollView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.updateContent()
        if !uiView.isZooming, abs(uiView.timelineScale - zoomScale) > 0.001 {
            uiView.setScale(zoomScale, preserveVisibleCenter: true)
        }
    }

    @MainActor
    final class Coordinator {
        var configuration: LinearScheduleCalendarConfiguration
        var zoomScale: Binding<CGFloat>
        var hostingController: UIHostingController<LinearScheduleCanvasView>?

        init(configuration: LinearScheduleCalendarConfiguration, zoomScale: Binding<CGFloat>) {
            self.configuration = configuration
            self.zoomScale = zoomScale
        }

        func install(in scrollView: LinearTimelineScrollView) {
            let controller = UIHostingController(
                rootView: LinearScheduleCanvasView(configuration: configuration)
            )
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            hostingController = controller
            scrollView.installCanvas(controller.view)
            scrollView.onScaleChange = { [weak self] scale in
                self?.zoomScale.wrappedValue = scale
            }
        }

        func updateContent() {
            hostingController?.rootView = LinearScheduleCanvasView(configuration: configuration)
        }
    }
}

private final class LinearTimelineScrollView: UIScrollView, UIScrollViewDelegate {
    var onScaleChange: ((CGFloat) -> Void)?
    var timelineScale: CGFloat { zoomScale }

    private let zoomContainer = UIView()
    private weak var canvasView: UIView?
    private var viewportSize = CGSize.zero
    private var hasInitialPosition = false
    private var pendingScale = AppDesignSystem.Schedule.timelineDefaultScale

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = ScheduleTimelineViewport.minimumScale
        maximumZoomScale = ScheduleTimelineViewport.maximumScale
        bouncesZoom = false
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
        isDirectionalLockEnabled = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        zoomContainer.backgroundColor = .clear
        zoomContainer.clipsToBounds = false
        addSubview(zoomContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installCanvas(_ view: UIView) {
        canvasView?.removeFromSuperview()
        canvasView = view
        view.layer.anchorPoint = .zero
        view.layer.position = .zero
        zoomContainer.addSubview(view)
        updateCanvasGeometry()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewportSize != bounds.size {
            let previousHeight = viewportSize.height
            let centerRatio = previousHeight > 0
                ? (contentOffset.y + previousHeight / 2) / max(previousHeight * zoomScale, 1)
                : 0
            viewportSize = bounds.size
            zoomContainer.bounds = CGRect(origin: .zero, size: viewportSize)
            zoomContainer.center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            updateCanvasGeometry()

            if previousHeight > 0 {
                let nextOffset = centerRatio * viewportSize.height * zoomScale - viewportSize.height / 2
                setVerticalOffset(nextOffset)
            }
        }

        if !hasInitialPosition {
            hasInitialPosition = true
            setZoomScale(ScheduleTimelineViewport.clampedScale(pendingScale), animated: false)
            updateCanvasGeometry()
            let initial = ScheduleTimelineViewport.initial(
                viewportHeight: viewportSize.height,
                scale: zoomScale,
                currentMinute: currentMinute()
            )
            setContentOffset(CGPoint(x: 0, y: initial.offsetY), animated: false)
        }
    }

    func setScale(_ value: CGFloat, preserveVisibleCenter: Bool) {
        let resolvedScale = ScheduleTimelineViewport.clampedScale(value)
        pendingScale = resolvedScale
        guard bounds.height > 0 else {
            setNeedsLayout()
            return
        }
        let currentViewport = ScheduleTimelineViewport(
            viewportHeight: bounds.height,
            scale: zoomScale,
            offsetY: contentOffset.y
        )
        let nextViewport = currentViewport.zoomed(
            to: resolvedScale,
            initialAnchorY: bounds.height / 2,
            currentAnchorY: bounds.height / 2
        )
        setZoomScale(resolvedScale, animated: false)
        updateCanvasGeometry()
        if preserveVisibleCenter {
            setVerticalOffset(nextViewport.offsetY)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomContainer
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateCanvasGeometry()
        clampHorizontalOffset()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        clampHorizontalOffset()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        pendingScale = scale
        onScaleChange?(scale)
    }

    private func updateCanvasGeometry() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let scale = max(zoomScale, 0.001)
        let canvasSize = CGSize(
            width: viewportSize.width,
            height: viewportSize.height * scale
        )
        canvasView?.bounds = CGRect(origin: .zero, size: canvasSize)
        canvasView?.layer.position = .zero
        canvasView?.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        canvasView?.setNeedsLayout()
    }

    private func setVerticalOffset(_ value: CGFloat) {
        let maximumOffset = max(bounds.height * zoomScale - bounds.height, 0)
        contentOffset = CGPoint(x: 0, y: min(max(value, 0), maximumOffset))
    }

    private func clampHorizontalOffset() {
        if abs(contentOffset.x) > 0.5 {
            contentOffset.x = 0
        }
    }

    private func currentMinute() -> Int {
        let components = ScheduleDateCodec.calendar.dateComponents([.hour, .minute], from: Date())
        return min(
            max((components.hour ?? 12) * 60 + (components.minute ?? 0), 0),
            24 * 60
        )
    }
}

private struct LinearScheduleCanvasView: View {
    let configuration: LinearScheduleCalendarConfiguration

    var body: some View {
        GeometryReader { proxy in
            let visibleWeekdays = visibleWeekdayValues
            let columnWidth = max(proxy.size.width / CGFloat(visibleWeekdays.count + 1), 1)
            let contentHeight = proxy.size.height
            let timelineStart = 0
            let timelineEnd = 24 * 60

            ZStack(alignment: .topLeading) {
                timelineGrid(
                    visibleWeekdays: visibleWeekdays,
                    leftWidth: columnWidth,
                    dayWidth: columnWidth,
                    contentHeight: contentHeight,
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd
                )

                ScheduleBlankContextMenuView(
                    onBegan: {},
                    onShare: configuration.onShareSchedule,
                    onImport: configuration.onImportSchedule
                )
                .frame(width: proxy.size.width, height: contentHeight)

                ForEach(configuration.entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    entryView(
                        entry,
                        leftWidth: columnWidth,
                        dayWidth: columnWidth,
                        contentHeight: contentHeight,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd
                    )
                }
            }
            .frame(width: proxy.size.width, height: contentHeight)
        }
    }

    private var visibleWeekdayValues: [Int] {
        (1 ... 7).filter {
            if $0 == 6 { return configuration.showSaturday }
            if $0 == 7 { return configuration.showSunday }
            return true
        }
    }

    private func timelineGrid(
        visibleWeekdays: [Int],
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        contentHeight: CGFloat,
        timelineStart: Int,
        timelineEnd: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if configuration.showHighlightToday,
               configuration.currentWeek == configuration.week,
               let index = visibleWeekdays.firstIndex(of: ScheduleDateCodec.weekdayIndex(from: Date())) {
                Rectangle()
                    .fill(AppDesignSystem.Schedule.GridPalette.todayHighlight)
                    .frame(width: dayWidth, height: contentHeight)
                    .offset(x: leftWidth + dayWidth * CGFloat(index))
            }

            ForEach(Array(stride(from: timelineStart + 60, through: timelineEnd - 60, by: 60)), id: \.self) { minute in
                let y = yPosition(
                    for: minute,
                    contentHeight: contentHeight,
                    start: timelineStart,
                    end: timelineEnd
                )
                Rectangle()
                    .fill(configuration.showDivider
                        ? AppDesignSystem.Schedule.GridPalette.linearMajorLine
                        : AppDesignSystem.Schedule.GridPalette.linearMinorLine)
                    .frame(width: leftWidth + dayWidth * CGFloat(visibleWeekdays.count), height: 0.5)
                    .offset(y: y)

                Text(TimeSlot.formatMinutes(minute))
                    .font(AppDesignSystem.Typography.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: leftWidth, alignment: .center)
                    .offset(y: y - 8)
            }

            ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                Rectangle()
                    .fill(AppDesignSystem.Schedule.GridPalette.columnLine)
                    .frame(width: AppDesignSystem.Schedule.grid.lineWidth, height: contentHeight)
                    .offset(x: leftWidth + dayWidth * CGFloat(column))
            }

            if configuration.showCurrentTime,
               configuration.currentWeek == configuration.week,
               let index = visibleWeekdays.firstIndex(of: ScheduleDateCodec.weekdayIndex(from: Date())) {
                Rectangle()
                    .fill(AppDesignSystem.Palette.accent)
                    .frame(width: dayWidth, height: AppDesignSystem.Schedule.grid.currentTimeLineHeight)
                    .offset(
                        x: leftWidth + dayWidth * CGFloat(index),
                        y: yPosition(
                            for: currentMinute,
                            contentHeight: contentHeight,
                            start: timelineStart,
                            end: timelineEnd
                        )
                    )
                    .zIndex(2)
            }
        }
    }

    private func entryView(
        _ entry: ScheduleCalendarEntry,
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        contentHeight: CGFloat,
        timelineStart: Int,
        timelineEnd: Int
    ) -> some View {
        let start = entry.startMinutes ?? fallbackMinute(for: entry.startSection, start: timelineStart, end: timelineEnd)
        let end = max(
            entry.endMinutes ?? fallbackMinute(for: entry.endSection, start: timelineStart, end: timelineEnd),
            start + 1
        )
        let startY = yPosition(
            for: start,
            contentHeight: contentHeight,
            start: timelineStart,
            end: timelineEnd
        )
        let endY = yPosition(
            for: min(end, timelineEnd),
            contentHeight: contentHeight,
            start: timelineStart,
            end: timelineEnd
        )
        let cardWidth = max(dayWidth - AppDesignSystem.Schedule.grid.courseCardTotalInset, 1)
        let cardHeight = max(endY - startY - AppDesignSystem.Schedule.grid.courseCardTotalInset, 18)

        return ZStack(alignment: .topLeading) {
            CourseScheduleBackgroundView(entry: entry, showBorder: configuration.showBorder)
                .frame(width: cardWidth, height: cardHeight)

            CourseScheduleBlockView(entry: entry, contentMode: configuration.cardContentMode)
                .contentShape(Rectangle())
                .onTapGesture { configuration.onSelect(entry) }
                .contextMenu {
                    if entry.kind == .course {
                        Button("分享课程", systemImage: "square.and.arrow.up") {
                            configuration.onLongPressCourse(entry)
                        }
                    }
                } preview: {
                    if entry.kind == .course {
                        Color.clear
                            .frame(
                                width: AppDesignSystem.Schedule.grid.previewTriggerSize,
                                height: AppDesignSystem.Schedule.grid.previewTriggerSize
                            )
                            .onAppear { configuration.onPrepareCourseShare(entry) }
                    }
                }
                .accessibilityAddTraits(.isButton)
                .frame(width: cardWidth, height: cardHeight)
        }
        .frame(width: cardWidth, height: cardHeight)
        .offset(
            x: leftWidth + dayWidth * CGFloat(visibleWeekdayValues.firstIndex(of: entry.dayOfWeek) ?? 0) + 0.5,
            y: startY + 0.5
        )
        .zIndex(entry.kind == .custom ? 1.5 : 1)
    }

    private func fallbackMinute(for section: CGFloat, start: Int, end: Int) -> Int {
        start + Int((section / CGFloat(max(configuration.timeTable.count, 1))) * CGFloat(end - start))
    }

    private func yPosition(
        for minute: Int,
        contentHeight: CGFloat,
        start: Int,
        end: Int
    ) -> CGFloat {
        let ratio = CGFloat(min(max(minute, start), end) - start) / CGFloat(max(end - start, 1))
        return contentHeight * ratio
    }

    private var currentMinute: Int {
        let components = ScheduleDateCodec.calendar.dateComponents([.hour, .minute], from: Date())
        return min(max((components.hour ?? 12) * 60 + (components.minute ?? 0), 0), 24 * 60)
    }
}
