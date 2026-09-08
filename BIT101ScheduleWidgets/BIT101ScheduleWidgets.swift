import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private let scheduleWidgetSyncMessage = "请先获取课表"
private let scheduleWidgetInvalidMessage = "请重新同步课表"
private let scheduleWidgetLoginMessage = "请登录"
private let scheduleWidgetRestMessage = "暂无后续课程"

/// 课程提醒 Live Activity 配置。
///
/// 锁屏态展示完整提醒信息；灵动岛提供三种展示：
/// - `expanded`：左侧显示提醒类型，右侧显示倒计时
/// - `compact`：显示提醒类型和倒计时
/// - `minimal`：显示系统图标
/// 倒计时文本直接绑定目标时刻，由系统驱动更新。
@available(iOSApplicationExtension 16.2, *)
struct CourseReminderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseReminderActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.liveActivityCard) {
                HStack(alignment: .firstTextBaseline, spacing: ScheduleExternalDesignSystem.Spacing.liveActivityHeader) {
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
            .padding(ScheduleExternalDesignSystem.Size.liveActivityContent)
            .activityBackgroundTint(.clear)
            // 锁屏内容区域需要单独声明 widgetURL，点击后返回主 App。
            .widgetURL(URL(string: "bit101://schedule/courses"))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态左侧展示提醒类型。
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.kindText)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.leading, ScheduleExternalDesignSystem.Spacing.liveActivityRegion)
                }
                // 展开态右侧展示倒计时。
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityTimerText(
                        targetDate: context.state.countdownTargetDate,
                        style: .expanded
                    )
                    .padding(.trailing, ScheduleExternalDesignSystem.Spacing.liveActivityRegion)
                }
                // 展开态中间展示单行标题。
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                // 展开态底部展示时间段、地点和老师摘要。
                DynamicIslandExpandedRegion(.bottom) {
                    Text(liveActivityExpandedSummaryText(for: context.state))
                        .font(.headline)
                        .lineLimit(1)
                }
            } compactLeading: {
                // 紧凑态左侧展示提醒类型。
                Text(context.state.kindText)
                    .font(.caption)
                    .lineLimit(1)
            } compactTrailing: {
                // 紧凑态右侧展示倒计时。
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

/// Live Activity 使用的计时视图。
///
/// 视图在课前窗口显示到开始时间的倒计时；activity 结束由主 App 调度层处理。
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
            timerText
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
        case .expanded:
            timerText
                .multilineTextAlignment(.trailing)
                .frame(width: ScheduleExternalDesignSystem.Size.liveActivityExpandedTimerWidth)
                .font(.caption2)
                .lineLimit(1)
        case .compact:
            // 紧凑态保持固定宽度，倒计时文本长度变化时维持 Dynamic Island 宽度。
            timerText
                .multilineTextAlignment(.center)
                .frame(width: ScheduleExternalDesignSystem.Size.liveActivityCompactTimerWidth)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    /// 使用原生倒计时文本；目标时刻到达后由 activity 调度层结束提醒。
    @ViewBuilder
    private var timerText: some View {
        Text(targetDate, style: .timer)
    }
}

/// Widget 时间线使用的条目。
private struct ScheduleWidgetEntry: TimelineEntry {
    let date: Date
    let nextOccurrences: [ScheduleExternalOccurrence]
    let message: String?
}

/// 课表小组件的时间线提供器。
private struct ScheduleWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> ScheduleWidgetEntry {
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

