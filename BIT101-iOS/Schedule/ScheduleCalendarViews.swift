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
    let onShare: () -> Void
    let onImport: () -> Void

    func makeUIView(context: Context) -> ScheduleBlankContextMenuControl {
        let view = ScheduleBlankContextMenuControl()
        view.onShare = onShare
        view.onImport = onImport
        return view
    }

    func updateUIView(_ uiView: ScheduleBlankContextMenuControl, context: Context) {
        uiView.onShare = onShare
        uiView.onImport = onImport
    }
}

private final class ScheduleBlankContextMenuControl: UIControl {
    var onShare: (() -> Void)?
    var onImport: (() -> Void)?
    private var lastInteractionLocation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
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

    let entries: [ScheduleCalendarEntry]
    let week: Int
    let displayMode: ScheduleDisplayMode
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
    let onSelectWeek: () -> Void
    let onLongPressCourse: (ScheduleCalendarEntry) -> Void
    let onPrepareCourseShare: (ScheduleCalendarEntry) -> Void
    let onShareSchedule: () -> Void
    let onImportSchedule: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let leftWidth: CGFloat = 50
            let headerHeight: CGFloat = 42
            let usableHeight = max(proxy.size.height - headerHeight, 1)
            let rowHeight = usableHeight / CGFloat(max(timeTable.count, 1))
            let visibleWeekdays = (1 ... 7).filter {
                if $0 == 6 { return showSaturday }
                if $0 == 7 { return showSunday }
                return true
            }
            let dayWidth = max((proxy.size.width - leftWidth) / CGFloat(max(visibleWeekdays.count, 1)), 1)
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
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: dayWidth, height: usableHeight)
                        .offset(x: leftWidth + dayWidth * CGFloat(index), y: headerHeight)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Group {
                            if displayMode == .weekly {
                                Button(action: onSelectWeek) {
                                    VStack(spacing: 1) {
                                        Text("\(week)")
                                        Text("周")
                                    }
                                    .frame(width: leftWidth, height: headerHeight)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("选择周次")
                            } else {
                                Color.clear
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(displayMode == .weekly ? Color.accentColor : Color.primary)
                        .frame(width: leftWidth, height: headerHeight)
                        .background {
                            if displayMode == .weekly {
                                Color.accentColor.opacity(0.12)
                            } else {
                                Color(.secondarySystemBackground)
                            }
                        }

                        ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
                            if displayMode == .allWeeks {
                                Text(weekdayText(for: visibleWeekdays[index]))
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .frame(width: dayWidth, height: headerHeight)
                                    .background(Color(.secondarySystemBackground))
                            } else {
                                Button {
                                    onSelectDay(date, visibleWeekdays[index])
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(weekdayText(for: visibleWeekdays[index]))
                                        Text(mmddText(for: date))
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .frame(width: dayWidth, height: headerHeight)
                                    .background(Color(.secondarySystemBackground))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(Array(timeTable.enumerated()), id: \.offset) { index, slot in
                        HStack(spacing: 0) {
                            VStack(spacing: 1) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                Text(slot.start)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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
                            .frame(height: 0.5)
                            .offset(y: headerHeight + rowHeight * CGFloat(row))
                    }
                }

                ForEach(0 ... visibleWeekdays.count, id: \.self) { column in
                    Rectangle()
                        .fill(Color.secondary.opacity(column == 0 ? 0.18 : 0.12))
                        .frame(width: 0.5, height: proxy.size.height)
                        .offset(x: leftWidth + dayWidth * CGFloat(column))
                }

                if let timeLineSection,
                   timeLineSection > 0,
                   timeLineSection < CGFloat(timeTable.count),
                   let highlightWeekday,
                   visibleWeekdays.contains(highlightWeekday),
                   let index = visibleWeekdays.firstIndex(of: highlightWeekday) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: dayWidth, height: 1.5)
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
                        onShare: onShareSchedule,
                        onImport: onImportSchedule
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)

                ForEach(entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    ZStack(alignment: .topLeading) {
                        ForEach(entry.backgroundLayers) { layer in
                            CourseScheduleBackgroundView(entry: entry, showBorder: showBorder)
                                .frame(
                                    width: max(dayWidth - 4, 1),
                                    height: max(rowHeight * (layer.endSection - layer.startSection) - 4, 1)
                                )
                                .offset(y: rowHeight * (layer.startSection - entry.startSection) + 2)
                        }

                        CourseScheduleBlockView(entry: entry, showBorder: false, showsBackground: false)
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
                                        .frame(width: 1, height: 1)
                                        .onAppear { onPrepareCourseShare(entry) }
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                        .frame(
                            width: max(dayWidth - 4, 1),
                            height: max(rowHeight * (entry.endSection - entry.startSection) - 4, 1)
                        )
                    }
                    .frame(
                        width: max(dayWidth - 4, 1),
                        height: max(rowHeight * (entry.endSection - entry.startSection) - 4, 1)
                    )
                    .offset(
                        x: leftWidth + dayWidth * CGFloat(visibleWeekdays.firstIndex(of: entry.dayOfWeek) ?? 0) + 2,
                        y: headerHeight + rowHeight * entry.startSection + 2
                    )
                }

            }
            .clipped()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    let showBorder: Bool
    let showsBackground: Bool

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)

            textStack(entry.title, minimumScaleFactor: 0.75)

            Spacer(minLength: 0)

            textStack(entry.subtitle, minimumScaleFactor: 0.7)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            }
        }
        .overlay {
            if showBorder, showsBackground {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.8)
            }
        }
    }

    @ViewBuilder
    private func textStack(_ value: String, minimumScaleFactor: CGFloat) -> some View {
        let groups = value.components(separatedBy: "\n\n")
        VStack(spacing: groups.count > 1 ? 8 : 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .minimumScaleFactor(minimumScaleFactor)
                    .foregroundStyle(textColor)
            }
        }
    }

    private var backgroundColor: Color {
        switch entry.kind {
        case .course:
            return Color(uiColor: .secondarySystemFill).opacity(0.95)
        case .exam:
            return Color.orange.opacity(0.22)
        case .custom:
            return Color.blue.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch entry.kind {
        case .course:
            return Color.secondary.opacity(0.25)
        case .exam:
            return Color.orange.opacity(0.35)
        case .custom:
            return Color.blue.opacity(0.30)
        }
    }

    private var textColor: Color {
        switch entry.kind {
        case .course:
            return .primary
        case .exam:
            return .orange
        case .custom:
            return .blue
        }
    }

}

