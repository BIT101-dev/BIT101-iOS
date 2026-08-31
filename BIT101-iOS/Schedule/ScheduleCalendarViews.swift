//
//  ScheduleCalendarViews.swift
//  BIT101-iOS
//
//  Split from ScheduleRootView.swift.
//

import SwiftUI

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
                        VStack(spacing: 1) {
                            Text("\(week)")
                            Text("周")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: leftWidth, height: headerHeight)
                        .background(Color(.secondarySystemBackground))

                        ForEach(Array(weekDates.enumerated()), id: \.offset) { index, date in
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

                ForEach(entries.filter { visibleWeekdays.contains($0.dayOfWeek) }) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        CourseScheduleBlockView(entry: entry, showBorder: showBorder)
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)

            Text(entry.title)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.75)
                .foregroundStyle(textColor)

            Spacer(minLength: 0)

            Text(entry.subtitle)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let dayOfWeek: Int
    let startSection: CGFloat
    let endSection: CGFloat
    let title: String
    let subtitle: String
    let detailLines: [String]
    let kind: ScheduleCalendarKind
}

/// 课表条目详情。
///
/// 课表块点击后的二级详情页，兼容课程、考试和自定义日程三种来源。
struct ScheduleEntryDetailSheet: View {
    let entry: ScheduleCalendarEntry
    let academicCourse: CourseRecord?
    let currentWeek: Int
    let timeTable: [TimeSlot]
    let allowsCourseMutation: Bool
    let allowsCustomScheduleMutation: Bool
    let onOpenAcademicCourse: (Int) -> Void
    let onEditCourseOccurrence: () -> Void
    let onEditCourse: () -> Void
    let onDeleteCourseOccurrence: () -> Void
    let onDeleteCourse: () -> Void
    let onEditCustomSchedule: () -> Void
    let onDeleteCustomSchedule: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCourseDeletion: PendingCourseDeletion?
    @State private var isResolvingAcademicCourse = false
    @State private var academicCourseAlert: AppAlert?

    var body: some View {
        NavigationStack {
            List {
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

                if entry.kind == .course {
                    Section {
                        Button {
                            Task { await openAcademicCourse() }
                        } label: {
                            HStack {
                                Label("在“学业－课程”中查看", systemImage: "books.vertical")
                                Spacer()
                                if isResolvingAcademicCourse {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isResolvingAcademicCourse)
                    }
                }

                if entry.kind == .course, allowsCourseMutation {
                    Section {
                        Button("调这节课") {
                            dismiss()
                            onEditCourseOccurrence()
                        }
                        Button("调这门课") {
                            dismiss()
                            onEditCourse()
                        }
                    }

                    Section {
                        Button("删除这节课", role: .destructive) {
                            pendingCourseDeletion = .occurrence
                        }
                        Button("删除这门课", role: .destructive) {
                            pendingCourseDeletion = .wholeCourse
                        }
                    }
                }

                if entry.kind == .course, !allowsCourseMutation {
                    Section("编辑") {
                        Text("分享课表是只读副本，不能调课、删除课程或做调休 / 放假。")
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
                            onDeleteCourseOccurrence()
                        case .wholeCourse:
                            onDeleteCourse()
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .alert(item: $academicCourseAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }

    @MainActor
    private func openAcademicCourse() async {
        guard !isResolvingAcademicCourse else { return }
        guard let academicCourse else {
            academicCourseAlert = AppAlert(
                title: "没有找到此课程",
                message: "当前课表中找不到这门课程的完整信息。"
            )
            return
        }

        isResolvingAcademicCourse = true
        defer { isResolvingAcademicCourse = false }
        do {
            guard let course = try await ScheduleAcademicCourseResolver().resolve(academicCourse) else {
                academicCourseAlert = AppAlert(
                    title: "没有找到此课程",
                    message: "“\(academicCourse.name)”暂未收录在学业课程中。"
                )
                return
            }
            dismiss()
            onOpenAcademicCourse(course.id)
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
        case occurrence
        case wholeCourse

        var id: Int {
            switch self {
            case .occurrence: return 0
            case .wholeCourse: return 1
            }
        }

        func message(entry: ScheduleCalendarEntry, currentWeek: Int) -> String {
            switch self {
            case .occurrence:
                return "你要删除的是第\(currentWeek)周第\(Int(entry.startSection) + 1)到第\(Int(entry.endSection))节的一节课：\(entry.title)"
            case .wholeCourse:
                return "你要删除的是\(entry.title)这门课的本学期所有课程"
            }
        }
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
