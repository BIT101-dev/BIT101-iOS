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

    var body: some View {
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
                Calendar.current.date(
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

                        HStack(spacing: 0) {
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
                        HStack(spacing: 0) {
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
                        HStack(spacing: 0) {
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
                                showBorder: showBorder,
                                isOpaque: entry.kind == .course
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
            // 课表主体改用 List 分组内容的圆角；不改变其它普通卡片。
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
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

/// 课表中的单个课程 / 考试 / 自定义日程块。
private struct CourseScheduleBlockView: View {
    let entry: ScheduleCalendarEntry
    let contentMode: ScheduleCardContentMode

    var body: some View {
        contentLayout
        .padding(AppDesignSystem.Spacing.micro)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentLayout: some View {
        switch contentMode {
        case .nameAndLocation:
            VStack(spacing: 0) {
                if !entry.title.isEmpty {
                    Spacer(minLength: 0)
                    titleLabel
                }
                if !entry.subtitle.isEmpty {
                    Spacer(minLength: 0)
                    locationLabel
                } else if !entry.title.isEmpty {
                    Spacer(minLength: 0)
                }
            }
        case .name:
            centered(titleLabel)
        case .location:
            if entry.subtitle.isEmpty {
                centered(titleLabel)
            } else {
                centered(locationLabel)
            }
        }
    }

    private var titleLabel: some View {
        ScheduleDenseTextLabel(
                text: entry.title,
                textStyle: AppDesignSystem.Schedule.courseText.style,
                textColor: uiTextColor,
                numberOfLines: titleLineLimit,
                minimumScaleFactor: AppDesignSystem.Schedule.courseText.titleMinimumScaleFactor,
                lineBreakMode: titleLineBreakMode
        )
        .frame(maxWidth: .infinity)
    }

    /// 仅在“名称+地点”模式下，两格课程限制名称最多两行；其它模式不人为截断。
    private var titleLineLimit: Int {
        contentMode == .nameAndLocation && entry.endSection - entry.startSection <= 2
            ? AppDesignSystem.Schedule.courseText.titleMaximumLinesForTwoSections
            : 0
    }

    private var titleLineBreakMode: NSLineBreakMode {
        titleLineLimit > 0 ? .byTruncatingTail : .byWordWrapping
    }

    private var locationLabel: some View {
        ScheduleDenseTextLabel(
            text: entry.subtitle,
            textStyle: AppDesignSystem.Schedule.courseText.style,
            textColor: uiTextColor,
            numberOfLines: AppDesignSystem.Schedule.courseText.locationLineCount,
            minimumScaleFactor: AppDesignSystem.Schedule.courseText.locationMinimumScaleFactor,
            lineBreakMode: .byCharWrapping,
            lineHeightMultiple: AppDesignSystem.Schedule.courseText.locationLineHeightMultiple
        )
        .frame(maxWidth: .infinity)
    }

    private func centered<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 课表专用紧凑文字块，直接使用 UIKit 的字符级换行，确保不回退到词语策略。
private struct ScheduleDenseTextLabel: UIViewRepresentable {
    let text: String
    let textStyle: UIFont.TextStyle
    let textColor: UIColor
    let numberOfLines: Int
    let minimumScaleFactor: CGFloat
    let lineBreakMode: NSLineBreakMode
    let lineHeightMultiple: CGFloat

    init(
        text: String,
        textStyle: UIFont.TextStyle,
        textColor: UIColor,
        numberOfLines: Int,
        minimumScaleFactor: CGFloat,
        lineBreakMode: NSLineBreakMode,
        lineHeightMultiple: CGFloat = 0
    ) {
        self.text = text
        self.textStyle = textStyle
        self.textColor = textColor
        self.numberOfLines = numberOfLines
        self.minimumScaleFactor = minimumScaleFactor
        self.lineBreakMode = lineBreakMode
        self.lineHeightMultiple = lineHeightMultiple
    }

    func makeUIView(context: Context) -> DenseLabel {
        let label = DenseLabel()
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ uiView: DenseLabel, context: Context) {
        let font = UIFont.preferredFont(forTextStyle: textStyle)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = lineBreakMode
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = 0
        if lineHeightMultiple > 0 {
            paragraphStyle.lineHeightMultiple = lineHeightMultiple
        } else {
            paragraphStyle.minimumLineHeight = font.lineHeight
            paragraphStyle.maximumLineHeight = font.lineHeight
        }

        uiView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        uiView.numberOfLines = numberOfLines
        uiView.textAlignment = .center
        uiView.adjustsFontForContentSizeCategory = true
        uiView.adjustsFontSizeToFitWidth = numberOfLines == 1
        uiView.minimumScaleFactor = minimumScaleFactor
        uiView.allowsDefaultTighteningForTruncation = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: DenseLabel,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        uiView.preferredMaxLayoutWidth = width
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: measured.height)
    }

    final class DenseLabel: UILabel {
        override func layoutSubviews() {
            preferredMaxLayoutWidth = bounds.width
            super.layoutSubviews()
        }
    }
}

private struct CourseScheduleBackgroundView: View {
    let entry: ScheduleCalendarEntry
    let showBorder: Bool
    let isOpaque: Bool

    var body: some View {
        AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.badge)
            .fill(backgroundColor)
            .opacity(isOpaque ? 1 : (entry.backgroundLayers.count > 1 ? 0.5 : 1))
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
            return isOpaque
                ? AppDesignSystem.Palette.secondaryBackground
                : AppDesignSystem.Palette.secondaryFill.opacity(0.95)
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
/// 单独抽出来后，`Button` 和 `Menu` 可以共用同一套视觉样式，
/// 避免“添加”按钮因为交互容器不同而出现尺寸或命中区域错位。
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
        // 先等滚动内容完成首轮布局，再设置选中项；直接在初始化阶段绑定滚动位置会落在半个刻度。
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

    /// 首次布局完成后再次定位到完整周次项，避免冷启动时停在半个刻度。
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

/// 使用 UIKit 手势识别器保留真实长按坐标，不影响课程块原有的点击手势。
private struct LongPressLocationDetector: UIViewRepresentable {
    let onTap: (() -> Void)?
    let onEnded: (CGPoint) -> Void

    init(onTap: (() -> Void)? = nil, onEnded: @escaping (CGPoint) -> Void) {
        self.onTap = onTap
        self.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        view.addGestureRecognizer(longPress)
        if onTap != nil {
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleTap(_:))
            )
            tap.require(toFail: longPress)
            view.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onEnded = onEnded
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: (() -> Void)?
        var onEnded: (CGPoint) -> Void

        init(onEnded: @escaping (CGPoint) -> Void) {
            self.onEnded = onEnded
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onEnded(recognizer.location(in: recognizer.view))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            onTap?()
        }
    }
}

/// 课表网格内部统一使用的条目类型。
///
/// 课程、考试、自定义日程最终都会投影成同一种“日历块”，但颜色和详情逻辑不同。
enum ScheduleCalendarKind {
    case course
    case exam
    case custom
}

/// 供课表网格渲染的统一条目模型。
///
/// 这是课表 UI 层内部使用的适配模型，不直接持久化。
struct ScheduleCalendarEntry: Identifiable {
    let id: String
    let sourceID: String
    /// 叠加模式下，一个格子可能对应多门课程；普通模式只有一个元素。
    let sourceIDs: [String]
    let dayOfWeek: Int
    let startSection: CGFloat
    let endSection: CGFloat
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
    let start = Calendar.current.startOfDay(for: firstDay)
    let today = Calendar.current.startOfDay(for: Date())
    let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
    return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
}

/// 处理同一天中互相重叠的日历块，避免后插入的块把前一个块完全遮住。
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
