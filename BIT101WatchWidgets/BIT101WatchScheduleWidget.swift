import SwiftUI
import WidgetKit

/// 镜像同步前使用的提示文案。
private let watchScheduleWidgetSyncMessage = "打开手机 App 同步课表"
/// Watch 端需要登录时使用的提示文案。
private let watchScheduleWidgetLoginMessage = "请先登录"
/// 后续课程为空时使用的提示文案。
private let watchScheduleWidgetRestMessage = "暂无后续课程"

/// Apple Watch complication 的时间线条目。
private struct WatchScheduleEntry: TimelineEntry {
    let date: Date
    let nextOccurrence: ScheduleExternalOccurrence?
    let message: String?
}

/// Apple Watch complication 使用的展示摘要。
private struct WatchScheduleDisplaySummary {
    let location: ScheduleCompactLocation
    let startTimeText: String
    let rangeText: String
    let dateText: String
    let courseTitle: String
    let inlineText: String

    init(occurrence: ScheduleExternalOccurrence) {
        let rawLocation = occurrence.classroom.isEmpty ? occurrence.title : occurrence.classroom
        let compactLocation = ScheduleDisplayNormalizer.compactLocation(for: rawLocation)
        let courseTitle = occurrence.classroom.isEmpty ? "" : occurrence.title
        let startTimeText = ScheduleSharedDateCodec.formatTime(occurrence.startDate)
        let dateText = occurrence.relativeDayText()

        self.location = compactLocation
        self.startTimeText = startTimeText
        self.rangeText = occurrence.rangeText
        self.dateText = dateText
        self.courseTitle = courseTitle

        self.inlineText = [compactLocation.maxText, startTimeText, dateText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private enum WatchScheduleEntryStatus {
    case sync
    case loggedOut
    case rest

    init(message: String?) {
        switch message {
        case watchScheduleWidgetSyncMessage:
            self = .sync
        case watchScheduleWidgetLoginMessage:
            self = .loggedOut
        default:
            self = .rest
        }
    }

    var circularText: String {
        switch self {
        case .sync:
            return "同步"
        case .loggedOut:
            return "登录"
        case .rest:
            return "无课"
        }
    }

    var cornerText: String {
        switch self {
        case .sync:
            return "待同步"
        case .loggedOut:
            return "未登录"
        case .rest:
            return "无课"
        }
    }
}

private extension WatchScheduleEntry {
    var displaySummary: WatchScheduleDisplaySummary? {
        guard let nextOccurrence else { return nil }
        return WatchScheduleDisplaySummary(occurrence: nextOccurrence)
    }

    var status: WatchScheduleEntryStatus {
        WatchScheduleEntryStatus(message: message)
    }
}

/// 把共享快照转换为 Apple Watch widget 时间线。
private struct WatchScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchScheduleEntry {
        let now = Date()
        return WatchScheduleEntry(
            date: now,
            nextOccurrence: ScheduleExternalOccurrence(
                id: "preview",
                title: "高等数学",
                classroom: "综合教学楼A101",
                teacher: "张老师",
                startDate: now.addingTimeInterval(20 * 60),
                endDate: now.addingTimeInterval(110 * 60),
                displayUntilDate: now.addingTimeInterval(110 * 60)
            ),
            message: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchScheduleEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchScheduleEntry>) -> Void) {
        let entry = loadEntry()
        let refreshDate = nextRefreshDate(for: entry)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    /// 从共享快照生成当前条目。
    ///
    /// 时间线以当前时刻之后的课程作为展示对象。
    private func loadEntry(now: Date = Date()) -> WatchScheduleEntry {
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(now: now, limit: 32)

        switch resolved.contentState {
        case .missing, .invalid:
            return WatchScheduleEntry(date: now, nextOccurrence: nil, message: watchScheduleWidgetSyncMessage)
        case .loggedOut:
            return WatchScheduleEntry(date: now, nextOccurrence: nil, message: watchScheduleWidgetLoginMessage)
        case .rest:
            return WatchScheduleEntry(date: now, nextOccurrence: nil, message: watchScheduleWidgetRestMessage)
        case .ready:
            let nextOccurrence = resolved.upcomingOccurrences.first(where: { $0.startDate > now })
            return WatchScheduleEntry(
                date: now,
                nextOccurrence: nextOccurrence,
                message: nextOccurrence == nil ? watchScheduleWidgetRestMessage : nil
            )
        }
    }

    /// 时间线在课程开始和跨日时刷新。
    ///
    /// 晚间条目显示“明天 8:00”时，时间线若等到 8:00 才刷新，
    /// 午夜到上课前会继续显示“明天”。因此下一个午夜也作为刷新点，
    /// 让 Watch 离开手机时继续用本地镜像把“明天”更新为“今天”。
    private func nextRefreshDate(for entry: WatchScheduleEntry) -> Date {
        ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: entry.nextOccurrence.map { [$0] } ?? [],
            now: entry.date,
            includeDisplayUntilDates: false,
            includeNextMidnight: true
        )
    }
}

/// 提供 Apple Watch complication 和 Smart Stack 课表卡片。
struct BIT101WatchScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BIT101WatchScheduleWidget", provider: WatchScheduleProvider()) { entry in
            WatchScheduleEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("课表")
        .description("在表盘或 Smart Stack 里查看下一节课。")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner,
            .accessoryRectangular,
        ])
    }
}

/// 按 widget family 分发 complication 视图。
private struct WatchScheduleEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WatchScheduleEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchScheduleCircularView(entry: entry)
        case .accessoryCorner:
            WatchScheduleCornerView(entry: entry)
        case .accessoryInline:
            WatchScheduleInlineView(entry: entry)
        case .accessoryRectangular:
            WatchScheduleRectangularView(entry: entry)
        @unknown default:
            WatchScheduleRectangularView(entry: entry)
        }
    }
}

private struct WatchScheduleCircularView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            VStack(spacing: 0) {
                Text(summary.location.maxBuilding)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(summary.location.room ?? " ")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
            .multilineTextAlignment(.center)
        } else {
            Text(entry.status.circularText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
        }
    }
}

private struct WatchScheduleCornerView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            Text(summary.location.maxText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .widgetCurvesContent()
                .widgetLabel {
                    Text("\(summary.dateText) \(summary.rangeText)")
                }
        } else {
            Text(entry.status.cornerText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

private struct WatchScheduleInlineView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            Text(summary.inlineText)
        } else {
            Text(entry.message ?? watchScheduleWidgetRestMessage)
        }
    }
}

private struct WatchScheduleRectangularView: View {
    let entry: WatchScheduleEntry

    var body: some View {
        if let summary = entry.displaySummary {
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline) {
                    Text("下一节")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(summary.dateText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(summary.courseTitle.isEmpty ? summary.location.lightText : summary.courseTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(alignment: .firstTextBaseline) {
                    Text(summary.rangeText)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 4)

                    Text(summary.location.lightText)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        } else {
            VStack(alignment: .leading) {
                Text(entry.message ?? watchScheduleWidgetRestMessage)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if case .sync = entry.status {
                    Text("先打开手机 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
