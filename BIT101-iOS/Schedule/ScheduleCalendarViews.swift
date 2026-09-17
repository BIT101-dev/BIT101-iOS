//
//  ScheduleCalendarViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI
import UIKit

/// 空白课表区域的原生上下文菜单，按真实长按坐标定位菜单。
private struct ScheduleBlankContextMenuView: UIViewRepresentable {
    let onBegan: () -> Void
    let onShare: () -> Void
    let onImport: () -> Void

    func makeUIView(context: Context) -> ScheduleBlankContextMenuControl {
        let view = ScheduleBlankContextMenuControl()
        view.onBegan = onBegan
        view.onShare = onShare
        view.onImport = onImport
        return view
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.onBegan = onBegan
        uiView.onShare = onShare
        uiView.onImport = onImport
    }
}

private final class ScheduleBlankContextMenuControl: UIControl {
    var onBegan: (() -> Void)?
    var onShare: (() -> Void)?
    var onImport: (() -> Void)?
    private var lastInteractionLocation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isContextMenuInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        lastInteractionLocation = location
        onBegan?()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: "分享课表",
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    self?.onShare?()
                },
                UIAction(
                    title: "导入课表",
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    self?.onImport?()
                }
            ])
        }
    }

    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        lastInteractionLocation
    }
}

