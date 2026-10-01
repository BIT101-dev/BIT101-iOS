#if os(iOS)
import ScheduleDomain
import DesignSystemKit
//
//  ScheduleCalendarViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI
import UIKit

/// 空白课表区域的原生操作菜单，按真实长按坐标定位菜单。
struct ScheduleBlankContextMenuView: UIViewRepresentable {
    let onShare: () -> Void
    let onImport: () -> Void
    let onMenuWillPresent: () -> Void

    func makeUIView(context: Context) -> ScheduleBlankContextMenuControl {
        let view = ScheduleBlankContextMenuControl()
        view.isAccessibilityElement = true
        view.accessibilityLabel = "课表空白区域"
        view.accessibilityHint = "长按查看课表操作"
        view.accessibilityIdentifier = "schedule.blank-context-menu"
        view.accessibilityTraits = .button
        view.shareTitle = "分享课表"
        view.showsImport = true
        view.onMenuWillPresent = onMenuWillPresent
        view.onShare = onShare
        view.onImport = onImport
        return view
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.onMenuWillPresent = onMenuWillPresent
        uiView.onShare = onShare
        uiView.onImport = onImport
    }
}

struct ScheduleEntryInteractionView: UIViewRepresentable {
    let entry: ScheduleCalendarEntry
    let onTap: () -> Void
    var onMenuWillPresent: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil

    func makeUIView(context: Context) -> ScheduleBlankContextMenuControl {
        let view = ScheduleBlankContextMenuControl()
        view.isAccessibilityElement = true
        view.isContextMenuInteractionEnabled = onShare != nil
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityValue = entry.subtitle.isEmpty ? "" : "地点：\(entry.subtitle)"
        view.accessibilityIdentifier = "schedule.entry.\(entry.id)"
        view.accessibilityHint = "双击打开详情"
        view.accessibilityTraits = .button
        view.shareTitle = "分享课程"
        view.showsImport = false
        view.onTap = onTap
        view.onMenuWillPresent = onMenuWillPresent
        view.onShare = onShare
        return view
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.onTap = onTap
        uiView.onMenuWillPresent = onMenuWillPresent
        uiView.onShare = onShare
        uiView.isContextMenuInteractionEnabled = onShare != nil
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityValue = entry.subtitle.isEmpty ? "" : "地点：\(entry.subtitle)"
        uiView.accessibilityIdentifier = "schedule.entry.\(entry.id)"
    }

    private var accessibilityLabel: String {
        let title = entry.title.isEmpty ? "未命名日程" : entry.title
        switch entry.kind {
        case .course: return title
        case .exam: return "考试，\(title)"
        case .custom: return "自定义日程，\(title)"
        }
    }
}

final class ScheduleBlankContextMenuControl: UIControl {
    var shareTitle = "分享课表"
    var showsImport = true
    var onTap: (() -> Void)? {
        didSet { tapGesture.isEnabled = onTap != nil }
    }
    var onMenuWillPresent: (() -> Void)?
    var onShare: (() -> Void)?
    var onImport: (() -> Void)?
    private var lastInteractionLocation: CGPoint = .zero
    private let tapGesture = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isMultipleTouchEnabled = true
        tintColor = UIColor(AppDesignSystem.Palette.Accent.primary)
        isContextMenuInteractionEnabled = true
        tapGesture.addTarget(self, action: #selector(handleTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.isEnabled = false
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onTap else { return super.accessibilityActivate() }
        onTap()
        return true
    }

    private static func coloredMenuImage(_ name: String) -> UIImage? {
        guard let symbol = UIImage(systemName: name) else { return nil }
        let color = UIColor(AppDesignSystem.Palette.Accent.primary)
        return UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(color, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: symbol.size))
        }.withRenderingMode(.alwaysOriginal)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        lastInteractionLocation = location
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            var actions: [UIMenuElement] = [UIAction(
                title: self.shareTitle,
                image: Self.coloredMenuImage("square.and.arrow.up"),
                identifier: UIAction.Identifier(self.showsImport ? "schedule.menu.share" : "schedule.course.menu.share")
            ) { [weak self] _ in
                self?.onShare?()
            }]
            if self.showsImport {
                actions.append(UIAction(
                    title: "导入课表",
                    image: Self.coloredMenuImage("square.and.arrow.down"),
                    identifier: UIAction.Identifier("schedule.menu.import")
                ) { [weak self] _ in
                    self?.onImport?()
                })
            }
            return UIMenu(children: actions)
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        onMenuWillPresent?()
    }

    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        lastInteractionLocation
    }
}