private struct CourseScheduleBackgroundView: View {
    let entry: ScheduleCalendarEntry
    let showBorder: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(backgroundColor)
            .opacity(entry.backgroundLayers.count > 1 ? 0.5 : 1)
            .overlay {
                if showBorder {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.8)
                }
            }
    }

    private var backgroundColor: Color {
        switch entry.kind {
        case .course:
            return Color(uiColor: .secondarySystemFill).opacity(0.95)
        case .exam:
            return Color.orange.opacity(0.22)
        case .custom:
            return Color.blue.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch entry.kind {
        case .course:
            return Color.secondary.opacity(0.25)
        case .exam:
            return Color.orange.opacity(0.35)
        case .custom:
            return Color.blue.opacity(0.30)
        }
    }
}

/// 右下角悬浮按钮。
struct CourseScheduleFAB: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CourseScheduleFABLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 课表页悬浮圆形按钮的统一外观。
///
/// 单独抽出来后，`Button` 和 `Menu` 可以共用同一套视觉样式，
/// 避免“添加”按钮因为交互容器不同而出现尺寸或命中区域错位。
struct CourseScheduleFABLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}

/// 按周模式的横向周次选择器。
struct ScheduleWeekPickerSheet: View {
    let weeks: [Int]
    let currentWeek: Int
    let onSelectWeek: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWeek: Int?

