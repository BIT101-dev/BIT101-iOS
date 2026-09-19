//
//  ScheduleCalendarViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI
import UIKit

/// 空白课表区域的原生上下文菜单，按真实长按坐标定位菜单。
struct ScheduleBlankContextMenuView: UIViewRepresentable {
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

final class ScheduleBlankContextMenuControl: UIControl {
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
                            .fill(row == 0
                                ? AppDesignSystem.Schedule.GridPalette.majorLine
                                : AppDesignSystem.Schedule.GridPalette.minorLine)
                            .frame(height: gridLineWidth)
                            .offset(y: headerHeight + rowHeight * CGFloat(row) - AppDesignSystem.Schedule.grid.lineOffset)
                            .zIndex(-1)
                    }
                }

                ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                    Rectangle()
                        .fill(column == 0
                            ? AppDesignSystem.Schedule.GridPalette.majorLine
                            : AppDesignSystem.Schedule.GridPalette.minorLine)
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