struct CourseScheduleCalendarView: View {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M.d"
        return formatter
    }()
    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "七"]
    @State private var contextMenuFeedbackToken = 0

    let entries: [ScheduleCalendarEntry]
    let week: Int
    let availableWeeks: [Int]
    let displayMode: ScheduleDisplayMode
    let cardContentMode: ScheduleCardContentMode
    let axisMode: ScheduleCalendarAxisMode
    @Binding var axisZoomScale: CGFloat
    let firstDay: Date
    let timeTable: [TimeSlot]
    let currentWeek: Int
    let showSaturday: Bool
    let showSunday: Bool
    let showHighlightToday: Bool
    let showDivider: Bool
    let showCurrentTime: Bool
    let showBorder: Bool
    let onSelect: (ScheduleCalendarEntry) -> Void
    let onSelectDay: (Date, Int) -> Void
    let onSelectWeekValue: (Int) -> Void
    let onLongPressCourse: (ScheduleCalendarEntry) -> Void
    let onPrepareCourseShare: (ScheduleCalendarEntry) -> Void
    let onShareSchedule: () -> Void
    let onImportSchedule: () -> Void

    @ViewBuilder
    var body: some View {
        if axisMode == .linear {
            LinearScheduleCalendarView(
                entries: entries,
                week: week,
                availableWeeks: availableWeeks,
                displayMode: displayMode,
                cardContentMode: cardContentMode,
                firstDay: firstDay,
                timeTable: timeTable,
                currentWeek: currentWeek,
                showSaturday: showSaturday,
                showSunday: showSunday,
                showHighlightToday: showHighlightToday,
                showDivider: showDivider,
                showCurrentTime: showCurrentTime,
                showBorder: showBorder,
                zoomScale: $axisZoomScale,
                onSelect: onSelect,
                onSelectDay: onSelectDay,
                onSelectWeekValue: onSelectWeekValue,
                onLongPressCourse: onLongPressCourse,
                onPrepareCourseShare: onPrepareCourseShare,
                onShareSchedule: onShareSchedule,
                onImportSchedule: onImportSchedule
            )
        } else {
            quantizedBody
        }
    }

    private var quantizedBody: some View {
        GeometryReader { proxy in
            let gridLineWidth = AppDesignSystem.Schedule.grid.lineWidth
            let weekSliderHeight = AppDesignSystem.Schedule.weekSlider.sliderHeight
            let dateHeaderHeight = AppDesignSystem.Schedule.weekSlider.dateHeaderHeight
            let headerHeight = displayMode == .weekly
                ? weekSliderHeight + dateHeaderHeight
                : AppDesignSystem.Schedule.weekSlider.compactHeaderHeight
            let usableHeight = max(proxy.size.height - headerHeight, 1)
            let rowHeight = usableHeight / CGFloat(max(timeTable.count, 1))
            let visibleWeekdays = (1 ... 7).filter {
                if $0 == 6 { return showSaturday }
                if $0 == 7 { return showSunday }
                return true
            }
            let columnWidth = max(proxy.size.width / CGFloat(visibleWeekdays.count + 1), 1)
            let leftWidth = columnWidth
            let dayWidth = columnWidth
            let cardWidth = max(dayWidth - AppDesignSystem.Schedule.grid.courseCardTotalInset, 1)
            let weekDates = visibleWeekdays.compactMap {
                ScheduleDateCodec.calendar.date(
                    byAdding: .day,
                    value: ($0 - 1) + ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7,
                    to: firstDay
                )
            }
            let highlightWeekday = (currentWeek == week && showHighlightToday) ? ScheduleDateCodec.weekdayIndex(from: Date()) : nil
            let timeLineSection = (currentWeek == week && showCurrentTime) ? convertTimeToSection(timeText: currentTimeText(), timeTable: timeTable) : nil

            ZStack(alignment: .topLeading) {
                if let highlightWeekday, visibleWeekdays.contains(highlightWeekday), let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(AppDesignSystem.Palette.accent.opacity(0.10))
                        .frame(width: dayWidth, height: usableHeight)
                        .offset(x: leftWidth + dayWidth * CGFloat(index), y: headerHeight)
                }

                VStack(spacing: 0) {
                    if displayMode == .weekly {
                        ScheduleInlineWeekSlider(
                            weeks: availableWeeks,
                            currentWeek: week,
                            highlightedWeek: currentWeek,
                            onSelectWeek: onSelectWeekValue
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: weekSliderHeight)
                        .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            Text("第\(week)周")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: leftWidth, height: dateHeaderHeight)
                            .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
                                Button {
                                    onSelectDay(date, visibleWeekdays[index])
                                } label: {
                                    Text(mmddText(for: date))
                                        .font(.caption2)
                                        .foregroundStyle(.primary)
                                        .frame(width: dayWidth, height: dateHeaderHeight)
                                        .background(AppDesignSystem.Palette.secondaryGroupedBackground)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            Color.clear
                                .frame(width: leftWidth, height: headerHeight)
                                .background(AppDesignSystem.Palette.secondaryGroupedBackground)

                            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, _ in
                                Text(weekdayText(for: visibleWeekdays[index]))
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .frame(width: dayWidth, height: headerHeight)
                                    .background(AppDesignSystem.Palette.secondaryGroupedBackground)
                            }
                        }
                    }

                    ForEach(Array(timeTable.enumerated()), id: \.offset) { index, slot in
                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            VStack(spacing: AppDesignSystem.Schedule.grid.cellSpacing) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .lineLimit(1)
                                Text(slot.start)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(width: leftWidth, height: rowHeight)

                            ForEach(visibleWeekdays, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: dayWidth, height: rowHeight)
                            }
                        }
                    }
                }

                if showDivider {
                    ForEach(0 ... timeTable.count, id: \.self) { row in
                        Rectangle()
                            .fill(Color.secondary.opacity(row == 0 ? 0.18 : 0.12))
                            .frame(height: gridLineWidth)
                            .offset(y: headerHeight + rowHeight * CGFloat(row) - AppDesignSystem.Schedule.grid.lineOffset)
                            .zIndex(-1)
                    }
                }

                ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                    Rectangle()
                        .fill(Color.secondary.opacity(column == 0 ? 0.18 : 0.12))
                        .frame(
                            width: gridLineWidth,
                            height: proxy.size.height - (displayMode == .weekly ? weekSliderHeight : 0)
                        )
                        .offset(
                            x: leftWidth + dayWidth * CGFloat(column) - gridLineWidth / 2,
                            y: displayMode == .weekly ? weekSliderHeight : 0
                        )
                        .zIndex(-1)
                }

                if let timeLineSection,
                   timeLineSection > 0,
                   timeLineSection < CGFloat(timeTable.count),
                   let highlightWeekday,
                   visibleWeekdays.contains(highlightWeekday),
                   let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(AppDesignSystem.Palette.accent)
                        .frame(width: dayWidth, height: AppDesignSystem.Schedule.grid.currentTimeLineHeight)
                        .offset(
                            x: leftWidth + dayWidth * CGFloat(index),
                            y: headerHeight + rowHeight * timeLineSection
                    )
                    .zIndex(2)
                }

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: headerHeight)
                        .allowsHitTesting(false)
                    ScheduleBlankContextMenuView(
                        onBegan: { contextMenuFeedbackToken &+= 1 },
                        onShare: onShareSchedule,
                        onImport: onImportSchedule
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                ForEach(entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    ZStack(alignment: .topLeading) {
                        ForEach(entry.orderedBackgroundLayers) { layer in
                            // 课程背景使用不透明系统色，网格线保持在卡片后方。
                            CourseScheduleBackgroundView(
                                entry: entry,
                                showBorder: showBorder
                            )
                            .frame(
                                width: cardWidth,
                                height: max(
                                    rowHeight * (layer.endSection - layer.startSection)
                                        - AppDesignSystem.Schedule.grid.courseCardTotalInset,
                                    1
                                )
                            )
                            .offset(
                                y: rowHeight * (layer.startSection - entry.startSection)
                                    + gridLineWidth
                            )
                            .zIndex(layer.displayZIndex)
                        }

                        CourseScheduleBlockView(entry: entry, contentMode: cardContentMode)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(entry) }
                            .contextMenu {
                                if entry.kind == .course {
                                    Button("分享课程", systemImage: "square.and.arrow.up") {
                                        onLongPressCourse(entry)
                                    }
                                }
                            } preview: {
                                if entry.kind == .course {
                                    Color.clear
                                        .frame(
                                            width: AppDesignSystem.Schedule.grid.previewTriggerSize,
                                            height: AppDesignSystem.Schedule.grid.previewTriggerSize
                                        )
                                        .onAppear { onPrepareCourseShare(entry) }
                                }
                            }
                        .accessibilityAddTraits(.isButton)
                        .frame(
                            width: cardWidth,
                            height: max(
                                rowHeight * (entry.endSection - entry.startSection)
                                    - AppDesignSystem.Schedule.grid.courseCardTotalInset,
                                1
                            )
                        )
                    }
                    .frame(
                        width: cardWidth,
                        height: max(
                            rowHeight * (entry.endSection - entry.startSection)
                                - AppDesignSystem.Schedule.grid.courseCardTotalInset,
                            1
                        )
                    )
                    .offset(
                        x: leftWidth + dayWidth * CGFloat(visibleWeekdays.firstIndex(of: entry.dayOfWeek) ?? 0)
                            + gridLineWidth,
                        y: headerHeight + rowHeight * entry.startSection
                            + gridLineWidth
                    )
                    .zIndex(1)
                }

            }
            .clipped()
            .background(AppDesignSystem.Palette.systemBackground)
            // 课表主体沿用 List 分组内容的圆角；其它卡片使用各自样式。
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped))
            .appSelectionFeedback(trigger: week)
            .appImpactFeedback(trigger: contextMenuFeedbackToken)
        }
    }

    private func mmddText(for date: Date) -> String {
        Self.monthDayFormatter.string(from: date)
    }

    private func weekdayText(for weekday: Int) -> String {
        guard (1 ... Self.weekdayTitles.count).contains(weekday) else {
            return "?"
        }
        return Self.weekdayTitles[weekday - 1]
    }

    private func currentTimeText() -> String {
        let components = ScheduleDateCodec.calendar.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

/// 线性时间轴视图。
private struct LinearScheduleCalendarView: View {
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
                            .font(.caption2.weight(.semibold))
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
                                    .font(.caption2)
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
                                .font(.caption2)
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
    private var pendingScale = ScheduleCalendarAxisMode.defaultLinearZoomScale

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
        let centerRatio = (contentOffset.y + bounds.height / 2)
            / max(bounds.height * zoomScale, 1)
        setZoomScale(resolvedScale, animated: false)
        updateCanvasGeometry()
        if preserveVisibleCenter {
            let nextOffset = centerRatio * bounds.height * resolvedScale - bounds.height / 2
            setVerticalOffset(nextOffset)
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
                    .fill(AppDesignSystem.Palette.accent.opacity(0.10))
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
                    .fill(Color.secondary.opacity(configuration.showDivider ? 0.14 : 0.08))
                    .frame(width: leftWidth + dayWidth * CGFloat(visibleWeekdays.count), height: 0.5)
                    .offset(y: y)

                Text(TimeSlot.formatMinutes(minute))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: leftWidth, alignment: .center)
                    .offset(y: y - 8)
            }

            ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                Rectangle()
                    .fill(Color.secondary.opacity(0.14))
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

/// 课表中的单个课程 / 考试 / 自定义日程块。
private struct CourseScheduleBlockView: View {
    let entry: ScheduleCalendarEntry
    let contentMode: ScheduleCardContentMode

    var body: some View {
        ScheduleCardTextView(
            title: entry.title,
            location: entry.subtitle,
            contentMode: contentMode,
            textStyle: AppDesignSystem.Schedule.courseText.style,
            textColor: uiTextColor
        )
        .padding(AppDesignSystem.Spacing.micro)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var uiTextColor: UIColor {
        switch entry.kind {
        case .course:
            return .label
        case .exam:
            return UIColor(AppDesignSystem.Palette.highlight)
        case .custom:
            return UIColor(AppDesignSystem.Palette.info)
        }
    }

}

/// 课表卡片为名称和地点分配独立文字区域。
private struct ScheduleCardTextView: UIViewRepresentable {
    let title: String
    let location: String
    let contentMode: ScheduleCardContentMode
    let textStyle: UIFont.TextStyle
    let textColor: UIColor

    func makeUIView(context: Context) -> AdaptiveCardTextView {
        AdaptiveCardTextView()
    }

    func updateUIView(_ uiView: AdaptiveCardTextView, context: Context) {
        uiView.configure(
            title: title,
            location: location,
            contentMode: contentMode,
            font: UIFont.preferredFont(forTextStyle: textStyle),
            textColor: textColor
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AdaptiveCardTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class AdaptiveCardTextView: UIView {
        private let titleLabel = UILabel()
        private let locationLabel = UILabel()
        private var title = ""
        private var location = ""
        private var scheduleContentMode = ScheduleCardContentMode.nameAndLocation
        private var baseFont = UIFont.preferredFont(forTextStyle: .caption2)

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            [titleLabel, locationLabel].forEach { label in
                label.textAlignment = .center
                label.adjustsFontForContentSizeCategory = true
                label.adjustsFontSizeToFitWidth = false
                label.allowsDefaultTighteningForTruncation = true
                label.clipsToBounds = true
                addSubview(label)
            }
            titleLabel.lineBreakMode = .byTruncatingTail
            locationLabel.lineBreakMode = .byCharWrapping
            locationLabel.numberOfLines = 0
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            title: String,
            location: String,
            contentMode: ScheduleCardContentMode,
            font: UIFont,
            textColor: UIColor
        ) {
            self.title = title
            self.location = location
            scheduleContentMode = contentMode
            baseFont = font
            titleLabel.textColor = textColor
            locationLabel.textColor = textColor
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0 else { return }

            switch scheduleContentMode {
            case .name:
                layoutTitle(text: title, in: bounds)
                hideLocation()
            case .location:
                hideTitle()
                layoutLocation(text: location.isEmpty ? title : location, in: bounds)
            case .nameAndLocation:
                layoutCombined()
            }
        }

        private func layoutCombined() {
            guard !location.isEmpty else {
                layoutTitle(text: title, in: bounds)
                hideLocation()
                return
            }
            guard !title.isEmpty else {
                hideTitle()
                layoutLocation(text: location, in: bounds)
                return
            }

            let gap = AppDesignSystem.Schedule.grid.cellSpacing
            let preferredLocationHeight = measuredHeight(
                text: location,
                font: baseFont,
                width: bounds.width
            )
            let preferredTitleLineHeight = baseFont.lineHeight
            let roomForTitle = bounds.height - preferredLocationHeight - gap
            let locationMaximumHeight = roomForTitle >= preferredTitleLineHeight
                ? preferredLocationHeight
                : bounds.height
            let locationFont = fittingFont(
                text: location,
                width: bounds.width,
                maximumHeight: locationMaximumHeight
            )
            let locationHeight = min(
                measuredHeight(text: location, font: locationFont, width: bounds.width),
                bounds.height
            )
            let titleAvailableHeight = max(bounds.height - locationHeight - gap, 0)
            let titleHeight = layoutTitle(
                text: title,
                in: CGRect(x: 0, y: 0, width: bounds.width, height: titleAvailableHeight)
            )
            let actualGap = titleHeight > 0 ? gap : 0
            let contentHeight = titleHeight + actualGap + locationHeight
            let originY = max((bounds.height - contentHeight) / 2, 0)
            titleLabel.frame.origin.y = originY
            configureLocationLabel(text: location, font: locationFont)
            locationLabel.frame = CGRect(
                x: 0,
                y: originY + titleHeight + actualGap,
                width: bounds.width,
                height: locationHeight
            )
        }

        @discardableResult
        private func layoutTitle(text: String, in rect: CGRect) -> CGFloat {
            guard !text.isEmpty, rect.height >= baseFont.lineHeight else {
                hideTitle()
                return 0
            }
            titleLabel.isHidden = false
            titleLabel.text = text
            titleLabel.font = baseFont
            titleLabel.preferredMaxLayoutWidth = rect.width
            titleLabel.numberOfLines = max(Int(floor(rect.height / baseFont.lineHeight)), 1)
            let measured = titleLabel.sizeThatFits(rect.size)
            let height = min(ceil(measured.height), rect.height)
            titleLabel.frame = CGRect(
                x: rect.minX,
                y: rect.minY + max((rect.height - height) / 2, 0),
                width: rect.width,
                height: height
            )
            return height
        }

        private func layoutLocation(text: String, in rect: CGRect) {
            guard !text.isEmpty else {
                hideLocation()
                return
            }
            let font = fittingFont(text: text, width: rect.width, maximumHeight: rect.height)
            configureLocationLabel(text: text, font: font)
            let height = min(measuredHeight(text: text, font: font, width: rect.width), rect.height)
            locationLabel.frame = CGRect(
                x: rect.minX,
                y: rect.minY + max((rect.height - height) / 2, 0),
                width: rect.width,
                height: height
            )
        }

        private func configureLocationLabel(text: String, font: UIFont) {
            locationLabel.isHidden = false
            locationLabel.text = text
            locationLabel.font = font
            locationLabel.preferredMaxLayoutWidth = bounds.width
        }

        private func fittingFont(text: String, width: CGFloat, maximumHeight: CGFloat) -> UIFont {
            guard maximumHeight > 0 else { return baseFont }
            if measuredHeight(text: text, font: baseFont, width: width) <= maximumHeight {
                return baseFont
            }

            var lowerBound: CGFloat = 1
            var upperBound = baseFont.pointSize
            for _ in 0 ..< 10 {
                let candidateSize = (lowerBound + upperBound) / 2
                let candidate = baseFont.withSize(candidateSize)
                if measuredHeight(text: text, font: candidate, width: width) <= maximumHeight {
                    lowerBound = candidateSize
                } else {
                    upperBound = candidateSize
                }
            }
            return baseFont.withSize(lowerBound)
        }

        private func measuredHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(rect.height)
        }

        private func hideTitle() {
            titleLabel.isHidden = true
            titleLabel.frame = .zero
        }

        private func hideLocation() {
            locationLabel.isHidden = true
            locationLabel.frame = .zero
        }
    }
}

private struct CourseScheduleBackgroundView: View {
    let entry: ScheduleCalendarEntry
    let showBorder: Bool

    var body: some View {
        AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge)
            .fill(backgroundColor)
            .opacity(entry.kind == .course || entry.backgroundLayers.count <= 1 ? 1 : 0.5)
            .overlay {
                if showBorder, entry.kind != .course {
                    AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge)
                        .strokeBorder(borderColor, lineWidth: AppDesignSystem.Schedule.grid.courseBorderWidth)
                }
            }
    }

    private var backgroundColor: Color {
        switch entry.kind {
        case .course:
            return AppDesignSystem.Palette.secondaryBackground
        case .exam:
            return AppDesignSystem.Palette.highlight.opacity(0.22)
        case .custom:
            return AppDesignSystem.Palette.info.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch entry.kind {
        case .course:
            return Color.secondary.opacity(0.25)
        case .exam:
            return AppDesignSystem.Palette.highlight.opacity(0.35)
        case .custom:
            return AppDesignSystem.Palette.info.opacity(0.30)
        }
    }
}

/// 右下角悬浮按钮。
struct CourseScheduleFAB: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        AppFloatingActionButton(
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel,
            action: action
        )
    }
}

