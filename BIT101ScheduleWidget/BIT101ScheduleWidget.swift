//
//  BIT101ScheduleWidget.swift
//  BIT101ScheduleWidget
//
//  Created by Codex on 2026-03-28.
//

import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

/// 课表未同步时统一使用的 widget 空态提示。
private let scheduleWidgetCampusNetworkMessage = "请先获取课表"
/// 未登录时统一使用的 widget 空态提示。
private let scheduleWidgetLoginMessage = "请登录"
/// 当后续没有课程时统一使用的 widget 空态提示。
private let scheduleWidgetRestMessage = "课已经上完，好好休息"
@available(iOSApplicationExtension 16.2, *)
/// 课程提醒 Live Activity 配置。
///
/// 锁屏态展示完整提醒信息；灵动岛则拆成三种展示：
/// - `expanded`：左侧显示提醒类型，右侧显示倒计时
/// - `compact`：只保留“类型 + 倒计时”
/// - `minimal`：退化成一个系统图标
///
/// 这块故意尽量贴近 Apple 的 Live Activity demo 写法：
/// 展示层直接绑定一个目标时刻，让系统自己驱动 timer 文本更新。
struct CourseReminderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseReminderActivityAttributes.self) { context in
            // 锁屏态：标题、副标题和完整倒计时都放在这里，信息最全。
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.state.kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(context.state.countdownTargetDate, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(context.state.classroom.isEmpty ? context.state.teacher : context.state.classroom)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                LiveActivityTimerText(
                    targetDate: context.state.countdownTargetDate,
                    style: .large
                )
            }
            .padding(12)
            .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态左侧：只显示“课程/日程”类型，尽量贴近 demo 的低密度布局。
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.kindText)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                // 展开态右侧：只放倒计时，尽量向 demo 的 timer 区域靠拢。
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityTimerText(
                        targetDate: context.state.countdownTargetDate,
                        style: .expanded
                    )
                    .padding(.trailing, 6)
                }
                // 展开态中间：标题单行显示，避免与摄像头区域和倒计时互相挤压。
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                // 展开态底部：把时间段和地点压成一条摘要，保证必要信息都在但不堆多行。
                DynamicIslandExpandedRegion(.bottom) {
                    Text(liveActivityExpandedSummaryText(for: context.state))
                        .font(.headline)
                        .lineLimit(1)
                }
            } compactLeading: {
                // 紧凑态左侧只显示“上课/日程”，尽量降低占宽。
                Text(context.state.kindText)
                    .font(.caption)
                    .lineLimit(1)
            } compactTrailing: {
                // 紧凑态右侧只显示倒计时，是最需要稳定刷新的区域。
                LiveActivityTimerText(
                    targetDate: context.state.countdownTargetDate,
                    style: .compact
                )
            } minimal: {
                Image(systemName: "calendar.badge.clock")
            }
            .widgetURL(URL(string: "bit101://schedule/courses"))
        }
    }

    /// 展开态底部统一摘要：开始时间优先，其后拼接地点/老师。
    private func liveActivityExpandedSummaryText(for state: CourseReminderActivityAttributes.ContentState) -> String {
        let classroom = state.classroom.trimmingCharacters(in: .whitespacesAndNewlines)
        let teacher = state.teacher.trimmingCharacters(in: .whitespacesAndNewlines)

        if !classroom.isEmpty && !teacher.isEmpty {
            return "\(state.timeRangeText) \(classroom) \(teacher)"
        }
        if !classroom.isEmpty {
            return "\(state.timeRangeText) \(classroom)"
        }
        if !teacher.isEmpty {
            return "\(state.timeRangeText) \(teacher)"
        }
        return state.timeRangeText
    }

}

/// Live Activity 使用的动态计时视图。
///
/// 这里不再显示“课中剩余时间”，只负责在课前窗口里倒计时到开始。
/// 结构上尽量贴近 Apple 常见 demo：直接绑定一个未来 Date，并交给系统 timer 文本刷新。
private struct LiveActivityTimerText: View {
    enum Style {
        case large
        case expanded
        case compact
    }

    let targetDate: Date
    let style: Style