    /// 提供预览和系统快照使用的当前条目。
    func getSnapshot(in _: Context, completion: @escaping (ScheduleWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    /// 构造时间线；下一次刷新时间取决于最近课程的开始和切换节点。
    func getTimeline(in _: Context, completion: @escaping (Timeline<ScheduleWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let refreshDate = nextRefreshDate(for: entry)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func loadEntry(now: Date = Date()) -> ScheduleWidgetEntry {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: 6)

        switch resolved.contentState {
        case .missing:
            return emptyEntry(message: scheduleWidgetSyncMessage, date: now)
        case .invalid:
            return emptyEntry(message: scheduleWidgetInvalidMessage, date: now)
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

    /// 构造统一的空态条目。
    private func emptyEntry(message: String, date: Date) -> ScheduleWidgetEntry {
        ScheduleWidgetEntry(
            date: date,
            nextOccurrences: [],
            message: message
        )
    }

    /// 计算 widget 下一次刷新时间。
    private func nextRefreshDate(for entry: ScheduleWidgetEntry) -> Date {
        ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: entry.nextOccurrences,
            now: entry.date,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        )
    }
}

/// 课程表小组件主体，支持桌面小组件与锁屏 accessory family。
struct BIT101ScheduleWidgets: Widget {
    let kind = "BIT101ScheduleWidgets"

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

/// 根据 family 分发布局，并复用同一份时间线条目。
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

    private func courseStatusText(for occurrence: ScheduleExternalOccurrence) -> String {
        occurrence.isCurrent() ? "正在上课" : "下一节"
    }

    @ViewBuilder
    private func scheduleHeader(for occurrence: ScheduleExternalOccurrence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ScheduleExternalDesignSystem.Spacing.widgetHeader) {
            Text(courseStatusText(for: occurrence))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(occurrence.relativeDayText())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
    }

    /// 2x2 小号组件。
    private var smallBody: some View {
        VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetSmallContent) {
            if let first = entry.nextOccurrences.first {
                scheduleHeader(for: first)

                VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetSmallContent) {
                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetSmallTitle)

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
    }

    /// 锁屏长条组件。
    @ViewBuilder
    private var accessoryRectangularBody: some View {
        if let first = entry.nextOccurrences.first {
            VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetAccessoryContent) {
                HStack(alignment: .firstTextBaseline, spacing: ScheduleExternalDesignSystem.Spacing.widgetAccessoryHeader) {
                    Text(courseStatusText(for: first))
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

    /// 锁屏单行组件。
    @ViewBuilder
    private var accessoryInlineBody: some View {
        if let first = entry.nextOccurrences.first {
            Text("\(courseStatusText(for: first)) \(first.title)")
                .lineLimit(1)
        } else {
            Text(accessoryEmptyText)
                .lineLimit(1)
        }
    }

    /// 锁屏圆形组件。
    private var accessoryCircularBody: some View {
        ZStack {
            AccessoryWidgetBackground()

            if let first = entry.nextOccurrences.first {
                VStack(spacing: ScheduleExternalDesignSystem.Spacing.widgetCircular) {
                    Image(systemName: first.isCurrent() ? "play.circle.fill" : "calendar.badge.clock")
                        .font(.caption2)
                    Text(circularCountdownText(for: first))
                        .font(.system(size: ScheduleExternalDesignSystem.Typography.widgetCircularCount, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetCircularCount)
                }
            } else {
                VStack(spacing: ScheduleExternalDesignSystem.Spacing.widgetCircular) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(circularEmptyText)
                        .font(.system(size: ScheduleExternalDesignSystem.Typography.widgetCircularEmpty, weight: .medium, design: .rounded))
                }
            }
        }
    }

    /// 2x4 中号组件。
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetMediumContent) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetMediumMain) {
                    scheduleHeader(for: first)

                    Text(first.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetMediumTitle)

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
                        HStack(spacing: ScheduleExternalDesignSystem.Spacing.widgetMediumMain) {
                            VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetFollowUp) {
                                Text(occurrence.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetMediumTitle)

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
    }

    /// 4x4 大号组件。
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetLargeContent) {
            if let first = entry.nextOccurrences.first {
                VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetLargeMain) {
                    scheduleHeader(for: first)

                    Text(first.title)
                        .font(.title3)
                        .lineLimit(2)
                        .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetLargeTitle)

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

                    VStack(spacing: ScheduleExternalDesignSystem.Spacing.widgetLargeFollowUp) {
                        ForEach(Array(entry.nextOccurrences.dropFirst().prefix(4))) { occurrence in
                            HStack(spacing: ScheduleExternalDesignSystem.Spacing.widgetLargeFollowUp) {
                                VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetFollowUp) {
                                    Text(occurrence.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(ScheduleExternalDesignSystem.Scale.widgetLargeTitle)

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
    }

    /// 大号组件主课的地点和老师摘要。
    private func primaryMetaText(for occurrence: ScheduleExternalOccurrence) -> String {
        if !occurrence.classroom.isEmpty && !occurrence.teacher.isEmpty {
            return "\(occurrence.classroom) · \(occurrence.teacher)"
        }
        if !occurrence.classroom.isEmpty {
            return occurrence.classroom
        }
        return occurrence.teacher
    }

    /// 后续课程的地点和老师摘要。
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

    /// 锁屏圆形组件展示分钟数倒计时。
    private func circularCountdownText(for occurrence: ScheduleExternalOccurrence) -> String {
        let target = occurrence.countdownTargetDate()
        let seconds = max(0, Int(target.timeIntervalSince(Date())))
        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        return "\(minutes)分"
    }

    /// 课表为空或后续课程为空时显示统一空态。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: ScheduleExternalDesignSystem.Spacing.widgetEmpty) {
            Text(entry.message ?? scheduleWidgetRestMessage)
                .font(.subheadline.weight(.medium))
            if entry.message == scheduleWidgetSyncMessage {
                Text("打开 App 同步课表后，这里会显示下一节课。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.message == scheduleWidgetInvalidMessage {
                Text("打开 App 重新同步课表后，这里会显示下一节课。")
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
        case scheduleWidgetSyncMessage:
            return "请先同步课表"
        case scheduleWidgetInvalidMessage:
            return "请重新同步"
        default:
            return "暂无课程"
        }
    }

    private var circularEmptyText: String {
        switch entry.message {
        case scheduleWidgetLoginMessage:
            return scheduleWidgetLoginMessage
        case scheduleWidgetInvalidMessage:
            return "重同步"
        default:
            return "无课"
        }
    }
}