struct CourseScheduleCalendarView: View {
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
            let gridLineWidth = AppDesignSystem.Schedule.Grid.lineWidth
            let weekSliderHeight = AppDesignSystem.Schedule.WeekSlider.sliderHeight
            let dateHeaderHeight = AppDesignSystem.Schedule.WeekSlider.dateHeaderHeight
            let headerHeight = displayMode == .weekly
                ? weekSliderHeight + dateHeaderHeight
                : AppDesignSystem.Schedule.WeekSlider.compactHeaderHeight
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
            let cardWidth = max(dayWidth - AppDesignSystem.Schedule.Grid.courseCardTotalInset, 1)
            let weekDates = visibleWeekdays.compactMap {
                ScheduleDateCodec.calendar.date(
                    byAdding: .day,
                    value: ($0 - 1) + ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7,
                    to: firstDay
                )
            }
            let highlightWeekday = currentWeek == week
                ? ScheduleDateCodec.weekdayIndex(from: Date())
                : nil
            let timeLineSection = currentWeek == week
                ? convertMinutesToSection(minutes: currentMinute(), timeTable: timeTable)
                : nil

            ZStack(alignment: .topLeading) {
                if let highlightWeekday, visibleWeekdays.contains(highlightWeekday), let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(AppDesignSystem.Schedule.GridPalette.todayHighlight)
                        .frame(width: dayWidth, height: usableHeight)
                        .offset(x: leftWidth + dayWidth * CGFloat(index), y: headerHeight)
                }