/// 课表页悬浮圆形按钮的统一外观。
///
/// `Button` 和 `Menu` 共用同一套视觉样式，保持“添加”按钮的尺寸和命中区域一致。
struct CourseScheduleFABLabel: View {
    let systemImage: String?
    let text: String?

    init(systemImage: String) {
        self.systemImage = systemImage
        text = nil
    }

    init(text: String) {
        systemImage = nil
        self.text = text
    }

    var body: some View {
        AppFloatingActionButtonSurface {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(AppDesignSystem.Typography.floatingIcon)
                    .foregroundStyle(.primary)
            } else if let text {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// 课表顶部的周次滑动条，直接切换当前周。
private struct ScheduleInlineWeekSlider: View {
    let weeks: [Int]
    let currentWeek: Int
    let highlightedWeek: Int
    let onSelectWeek: (Int) -> Void
    @State private var selectedWeek: Int?

    init(
        weeks: [Int],
        currentWeek: Int,
        highlightedWeek: Int,
        onSelectWeek: @escaping (Int) -> Void
    ) {
        self.weeks = weeks
        self.currentWeek = currentWeek
        self.highlightedWeek = highlightedWeek
        self.onSelectWeek = onSelectWeek
        // 等待滚动内容完成首轮布局，再设置选中项，使选中项对齐完整刻度。
        _selectedWeek = State(initialValue: nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let itemWidth = AppDesignSystem.Schedule.weekSlider.itemWidth
            let barHeight = AppDesignSystem.Schedule.weekSlider.barHeight
            let horizontalPadding = max((proxy.size.width - itemWidth) / 2, 0).rounded()

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: AppDesignSystem.Schedule.weekSlider.itemSpacing) {
                        ForEach(weeks, id: \.self) { week in
                            VStack(spacing: AppDesignSystem.Schedule.grid.cellSpacing) {
                                Text(isMajorWeek(week) ? "\(week)" : "")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(week == highlightedWeek ? AppDesignSystem.Palette.accent : .secondary)
                                    .frame(height: AppDesignSystem.Schedule.weekSlider.labelHeight)
                                Capsule()
                                    .fill(week == highlightedWeek ? AppDesignSystem.Palette.accent : Color.secondary.opacity(0.55))
                                    .frame(
                                        width: week == highlightedWeek
                                            ? AppDesignSystem.Schedule.weekSlider.selectedBarWidth
                                            : AppDesignSystem.Schedule.weekSlider.barWidth,
                                        height: isMajorWeek(week)
                                            ? barHeight
                                            : AppDesignSystem.Schedule.weekSlider.minorBarHeight
                                    )
                            }
                            .frame(
                                width: itemWidth,
                                height: AppDesignSystem.Schedule.weekSlider.itemHeight,
                                alignment: .top
                            )
                            .contentShape(Rectangle())
                            .id(week)
                            .onTapGesture {
                                withAnimation(.snappy) {
                                    selectedWeek = week
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .frame(minHeight: AppDesignSystem.Schedule.weekSlider.itemHeight)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selectedWeek, anchor: .center)
                .safeAreaPadding(.horizontal, horizontalPadding)
                .overlay(alignment: .top) {
                    Image(systemName: "triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(180))
                        .allowsHitTesting(false)
                }
                .onAppear {
                    let target = weeks.contains(currentWeek) ? currentWeek : weeks.first
                    guard let target else { return }
                    DispatchQueue.main.async {
                        selectedWeek = target
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .onChange(of: selectedWeek) { _, week in
                    guard let week, week != currentWeek else { return }
                    onSelectWeek(week)
                }
                .onChange(of: currentWeek) { _, week in
                    let target = weeks.contains(week) ? week : weeks.first
                    guard selectedWeek != target else { return }
                    selectedWeek = target
                    alignSelection(using: scrollProxy, to: target)
                }
                .onChange(of: weeks) { _, newWeeks in
                    let target = newWeeks.contains(currentWeek) ? currentWeek : newWeeks.first
                    guard selectedWeek == target else {
                        selectedWeek = target
                        alignSelection(using: scrollProxy, to: target)
                        return
                    }
                    alignSelection(using: scrollProxy, to: target)
                }
            }
        }
    }

    private func isMajorWeek(_ week: Int) -> Bool {
        week == 1 || week % 5 == 0
    }

    /// 首次布局完成后再次定位到完整周次项，使冷启动时的选中项对齐完整刻度。
    private func alignSelection(using proxy: ScrollViewProxy, to target: Int? = nil) {
        guard let target = target ?? selectedWeek else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

/// 课程长按分享使用的系统分享面板。
struct CourseActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    let subject: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [CourseShareItemSource(url: url, subject: subject)],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class CourseShareItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let subject: String

    init(url: URL, subject: String) {
        self.url = url
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject
    }
}

/// 课表网格内部统一使用的条目类型。
///
/// 课程、考试和自定义日程统一投影为日历块，并分别使用对应的颜色和详情逻辑。
enum ScheduleCalendarKind {
    case course
    case exam
    case custom
}

/// 供课表网格渲染的统一条目模型。
///
/// 这是课表 UI 层内部的适配模型，数据生命周期止于展示流程。
struct ScheduleCalendarEntry: Identifiable {
    let id: String
    let sourceID: String
    /// 叠加模式下，一个格子可能对应多门课程；普通模式只有一个元素。
    let sourceIDs: [String]
    let dayOfWeek: Int
    let startSection: CGFloat
    let endSection: CGFloat
    let startMinutes: Int?
    let endMinutes: Int?
    let title: String
    let subtitle: String
    let detailLines: [String]
    let kind: ScheduleCalendarKind
    let backgroundLayers: [ScheduleCalendarLayer]

    init(
        id: String,
        sourceID: String,
        sourceIDs: [String],
        dayOfWeek: Int,
        startSection: CGFloat,
        endSection: CGFloat,
        startMinutes: Int? = nil,
        endMinutes: Int? = nil,
        title: String,
        subtitle: String,
        detailLines: [String],
        kind: ScheduleCalendarKind,
        backgroundLayers: [ScheduleCalendarLayer]? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceIDs = sourceIDs
        self.dayOfWeek = dayOfWeek
        self.startSection = startSection
        self.endSection = endSection
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.title = title
        self.subtitle = subtitle
        self.detailLines = detailLines
        self.kind = kind
        self.backgroundLayers = backgroundLayers ?? [
            ScheduleCalendarLayer(
                id: "background-\(id)",
                startSection: startSection,
                endSection: endSection
            )
        ]
    }

    var resolvedSourceIDs: [String] {
        sourceIDs.isEmpty ? [sourceID] : sourceIDs
    }

    /// 重叠课程按中心位置绘制：中心更靠前的课程最后绘制，位于上层。
    var orderedBackgroundLayers: [ScheduleCalendarLayer] {
        backgroundLayers.sorted { lhs, rhs in
            let lhsCenter = (lhs.startSection + lhs.endSection) / 2
            let rhsCenter = (rhs.startSection + rhs.endSection) / 2
            if lhsCenter == rhsCenter {
                if lhs.startSection == rhs.startSection {
                    return lhs.endSection > rhs.endSection
                }
                return lhs.startSection > rhs.startSection
            }
            return lhsCenter > rhsCenter
        }
    }
}

struct ScheduleCalendarLayer: Identifiable {
    let id: String
    let startSection: CGFloat
    let endSection: CGFloat

    /// SwiftUI 的 zIndex 越大越靠上；中心更靠前的课程因此拥有更高层级。
    var displayZIndex: Double {
        -Double((startSection + endSection) / 2)
    }
}

/// 把具体时间映射到课表网格中的“浮点节次位置”。
///
/// 例如 10:15 可能落在第 3.4 节的位置，用于考试和自定义日程块的连续时间定位。
func convertTimeToSection(timeText: String, timeTable: [TimeSlot]) -> CGFloat {
    let minutes = TimeSlot.parseMinutes(timeText)
    guard !timeTable.isEmpty else { return 0 }

    let sectionIndex = timeTable.firstIndex(where: { minutes <= $0.endMinutes }) ?? (timeTable.count - 1)
    let slot = timeTable[sectionIndex]
    let duration = max(slot.endMinutes - slot.startMinutes, 1)
    let rawRatio = CGFloat(minutes - slot.startMinutes) / CGFloat(duration)
    let ratio = min(max(rawRatio, 0), 1)
    return CGFloat(sectionIndex) + ratio
}

/// 根据首周日期计算课表页当前周次。
func resolvedCurrentWeek(firstDay: Date) -> Int {
    let start = ScheduleDateCodec.calendar.startOfDay(for: firstDay)
    let today = ScheduleDateCodec.calendar.startOfDay(for: Date())
    let diff = ScheduleDateCodec.calendar.dateComponents([.day], from: start, to: today).day ?? 0
    return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
}

/// 处理同一天中互相重叠的日历块，为先前条目保留可见区域。
func normalize(entries: [ScheduleCalendarEntry]) -> [ScheduleCalendarEntry] {
    let sorted = entries.sorted { lhs, rhs in
        if lhs.dayOfWeek == rhs.dayOfWeek {
            return lhs.startSection < rhs.startSection
        }
        return lhs.dayOfWeek < rhs.dayOfWeek
    }

    var result: [ScheduleCalendarEntry] = []

    for day in 1 ... 7 {
        var dayEntries: [ScheduleCalendarEntry] = []
        for entry in sorted where entry.dayOfWeek == day {
            if let last = dayEntries.last, last.endSection > entry.startSection {
                if last.endSection < entry.endSection {
                    dayEntries.append(
                        ScheduleCalendarEntry(
                            id: "\(entry.id)-trim-\(last.endSection)",
                            sourceID: entry.sourceID,
                            sourceIDs: entry.resolvedSourceIDs,
                            dayOfWeek: entry.dayOfWeek,
                            startSection: last.endSection,
                            endSection: entry.endSection,
                            startMinutes: entry.startMinutes,
                            endMinutes: entry.endMinutes,
                            title: entry.title,
                            subtitle: entry.subtitle,
                            detailLines: entry.detailLines,
                            kind: entry.kind
                        )
                    )
                }
            } else {
                dayEntries.append(entry)
            }
        }
        result.append(contentsOf: dayEntries)
    }

    return result
}
