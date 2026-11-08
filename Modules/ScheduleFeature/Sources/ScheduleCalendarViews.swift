#if os(iOS)
import ScheduleDomain
import DesignSystemKit
import SwiftUI
import UIKit

/// 空白课表区域的原生操作菜单，按真实长按坐标定位菜单。
struct ScheduleBlankContextMenuView: UIViewRepresentable {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
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
        view.interactionEvidence = interactionEvidence
        return view
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.onMenuWillPresent = onMenuWillPresent
        uiView.onShare = onShare
        uiView.onImport = onImport
        uiView.interactionEvidence = interactionEvidence
    }
}

struct ScheduleEntryInteractionView: UIViewRepresentable {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    let entry: ScheduleCalendarEntry
    let onTap: () -> Void
    var onMenuWillPresent: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var contentMode: ScheduleCardContentMode? = nil

    func makeUIView(context: Context) -> ScheduleBlankContextMenuControl {
        ScheduleBlankContextMenuControl()
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.configure(
            entry: entry, contentMode: contentMode, onTap: onTap,
            onMenuWillPresent: onMenuWillPresent, onShare: onShare,
            interactionEvidence: interactionEvidence)
    }

}

final class ScheduleBlankContextMenuControl: UIControl {
    var interactionEvidence: ((String, String) -> Void)?
    var shareTitle = "分享课表"
    var showsImport = true
    var onTap: (() -> Void)? {
        didSet {
            guard !usesSharedInteractions else { return }
            if tapGesture.isEnabled != (onTap != nil) { tapGesture.isEnabled = onTap != nil }
        }
    }
    var onMenuWillPresent: (() -> Void)?
    var onShare: (() -> Void)?
    var onImport: (() -> Void)?
    private var lastInteractionLocation: CGPoint = .zero
    private let tapGesture = UITapGestureRecognizer()
    private var usesSharedInteractions = false
    private(set) var cardText: ScheduleCardTextRenderer?
    private let cardTextLayer = CALayer()
    private var displayedTextImage: CGImage?
    var isContentVisible = true {
        didSet {
            if isContentVisible && !oldValue && hasDeferredLayout { setNeedsLayout() }
        }
    }
    private var hasDeferredLayout = false
    private let cardBackground = CALayer()
    private var backgroundLayers: [CALayer] = []
    private var backgroundFrames: [CGRect] = []
    private var backgroundKind: ScheduleCalendarKind?
    private var backgroundOpacity: Float = 1
    private var textEntry: ScheduleCalendarEntry?
    private var textMode: ScheduleCardContentMode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        layer.insertSublayer(cardBackground, at: 0)
        cardTextLayer.contentsGravity = .topLeft
        cardTextLayer.masksToBounds = true
        isMultipleTouchEnabled = true
        tintColor = UIColor(AppDesignSystem.Palette.Accent.primary)
        isContextMenuInteractionEnabled = true
        tapGesture.addTarget(self, action: #selector(handleTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.isEnabled = false
        addGestureRecognizer(tapGesture)
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
            UITraitUserInterfaceLevel.self, UITraitPreferredContentSizeCategory.self,
            UITraitLegibilityWeight.self,
        ]) { (view: ScheduleBlankContextMenuControl, _: UITraitCollection) in
            view.applyBackgroundAppearance()
            view.updateTextAppearance()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        entry: ScheduleCalendarEntry, contentMode: ScheduleCardContentMode?,
        onTap: @escaping () -> Void, onMenuWillPresent: (() -> Void)?, onShare: (() -> Void)?,
        interactionEvidence: ((String, String) -> Void)?
    ) {
        if textEntry != entry {
            let identifier = "schedule.entry.\(entry.id)"
            if accessibilityIdentifier != identifier {
                isAccessibilityElement = true
                accessibilityIdentifier = identifier
                accessibilityHint = "双击打开详情"
                accessibilityTraits = .button
                shareTitle = "分享课程"
                showsImport = false
            }
            let title = entry.title.isEmpty ? "未命名日程" : entry.title
            switch entry.kind {
            case .course: accessibilityLabel = title
            case .exam: accessibilityLabel = "考试，\(title)"
            case .custom: accessibilityLabel = "自定义日程，\(title)"
            }
            accessibilityValue = entry.subtitle.isEmpty ? "" : "地点：\(entry.subtitle)"
        }
        if !usesSharedInteractions {
            let needsOwnMenu = onShare != nil
            if isContextMenuInteractionEnabled != needsOwnMenu {
                isContextMenuInteractionEnabled = needsOwnMenu
            }
        }
        self.onTap = onTap
        self.onMenuWillPresent = onMenuWillPresent
        self.onShare = onShare
        self.interactionEvidence = interactionEvidence
        configureText(entry: entry, contentMode: contentMode)
    }

    func configureBackgrounds(_ frames: [CGRect], entry: ScheduleCalendarEntry) {
        let opacity = Float(
            entry.kind == .course || entry.backgroundLayers.count <= 1
                ? AppDesignSystem.Opacity.full
                : AppDesignSystem.Schedule.CoursePalette.secondaryLayerOpacity)
        guard frames != backgroundFrames || entry.kind != backgroundKind
            || opacity != backgroundOpacity else { return }
        backgroundFrames = frames
        backgroundKind = entry.kind
        backgroundOpacity = opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while backgroundLayers.count > frames.count {
            backgroundLayers.removeLast().removeFromSuperlayer()
        }
        while backgroundLayers.count < frames.count {
            let background = CALayer()
            background.cornerRadius = AppDesignSystem.Radius.small
            background.cornerCurve = .continuous
            cardBackground.addSublayer(background)
            backgroundLayers.append(background)
        }
        for (background, frame) in zip(backgroundLayers, frames) { background.frame = frame }
        applyBackgroundAppearance()
        CATransaction.commit()
    }

    private func applyBackgroundAppearance() {
        guard let backgroundKind else { return }
        let fill: UIColor
        let border: UIColor
        switch backgroundKind {
        case .course:
            fill = UIColor(AppDesignSystem.Palette.Background.secondary)
            border = UIColor(AppDesignSystem.Schedule.GridPalette.courseBorder)
        case .exam:
            fill = UIColor(AppDesignSystem.Schedule.CoursePalette.examSurface)
            border = UIColor(AppDesignSystem.Schedule.CoursePalette.examBorder)
        case .custom:
            fill = UIColor(AppDesignSystem.Schedule.CoursePalette.customSurface)
            border = UIColor(AppDesignSystem.Schedule.CoursePalette.customBorder)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for background in backgroundLayers {
            background.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
            background.borderColor = border.resolvedColor(with: traitCollection).cgColor
            background.borderWidth = backgroundKind == .course
                ? 0 : AppDesignSystem.Schedule.Grid.courseBorderWidth
            background.opacity = backgroundOpacity
        }
        CATransaction.commit()
    }

    func configureText(entry: ScheduleCalendarEntry, contentMode: ScheduleCardContentMode?) {
        let nextEntry = contentMode == nil ? nil : entry
        guard textEntry != nextEntry || textMode != contentMode else { return }
        textEntry = nextEntry
        textMode = contentMode
        updateTextAppearance()
    }

    private func updateTextAppearance() {
        guard let entry = textEntry, let contentMode = textMode else {
            cardTextLayer.removeFromSuperlayer()
            cardTextLayer.contents = nil
            displayedTextImage = nil
            cardText = nil
            return
        }
        let text: ScheduleCardTextRenderer
        if let cardText {
            text = cardText
        } else {
            text = ScheduleCardTextRenderer()
            cardText = text
            layer.addSublayer(cardTextLayer)
        }
        let color: UIColor
        switch entry.kind {
        case .course: color = .label
        case .exam: color = UIColor(AppDesignSystem.Palette.Highlight.primary)
        case .custom: color = UIColor(AppDesignSystem.Palette.Status.info)
        }
        text.configure(
            title: entry.title, location: entry.subtitle, contentMode: contentMode,
            font: UIFont.preferredFont(
                forTextStyle: AppDesignSystem.Typography.uiCaption,
                compatibleWith: traitCollection),
            textColor: color)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isContentVisible else {
            hasDeferredLayout = true
            return
        }
        hasDeferredLayout = false
        guard let cardText else { return }
        var frame = bounds.insetBy(
            dx: min(AppDesignSystem.Spacing.micro, bounds.width / 2),
            dy: min(AppDesignSystem.Spacing.micro, bounds.height / 2))
        let image = cardText.image(
            size: frame.size, scale: contentScaleFactor, traits: traitCollection)
        if let image {
            frame.size = CGSize(
                width: CGFloat(image.width) / contentScaleFactor,
                height: CGFloat(image.height) / contentScaleFactor)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cardTextLayer.frame != frame { cardTextLayer.frame = frame }
        if cardTextLayer.contentsScale != contentScaleFactor {
            cardTextLayer.contentsScale = contentScaleFactor
        }
        if displayedTextImage !== image {
            cardTextLayer.contents = image
            displayedTextImage = image
        }
        CATransaction.commit()
    }

    func useSharedInteractionHandling() {
        usesSharedInteractions = true
        isContextMenuInteractionEnabled = false
        removeGestureRecognizer(tapGesture)
    }

    @objc private func handleTap() {
        interactionEvidence?("interaction.ScheduleBlankContextMenuControl.tap", "tap")
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onTap else { return super.accessibilityActivate() }
        onTap()
        return true
    }

    private static func coloredMenuImage(_ name: String) -> UIImage? {
        UIImage(systemName: name)?.withTintColor(
            UIColor(AppDesignSystem.Palette.Accent.primary),
            renderingMode: .alwaysOriginal
        )
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        lastInteractionLocation = location
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            var actions: [UIMenuElement] = [
                UIAction(
                    title: self.shareTitle,
                    image: Self.coloredMenuImage("square.and.arrow.up"),
                    identifier: UIAction.Identifier(
                        self.showsImport ? "schedule.menu.share" : "schedule.course.menu.share")
                ) { [weak self] _ in
                    self?.interactionEvidence?(
                        "interaction.ScheduleBlankContextMenuControl.share", "tap")
                    self?.onShare?()
                }
            ]
            if self.showsImport {
                actions.append(
                    UIAction(
                        title: "导入课表",
                        image: Self.coloredMenuImage("square.and.arrow.down"),
                        identifier: UIAction.Identifier("schedule.menu.import")
                    ) { [weak self] _ in
                        self?.interactionEvidence?(
                            "interaction.ScheduleBlankContextMenuControl.import", "tap")
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
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight = AppDesignSystem.Schedule
        .WeekSlider.captionLineHeight
    @Environment(\.scheduleCurrentDate) private var currentDate
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
    @State private var placementProjection = ScheduleCalendarPlacementProjection()
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
            let metrics = ScheduleCalendarHeaderMetrics(captionLineHeight: captionLineHeight)
            let weekSliderHeight = metrics.weekSliderHeight
            let dateHeaderHeight = metrics.dateHeaderHeight
            let headerHeight =
                displayMode == .weekly
                ? weekSliderHeight + dateHeaderHeight
                : metrics.compactHeaderHeight
            let groups = placementProjection.resolve(
                entries: entries, separateOverlaps: displayMode == .weekly)
            let outsideHeight =
                groups.outside.isEmpty ? 0 : AppDesignSystem.Size.Control.touchTarget
            let usableHeight = max(proxy.size.height - headerHeight - outsideHeight, 1)
            let rowHeight = usableHeight / CGFloat(max(timeTable.count, 1))
            let visibleWeekdays = (1...7).filter {
                if $0 == 6 { return showSaturday }
                if $0 == 7 { return showSunday }
                return true
            }
            let columnWidth = max(proxy.size.width / CGFloat(visibleWeekdays.count + 1), 1)
            let leftWidth = columnWidth
            let dayWidth = columnWidth
            let weekDates = visibleWeekdays.compactMap {
                ScheduleDateCodec.calendar.date(
                    byAdding: .day,
                    value: ($0 - 1) + ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7,
                    to: firstDay
                )
            }
            let highlightWeekday =
                currentWeek == week
                ? ScheduleDateCodec.weekdayIndex(from: currentDate)
                : nil
            let timeLineSection =
                currentWeek == week
                ? convertMinutesToSection(minutes: currentMinute(), timeTable: timeTable)
                : nil

            ZStack(alignment: .topLeading) {
                if let highlightWeekday, visibleWeekdays.contains(highlightWeekday),
                    let index = visibleWeekdays.firstIndex(of: highlightWeekday)
                {
                    Rectangle()
                        .fill(AppDesignSystem.Schedule.GridPalette.todayHighlight)
                        .frame(width: dayWidth, height: usableHeight)
                        .offset(x: leftWidth + dayWidth * CGFloat(index), y: headerHeight)
                }

                VStack(spacing: AppDesignSystem.Spacing.none) {
                    quantizedHeader(
                        weekSliderHeight: weekSliderHeight,
                        dateHeaderHeight: dateHeaderHeight,
                        headerHeight: headerHeight,
                        leftWidth: leftWidth,
                        dayWidth: dayWidth,
                        weekDates: weekDates,
                        visibleWeekdays: visibleWeekdays
                    )

                    quantizedTimeGrid(
                        leftWidth: leftWidth,
                        dayWidth: dayWidth,
                        rowHeight: rowHeight,
                        visibleWeekdays: visibleWeekdays
                    )
                }

                ForEach(0...timeTable.count, id: \.self) { row in
                    Rectangle()
                        .fill(
                            row == 0
                                ? AppDesignSystem.Schedule.GridPalette.majorLine
                                : AppDesignSystem.Schedule.GridPalette.minorLine
                        )
                        .frame(height: gridLineWidth)
                        .offset(
                            y: headerHeight + rowHeight * CGFloat(row)
                                - AppDesignSystem.Schedule.Grid.lineOffset
                        )
                        .zIndex(-1)
                }

                ForEach(0...visibleWeekdays.count, id: \.self) { column in
                    Rectangle()
                        .fill(
                            column == 0
                                ? AppDesignSystem.Schedule.GridPalette.majorLine
                                : AppDesignSystem.Schedule.GridPalette.minorLine
                        )
                        .frame(
                            width: gridLineWidth,
                            height: proxy.size.height
                                - (displayMode == .weekly ? weekSliderHeight : 0)
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
                    let index = visibleWeekdays.firstIndex(of: highlightWeekday)
                {
                    Rectangle()
                        .fill(AppDesignSystem.Palette.Accent.primary)
                        .frame(
                            width: dayWidth,
                            height: AppDesignSystem.Schedule.Grid.currentTimeLineHeight
                        )
                        .offset(
                            x: leftWidth + dayWidth * CGFloat(index),
                            y: headerHeight + rowHeight * timeLineSection
                        )
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
                    .padding(
                        .trailing,
                        AppDesignSystem.Size.Control.touchTarget
                            + AppDesignSystem.Spacing.regular
                    )
                    .padding(
                        .bottom,
                        AppDesignSystem.Size.Control.touchTarget
                            + AppDesignSystem.Spacing.regular)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                ScheduleCalendarCardsView(
                    cards: groups.placements.filter {
                        visibleWeekdays.contains($0.entry.dayOfWeek)
                    }.map { placement in
                        quantizedCard(
                            placement: placement, dayWidth: dayWidth, rowHeight: rowHeight,
                            gridLineWidth: gridLineWidth, leftWidth: leftWidth,
                            headerHeight: headerHeight, visibleWeekdays: visibleWeekdays)
                    },
                    contentMode: cardContentMode,
                    onSelect: onSelect,
                    onMenuWillPresent: { entry in
                        contextMenuFeedbackToken &+= 1
                        onPrepareCourseShare(entry)
                    },
                    onShare: onLongPressCourse)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .zIndex(1)

                outsideEventsSection(
                    outside: groups.outside,
                    dayWidth: dayWidth,
                    outsideHeight: outsideHeight,
                    headerHeight: headerHeight,
                    usableHeight: usableHeight
                )

            }
            .clipped()
            .background(AppDesignSystem.Palette.Background.system)
            // 课表主体沿用 List 分组内容的圆角；其它卡片使用各自样式。
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped))
            .appImpactFeedback(trigger: contextMenuFeedbackToken)
        }
    }

    @ViewBuilder
    private func quantizedHeader(
        weekSliderHeight: CGFloat,
        dateHeaderHeight: CGFloat,
        headerHeight: CGFloat,
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        weekDates: [Date],
        visibleWeekdays: [Int]
    ) -> some View {
        if displayMode == .weekly {
            quantizedWeeklyHeader(
                weekSliderHeight: weekSliderHeight,
                dateHeaderHeight: dateHeaderHeight,
                leftWidth: leftWidth,
                dayWidth: dayWidth,
                weekDates: weekDates,
                visibleWeekdays: visibleWeekdays
            )
        } else {
            quantizedCompactHeader(
                headerHeight: headerHeight,
                leftWidth: leftWidth,
                dayWidth: dayWidth,
                weekDates: weekDates,
                visibleWeekdays: visibleWeekdays
            )
        }
    }

    private func quantizedWeeklyHeader(
        weekSliderHeight: CGFloat,
        dateHeaderHeight: CGFloat,
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        weekDates: [Date],
        visibleWeekdays: [Int]
    ) -> some View {
        VStack(spacing: AppDesignSystem.Spacing.none) {
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
                    quantizedDayHeaderButton(
                        date: date,
                        weekday: visibleWeekdays[index],
                        dayWidth: dayWidth,
                        height: dateHeaderHeight
                    )
                }
            }
        }
    }

    private func quantizedDayHeaderButton(
        date: Date,
        weekday: Int,
        dayWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        let weekdayName = weekdayText(for: weekday)
        let dateText = mmddText(for: date)
        return Button {
            onSelectDay(date, weekday)
        } label: {
            Text(dateText)
                .font(AppDesignSystem.Typography.caption)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
                .frame(width: dayWidth, height: height)
                .background(AppDesignSystem.Palette.Background.secondaryGrouped)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第\(week)周，周\(weekdayName)，\(dateText)")
    }

    private func quantizedCompactHeader(
        headerHeight: CGFloat,
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        weekDates: [Date],
        visibleWeekdays: [Int]
    ) -> some View {
        HStack(spacing: AppDesignSystem.Spacing.none) {
            Color.clear
                .frame(width: leftWidth, height: headerHeight)
                .background(AppDesignSystem.Palette.Background.secondaryGrouped)

            ForEach(Array(weekDates.enumerated()), id: \.offset) { index, _ in
                Text("周\(weekdayText(for: visibleWeekdays[index]))")
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Foreground.primary)
                    .frame(width: dayWidth, height: headerHeight)
                    .background(AppDesignSystem.Palette.Background.secondaryGrouped)
                    .accessibilityLabel("周\(weekdayText(for: visibleWeekdays[index]))")
            }
        }
    }

    private func quantizedTimeGrid(
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        rowHeight: CGFloat,
        visibleWeekdays: [Int]
    ) -> some View {
        ForEach(Array(timeTable.enumerated()), id: \.offset) { index, slot in
            quantizedTimeRow(
                index: index,
                slot: slot,
                leftWidth: leftWidth,
                dayWidth: dayWidth,
                rowHeight: rowHeight,
                visibleWeekdays: visibleWeekdays
            )
        }
    }

    private func quantizedTimeRow(
        index: Int,
        slot: TimeSlot,
        leftWidth: CGFloat,
        dayWidth: CGFloat,
        rowHeight: CGFloat,
        visibleWeekdays: [Int]
    ) -> some View {
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

            Color.clear
                .frame(width: dayWidth * CGFloat(visibleWeekdays.count), height: rowHeight)
        }
    }

    private func quantizedCard(
        placement: ScheduleCalendarPlacement, dayWidth: CGFloat, rowHeight: CGFloat,
        gridLineWidth: CGFloat, leftWidth: CGFloat, headerHeight: CGFloat,
        visibleWeekdays: [Int]
    ) -> ScheduleCalendarCard {
        let entry = placement.entry
        let laneWidth = dayWidth / CGFloat(placement.columnCount)
        let width = max(laneWidth - AppDesignSystem.Schedule.Grid.courseCardTotalInset, 1)
        let height = max(
            rowHeight * (entry.endSection - entry.startSection)
                - AppDesignSystem.Schedule.Grid.courseCardTotalInset, 1)
        let frame = CGRect(
            x: leftWidth + dayWidth
                * CGFloat(visibleWeekdays.firstIndex(of: entry.dayOfWeek) ?? 0)
                + laneWidth * CGFloat(placement.column) + gridLineWidth,
            y: headerHeight + rowHeight * entry.startSection + gridLineWidth,
            width: width, height: height)
        return ScheduleCalendarCard(
            entry: entry, frame: frame,
            backgrounds: entry.orderedBackgroundLayers.map { layer in
                CGRect(
                    x: 0, y: rowHeight * (layer.startSection - entry.startSection) + gridLineWidth,
                    width: width,
                    height: max(
                        rowHeight * (layer.endSection - layer.startSection)
                            - AppDesignSystem.Schedule.Grid.courseCardTotalInset, 1))
            })
    }

    @ViewBuilder
    private func outsideEventsSection(
        outside: [ScheduleCalendarEntry],
        dayWidth: CGFloat,
        outsideHeight: CGFloat,
        headerHeight: CGFloat,
        usableHeight: CGFloat
    ) -> some View {
        if !outside.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    ForEach(outside) { entry in
                        outsideEventCard(
                            entry: entry,
                            dayWidth: dayWidth,
                            outsideHeight: outsideHeight
                        )
                    }
                }
            }
            .accessibilityIdentifier("schedule.calendar.outside-events")
            .frame(height: outsideHeight)
            .background { horizontalControlFramePreference }
            .offset(y: headerHeight + usableHeight)
            .zIndex(1)
        }
    }

    private func outsideEventCard(
        entry: ScheduleCalendarEntry,
        dayWidth: CGFloat,
        outsideHeight: CGFloat
    ) -> some View {
        ZStack {
            Text(entry.title)
                .font(AppDesignSystem.Typography.captionEmphasis)
                .lineLimit(2)
                .padding(.horizontal, AppDesignSystem.Spacing.regular)
            ScheduleEntryInteractionView(
                entry: entry, onTap: { onSelect(entry) })
        }
        .frame(width: dayWidth, height: outsideHeight)
        .background(AppDesignSystem.Palette.Accent.surface)
        .clipShape(
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
    }

    private var horizontalControlFramePreference: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: AppHorizontalControlFramesKey.self,
                value: [geometry.frame(in: .global)])
        }
    }

    private func mmddText(for date: Date) -> String {
        ScheduleDateCodec.formatCompactDate(date)
    }

    private func weekdayText(for weekday: Int) -> String {
        ScheduleDateCodec.weekdaySymbol(weekday)
    }

    private func currentMinute() -> Int {
        let components = ScheduleDateCodec.calendar.dateComponents(
            [.hour, .minute], from: currentDate)
        return min(
            max((components.hour ?? 0) * 60 + (components.minute ?? 0), 0),
            24 * 60
        )
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

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
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