    var body: some View {
        switch style {
        case .large:
            // 锁屏态允许更大字体，优先保证可读性。
            timerText
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
        case .expanded:
            timerText
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .font(.caption2)
                .lineLimit(1)
        case .compact:
            // 紧凑态宽度固定，避免倒计时文本长度变化时把岛继续撑宽。
            timerText
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    /// 使用原生区间倒计时；到点后不再继续显示计时文本，实际 activity 结束交给主 app 调度层处理。
    @ViewBuilder
    private var timerText: some View {
        if Date() < targetDate {
            Text(targetDate, style: .timer)
        } else {
            EmptyView()
        }
    }
}

/// Widget 渲染使用的统一条目。
///
/// 一个时间线条目里既可能有后续课程，也可能只有一条空态消息。
private struct ScheduleWidgetEntry: TimelineEntry {
    let date: Date
    let nextOccurrences: [ScheduleExternalOccurrence]
    let message: String?
}

/// 课表小组件的时间线提供器。
private struct ScheduleWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleWidgetEntry {
        ScheduleWidgetEntry(
            date: Date(),
            nextOccurrences: [
                ScheduleExternalOccurrence(
                    id: "preview-next",
                    title: "高等数学",
                    classroom: "理教201",
                    teacher: "张老师",
                    startDate: Date().addingTimeInterval(20 * 60),
                    endDate: Date().addingTimeInterval(110 * 60),
                    displayUntilDate: Date().addingTimeInterval(110 * 60)
                ),
                ScheduleExternalOccurrence(
                    id: "preview-later",
                    title: "大学英语",
                    classroom: "文萃302",
                    teacher: "李老师",
                    startDate: Date().addingTimeInterval(180 * 60),
                    endDate: Date().addingTimeInterval(260 * 60),
                    displayUntilDate: Date().addingTimeInterval(260 * 60)
                ),
            ],
            message: nil
        )
    }

    /// 供预览和系统快照使用的当前条目。
    func getSnapshot(in context: Context, completion: @escaping (ScheduleWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    /// 构造一条时间线；下一次刷新时间取决于最近课程的开始/切换节点。
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let refreshDate = nextRefreshDate(for: entry)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func loadEntry(now: Date = Date()) -> ScheduleWidgetEntry {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: 6)

        switch resolved.contentState {
        case .missing, .invalid:
            return emptyEntry(message: scheduleWidgetCampusNetworkMessage, date: now)
        case .loggedOut:
            return emptyEntry(message: scheduleWidgetLoginMessage, date: now)
        case .rest:
            return emptyEntry(message: scheduleWidgetRestMessage, date: now)
        case .ready:
            return ScheduleWidgetEntry(
                date: now,
                nextOccurrences: resolved.upcomingOccurrences,
                message: nil
            )
        }
    }

    /// 构造统一的空态条目，避免多处重复写空数组与同样的文案。
    private func emptyEntry(message: String, date: Date) -> ScheduleWidgetEntry {
        ScheduleWidgetEntry(
            date: date,
            nextOccurrences: [],
            message: message
        )
    }

    /// 计算 widget 下一次需要刷新的时间点。
    ///
    /// 优先在最近一节课的开始/切换节点刷新；没有课程时再走兜底刷新。
    private func nextRefreshDate(for entry: ScheduleWidgetEntry) -> Date {
        ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: entry.nextOccurrences,
            now: entry.date,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        )
    }
}

/// 课程表小组件主体。
///
/// 同一个 widget 同时支持桌面小组件与锁屏 accessory family。
struct BIT101ScheduleWidget: Widget {
    let kind = "BIT101ScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleWidgetProvider()) { entry in
            ScheduleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "bit101://schedule/courses"))
        }
        .configurationDisplayName("课程表")
        .description("查看下一节课，支持桌面和锁屏组件。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

/// 小组件视图。
///
/// 根据 family 分发到三套布局，但都复用同一份时间线条目。
private struct ScheduleWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ScheduleWidgetEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessoryRectangularBody
        case .accessoryInline:
            accessoryInlineBody
        case .accessoryCircular:
            accessoryCircularBody
        case .systemLarge:
            largeBody
        case .systemMedium:
            mediumBody
        default:
            smallBody
        }
    }

    /// 2x2 小号组件。
    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = entry.nextOccurrences.first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(first.isCurrent() ? "正在上课" : "下一节")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(first.relativeDayText())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text(first.rangeText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !first.classroom.isEmpty {
                        Text(first.classroom)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 锁屏长条组件。
    private var accessoryRectangularBody: some View {
        Group {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent() ? "正在上课" : "下一节")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(accessoryMetaText(for: first))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(accessoryEmptyText)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    /// 锁屏单行组件。
    private var accessoryInlineBody: some View {
        Group {
            if let first = entry.nextOccurrences.first {
                Text("\(first.isCurrent() ? "正在上课" : "下一节") \(first.title)")
                    .lineLimit(1)
            } else {
                Text(accessoryEmptyText)
                    .lineLimit(1)
            }
        }
    }

    /// 锁屏圆形组件。
    private var accessoryCircularBody: some View {
        ZStack {
            AccessoryWidgetBackground()

            if let first = entry.nextOccurrences.first {
                VStack(spacing: 1) {
                    Image(systemName: first.isCurrent() ? "play.circle.fill" : "calendar.badge.clock")
                        .font(.caption2)
                    Text(circularCountdownText(for: first))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            } else {
                VStack(spacing: 1) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(circularEmptyText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
            }
        }
    }

    /// 2x4 中号组件。
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent() ? "正在上课" : "下一节")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text("\(first.rangeText)\(first.classroom.isEmpty ? "" : " · \(first.classroom)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !entry.nextOccurrences.dropFirst().isEmpty {
                    Text("后续")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(entry.nextOccurrences.dropFirst().prefix(1))) { occurrence in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)

                                Text(occurrence.classroom)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text(occurrence.rangeText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 4x4 大号组件。
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(first.isCurrent() ? "正在上课" : "下一节")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Text(first.relativeDayText())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }

                    Text(first.title)
                        .font(.title3)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(first.rangeText)
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !first.classroom.isEmpty || !first.teacher.isEmpty {
                        Text(primaryMetaText(for: first))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !entry.nextOccurrences.dropFirst().isEmpty {
                    Text("后续")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(Array(entry.nextOccurrences.dropFirst().prefix(4))) { occurrence in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(occurrence.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)

                                    let meta = secondaryMetaText(for: occurrence)
                                    if !meta.isEmpty {
                                        Text(meta)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 0)

                                Text(occurrence.rangeText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                emptyState
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(0)
    }

    /// 大号组件主课的地点/老师摘要。
    private func primaryMetaText(for occurrence: ScheduleExternalOccurrence) -> String {
        if !occurrence.classroom.isEmpty && !occurrence.teacher.isEmpty {
            return "\(occurrence.classroom) · \(occurrence.teacher)"
        }
        if !occurrence.classroom.isEmpty {
            return occurrence.classroom
        }
        return occurrence.teacher
    }

    /// 后续课程的次级摘要。
    private func secondaryMetaText(for occurrence: ScheduleExternalOccurrence) -> String {
        if !occurrence.classroom.isEmpty {
            return occurrence.classroom
        }
        return occurrence.teacher
    }

    /// 锁屏长条组件的辅助摘要。
    private func accessoryMetaText(for occurrence: ScheduleExternalOccurrence) -> String {
        if !occurrence.classroom.isEmpty {
            return "\(occurrence.rangeText) \(occurrence.classroom)"
        }
        return occurrence.rangeText
    }

    /// 锁屏圆形组件里展示的分钟数倒计时。
    private func circularCountdownText(for occurrence: ScheduleExternalOccurrence) -> String {
        let target = occurrence.countdownTargetDate()
        let seconds = max(0, Int(target.timeIntervalSince(Date())))
        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "\(minutes)分"
    }

    /// 没有课表或后续无课时的统一空态。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.message ?? scheduleWidgetRestMessage)
                .font(.subheadline.weight(.medium))
            if entry.message == scheduleWidgetCampusNetworkMessage {
                Text("打开 App 同步课表后，这里会显示下一节课。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.message == scheduleWidgetLoginMessage {
                Text("登录后，这里会显示下一节课。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessoryEmptyText: String {
        switch entry.message {
        case scheduleWidgetLoginMessage:
            return scheduleWidgetLoginMessage
        case scheduleWidgetCampusNetworkMessage:
            return "请先同步课表"
        default:
            return "暂无课程"
        }
    }

    private var circularEmptyText: String {
        entry.message == scheduleWidgetLoginMessage ? scheduleWidgetLoginMessage : "无课"
    }
}