                VStack(spacing: AppDesignSystem.Spacing.none) {
                    if displayMode == .weekly {
                        ScheduleInlineWeekSlider(
                            weeks: availableWeeks,
                            currentWeek: week,
                            highlightedWeek: currentWeek,
                            onSelectWeek: onSelectWeekValue
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: weekSliderHeight)
                        .background(AppDesignSystem.Palette.Background.secondaryGrouped)

                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            Text("第\(week)周")
                                .font(AppDesignSystem.Typography.captionEmphasis)
                                .foregroundStyle(AppDesignSystem.Foreground.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(AppDesignSystem.Schedule.Grid.minimumScaleFactor)
                                .frame(width: leftWidth, height: dateHeaderHeight)
                            .background(AppDesignSystem.Palette.Background.secondaryGrouped)

                            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
                                Button {
                                    onSelectDay(date, visibleWeekdays[index])
                                } label: {
                                    Text(mmddText(for: date))
                                        .font(AppDesignSystem.Typography.caption)
                                        .foregroundStyle(AppDesignSystem.Foreground.primary)
                                        .frame(width: dayWidth, height: dateHeaderHeight)
                                        .background(AppDesignSystem.Palette.Background.secondaryGrouped)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("第\(week)周，周\(weekdayText(for: visibleWeekdays[index]))，\(mmddText(for: date))")
                            }
                        }
                    } else {
                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            Color.clear
                                .frame(width: leftWidth, height: headerHeight)
                                .background(AppDesignSystem.Palette.Background.secondaryGrouped)

                            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, _ in
                                Text(weekdayText(for: visibleWeekdays[index]))
                                    .font(AppDesignSystem.Typography.caption)
                                    .foregroundStyle(AppDesignSystem.Foreground.primary)
                                    .frame(width: dayWidth, height: headerHeight)
                                    .background(AppDesignSystem.Palette.Background.secondaryGrouped)
                                    .accessibilityLabel("周\(weekdayText(for: visibleWeekdays[index]))")
                            }
                        }
                    }

                    ForEach(Array(timeTable.enumerated()), id: \.offset) { index, slot in
                        HStack(spacing: AppDesignSystem.Spacing.none) {
                            VStack(spacing: AppDesignSystem.Schedule.Grid.cellSpacing) {
                                Text("\(index + 1)")
                                    .font(AppDesignSystem.Typography.captionEmphasis)
                                    .lineLimit(1)
                                Text(slot.start)
                                    .font(AppDesignSystem.Typography.caption)
                                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(AppDesignSystem.Schedule.Grid.minimumScaleFactor)
                            }
                            .frame(width: leftWidth, height: rowHeight)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("第\(index + 1)节，开始时间\(slot.start)")

                            ForEach(visibleWeekdays, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: dayWidth, height: rowHeight)
                            }
                        }
                    }
                }

                ForEach(0 ... timeTable.count, id: \.self) { row in
                    Rectangle()
                        .fill(row == 0
                            ? AppDesignSystem.Schedule.GridPalette.majorLine
                            : AppDesignSystem.Schedule.GridPalette.minorLine)
                        .frame(height: gridLineWidth)
                        .offset(y: headerHeight + rowHeight * CGFloat(row) - AppDesignSystem.Schedule.Grid.lineOffset)
                        .zIndex(-1)
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
                        .fill(AppDesignSystem.Palette.Accent.primary)
                        .frame(width: dayWidth, height: AppDesignSystem.Schedule.Grid.currentTimeLineHeight)
                        .offset(
                            x: leftWidth + dayWidth * CGFloat(index),
                            y: headerHeight + rowHeight * timeLineSection
                    )
                    .zIndex(2)
                }

                VStack(spacing: AppDesignSystem.Spacing.none) {
                    Color.clear
                        .frame(height: headerHeight)
                        .allowsHitTesting(false)
                    ScheduleBlankContextMenuView(
                        onShare: onShareSchedule,
                        onImport: onImportSchedule,
                        onMenuWillPresent: { contextMenuFeedbackToken &+= 1 }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, AppDesignSystem.Size.Control.touchTarget + AppDesignSystem.Spacing.regular)
                        .padding(.bottom, AppDesignSystem.Size.Control.touchTarget + AppDesignSystem.Spacing.regular)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                ForEach(entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    ZStack(alignment: .topLeading) {
                        ForEach(entry.orderedBackgroundLayers) { layer in
                            // 课程背景使用不透明系统色，网格线保持在卡片后方。
                            CourseScheduleBackgroundView(
                                entry: entry
                            )
                            .frame(
                                width: cardWidth,
                                height: max(
                                    rowHeight * (layer.endSection - layer.startSection)
                                        - AppDesignSystem.Schedule.Grid.courseCardTotalInset,
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
                            .frame(
                                width: cardWidth,
                                height: max(
                                    rowHeight * (entry.endSection - entry.startSection)
                                        - AppDesignSystem.Schedule.Grid.courseCardTotalInset,
                                    1
                                )
                            )

                        ScheduleEntryInteractionView(
                            entry: entry,
                            onTap: { onSelect(entry) },
                            onMenuWillPresent: entry.kind == .course ? {
                                contextMenuFeedbackToken &+= 1
                                onPrepareCourseShare(entry)
                            } : nil,
                            onShare: entry.kind == .course ? { onLongPressCourse(entry) } : nil
                        )
                        .frame(
                            width: cardWidth,
                            height: max(
                                rowHeight * (entry.endSection - entry.startSection)
                                    - AppDesignSystem.Schedule.Grid.courseCardTotalInset,
                                1
                            )
                        )
                    }
                    .frame(
                        width: cardWidth,
                        height: max(
                            rowHeight * (entry.endSection - entry.startSection)
                                - AppDesignSystem.Schedule.Grid.courseCardTotalInset,
                            1
                        )
                    )
                    .contentShape(Rectangle())
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
            .background(AppDesignSystem.Palette.Background.system)
            // 课表主体沿用 List 分组内容的圆角；其它卡片使用各自样式。
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped))
            .appSelectionFeedback(trigger: week)
            .appImpactFeedback(trigger: contextMenuFeedbackToken)
        }
    }

    private func mmddText(for date: Date) -> String {
        ScheduleDateCodec.formatCompactDate(date)
    }

    private func weekdayText(for weekday: Int) -> String {
        guard (1 ... Self.weekdayTitles.count).contains(weekday) else {
            return "?"
        }
        return Self.weekdayTitles[weekday - 1]
    }

    private func currentMinute() -> Int {
        let components = ScheduleDateCodec.calendar.dateComponents([.hour, .minute], from: Date())
        return min(
            max((components.hour ?? 0) * 60 + (components.minute ?? 0), 0),
            24 * 60
        )
    }
}

/// 课表页悬浮圆形按钮的统一外观。
///
/// `Button` 和 `Menu` 共用同一套视觉样式，保持“添加”按钮的尺寸和命中区域一致。
struct CourseScheduleFABLabel: View {
    let systemImage: String

    init(systemImage: String) {
        self.systemImage = systemImage
    }

    var body: some View {
        AppFloatingActionButtonSurface {
            Image(systemName: systemImage)
                .font(AppDesignSystem.Typography.bodyEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
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

#endif