    init(
        weeks: [Int],
        currentWeek: Int,
        onSelectWeek: @escaping (Int) -> Void
    ) {
        self.weeks = weeks
        self.currentWeek = currentWeek
        self.onSelectWeek = onSelectWeek
        _selectedWeek = State(initialValue: weeks.contains(currentWeek) ? currentWeek : weeks.first)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text("选择周次")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    if let selectedWeek {
                        onSelectWeek(selectedWeek)
                    }
                    dismiss()
                }
                .fontWeight(.semibold)
            }

            Text("第\(selectedWeek ?? currentWeek)周")
                .font(.title3.weight(.semibold))

            GeometryReader { proxy in
                let itemWidth: CGFloat = 30
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(weeks, id: \.self) { week in
                            VStack(spacing: 4) {
                                Text(isMajorWeek(week) ? "\(week)" : "")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(week == selectedWeek ? .primary : .secondary)
                                    .frame(height: 16)
                                Capsule()
                                    .fill(week == selectedWeek ? Color.accentColor : Color.secondary.opacity(0.55))
                                    .frame(width: week == selectedWeek ? 5 : 4, height: isMajorWeek(week) ? 42 : 28)
                            }
                            .frame(width: itemWidth, height: 70, alignment: .top)
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
                    .frame(minHeight: 70)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selectedWeek, anchor: .center)
                .safeAreaPadding(.horizontal, max((proxy.size.width - itemWidth) / 2, 0))
                .overlay {
                    VStack(spacing: 0) {
                        Image(systemName: "triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .rotationEffect(.degrees(180))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 42)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 78)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
    }

    private func isMajorWeek(_ week: Int) -> Bool {
        week == 1 || week % 5 == 0
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
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
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
}

struct ScheduleCalendarLayer: Identifiable {
    let id: String
    let startSection: CGFloat
    let endSection: CGFloat
}

/// 课表条目详情。
///
/// 课表块点击后的二级详情页，兼容课程、考试和自定义日程三种来源。
struct ScheduleEntryDetailSheet: View {
    let entry: ScheduleCalendarEntry
    let academicCourses: [CourseRecord]
    let currentWeek: Int
    let timeTable: [TimeSlot]
    let allowsCourseMutation: Bool
    let isOverviewMode: Bool
    let allowsCustomScheduleMutation: Bool
    let onOpenAcademicCourse: (CourseNavigationRequest) -> Void
    let onEditCourseOccurrence: (String) -> Void
    let onEditCourse: (String) -> Void
    let onDeleteCourseOccurrence: (String) -> Void
    let onDeleteCourse: (String) -> Void
    let onEditCustomSchedule: () -> Void
    let onDeleteCustomSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCourseDeletion: PendingCourseDeletion?
    @State private var isResolvingAcademicCourse = false
    @State private var academicCourseAlert: AppAlert?

    var body: some View {
        NavigationStack {
            List {
                if entry.kind == .course, !academicCourseGroups.isEmpty {
                    courseDetailSections
                } else {
                    Section {
                        Text(entry.title)
                            .font(.headline)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !entry.detailLines.isEmpty {
                        Section("详情") {
                            ForEach(entry.detailLines, id: \.self) { line in
                                Text(line)
                            }
                        }
                    }
                }

                if entry.kind == .course, !allowsCourseMutation {
                    Section("编辑") {
                        Text(isOverviewMode
                            ? "全学期叠加仅用于查看；请切换为按周显示后再编辑课程。"
                            : "分享课表是只读副本，不能调课、删除课程或做调休 / 放假。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.kind == .custom, allowsCustomScheduleMutation {
                    Section {
                        Button("编辑") {
                            dismiss()
                            onEditCustomSchedule()
                        }
                        Button("删除", role: .destructive) {
                            onDeleteCustomSchedule()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert(item: $pendingCourseDeletion) { target in
                Alert(
                    title: Text("确认删除"),
                    message: Text(target.message(entry: entry, currentWeek: currentWeek)),
                    primaryButton: .destructive(Text("删除")) {
                        switch target {
                        case .occurrence:
                            onDeleteCourseOccurrence(target.courseID)
                        case .wholeCourse:
                            onDeleteCourse(target.courseID)
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .diagnosticAlert(item: $academicCourseAlert)
        }
    }

    @MainActor
    private func openAcademicCourse(_ course: CourseRecord) async {
        guard !isResolvingAcademicCourse else { return }

        isResolvingAcademicCourse = true
        defer { isResolvingAcademicCourse = false }
        do {
            guard let resolution = try await ScheduleAcademicCourseResolver().resolve(course) else {
                academicCourseAlert = AppAlert(
                    title: "没有找到此课程",
                    message: "“\(course.name)”暂未收录在学业课程中。"
                )
                return
            }
            dismiss()
            onOpenAcademicCourse(resolution.navigationRequest)
        } catch {
            academicCourseAlert = AppAlert(
                title: "查找课程失败",
                message: error.localizedDescription
            )
        }
    }

    private var title: String {
        switch entry.kind {
        case .course: return "课程详情"
        case .exam: return "考试详情"
        case .custom: return "自定义日程"
        }
    }

    private enum PendingCourseDeletion: Identifiable {
        case occurrence(courseID: String, courseName: String, week: Int)
        case wholeCourse(courseID: String, courseName: String)

        var id: String {
            switch self {
            case let .occurrence(courseID, _, _): return "occurrence-\(courseID)"
            case let .wholeCourse(courseID, _): return "whole-\(courseID)"
            }
        }

        var courseID: String {
            switch self {
            case let .occurrence(courseID, _, _), let .wholeCourse(courseID, _): return courseID
            }
        }

        func message(entry: ScheduleCalendarEntry, currentWeek: Int) -> String {
            switch self {
            case let .occurrence(_, courseName, week):
                return "你要删除的是第\(week)周的一节课：\(courseName)"
            case let .wholeCourse(_, courseName):
                return "你要删除的是\(courseName)这门课的本学期所有课程"
            }
        }
    }

    @ViewBuilder
    private var courseDetailSections: some View {
        ForEach(academicCourseGroups.indices, id: \.self) { index in
            let group = academicCourseGroups[index]
            let first = group[0]
            Section {
                Text(ScheduleDisplayNormalizer.normalizeCourseTitle(first.name))
                    .font(.headline)
                let classrooms = unique(group.map { ScheduleDisplayNormalizer.normalizeClassroom($0.classroom) }.filter { !$0.isEmpty })
                if !classrooms.isEmpty {
                    Text(classrooms.joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                }
            }

            Section("详情") {
                ForEach(detailLines(for: group), id: \.self) { line in
                    Text(line)
                }
            }

            Section("学业课程") {
                academicCourseRow(for: group)
            }

            if allowsCourseMutation {
                Section {
                    Button("调这节课") {
                        dismiss()
                        onEditCourseOccurrence(first.id)
                    }
                    Button("调这门课") {
                        dismiss()
                        onEditCourse(first.id)
                    }
                }

                Section {
                    Button("删除这节课", role: .destructive) {
                        pendingCourseDeletion = .occurrence(
                            courseID: first.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name),
                            week: mutationWeek(for: group)
                        )
                    }
                    Button("删除这门课", role: .destructive) {
                        pendingCourseDeletion = .wholeCourse(
                            courseID: first.id,
                            courseName: ScheduleDisplayNormalizer.normalizeCourseTitle(first.name)
                        )
                    }
                }
            }

            if index < academicCourseGroups.count - 1 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var academicCourseGroups: [[CourseRecord]] {
        var groups: [[CourseRecord]] = []
        for course in academicCourses {
            if let index = groups.firstIndex(where: { scheduleCourseIdentity($0[0]) == scheduleCourseIdentity(course) }) {
                groups[index].append(course)
            } else {
                groups.append([course])
            }
        }
        return groups
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func academicCourseRow(for group: [CourseRecord]) -> some View {
        let course = group[0]
        return Button {
            Task { await openAcademicCourse(course) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduleDisplayNormalizer.normalizeCourseTitle(course.name))
                        .lineLimit(1)
                    let teachers = unique(group.map(\.teacher).filter { !$0.isEmpty })
                    if academicCourseGroups.count > 1, !teachers.isEmpty {
                        Text(teachers.joined(separator: "、"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isResolvingAcademicCourse {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(isResolvingAcademicCourse)
    }

    private func detailLines(for group: [CourseRecord]) -> [String] {
        guard let first = group.first else { return [] }
        let teachers = unique(group.map(\.teacher).filter { !$0.isEmpty })
        let classrooms = unique(group.map { ScheduleDisplayNormalizer.normalizeClassroom($0.classroom) }.filter { !$0.isEmpty })
        let sections = unique(group.map(\.sectionText))
        let descriptions = unique(group.map(\.description).filter { !$0.isEmpty })
        return [
            teachers.isEmpty ? nil : "教师：\(teachers.joined(separator: "、"))",
            classrooms.isEmpty ? nil : "教室：\(classrooms.joined(separator: "\n"))",
            "学分：\(first.credit > 0 ? String(first.credit) : "-")",
            "节次：\(sections.joined(separator: "\n"))",
            descriptions.isEmpty ? nil : descriptions.joined(separator: "\n"),
        ].compactMap { $0 }
    }

    private func mutationWeek(for group: [CourseRecord]) -> Int {
        guard let course = group.first else { return currentWeek }
        return course.weeks.contains(currentWeek) ? currentWeek : (course.weeks.first ?? currentWeek)
    }
}

func scheduleCourseIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)|name:\(name)"
    }
    return "name:\(name)|teacher:\(course.teacher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
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
