import DesignSystemKit
import ScheduleDomain
import Foundation

/// 设置页消费的课表配置与名称快照。
public nonisolated struct ScheduleSettingsSnapshot {
    public nonisolated struct SharedSchedule: Identifiable {
        public let id: String
        public let title: String
    }

    public let currentTerm: String
    public let firstDayString: String
    public let firstDay: Date?
    public let schoolFirstDay: Date?
    public let timeTableText: String
    public let primaryScheduleTitle: String
    public let sharedSchedules: [SharedSchedule]
    public let hasCourses: Bool
    public let iCloudSyncEnabled: Bool
    public let courseLiveActivityLeadMinutes: Int
    public let scheduleDisplayMode: ScheduleDisplayMode
    public let scheduleCardContentMode: ScheduleCardContentMode
    public let showSaturday: Bool
    public let showSunday: Bool
    public let showExamInfo: Bool
    public let showCourseLiveActivityReminder: Bool

    init(courses: ScheduleCourseState, preferences: SchedulePresentationPreferences, sync: ScheduleSyncState) {
        currentTerm = courses.currentTerm
        firstDayString = courses.firstDayString
        firstDay = courses.firstDay
        schoolFirstDay = courses.termSchedulesByTerm[courses.currentTerm]?.firstDay
        timeTableText = courses.timeTable.map { "\($0.start), \($0.end)" }.joined(separator: "\n")
        primaryScheduleTitle = courses.primaryScheduleTitle
        sharedSchedules = courses.sharedSchedules.map { SharedSchedule(id: $0.id, title: $0.title) }
        hasCourses = !courses.courses.isEmpty
        iCloudSyncEnabled = sync.iCloudSyncEnabled
        courseLiveActivityLeadMinutes = preferences.courseLiveActivityLeadMinutes
        scheduleDisplayMode = preferences.scheduleDisplayMode
        scheduleCardContentMode = preferences.scheduleCardContentMode
        showSaturday = preferences.showSaturday
        showSunday = preferences.showSunday
        showExamInfo = preferences.showExamInfo
        showCourseLiveActivityReminder = preferences.showCourseLiveActivityReminder
    }
}

public nonisolated enum ScheduleSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case courses
    case ddl
    case classroom

    /// 供分段控件和手势切换使用的稳定标识。
    public var id: String { rawValue }

    /// 顶部分段控件展示的标题。
    public var title: String {
        switch self {
        case .courses:
            return "课表"
        case .ddl:
            return "DDL"
        case .classroom:
            return "空教室"
        }
    }
}

/// 课表纵轴的时间表达方式。
public nonisolated enum ScheduleCalendarAxisMode: String, CaseIterable, Identifiable, Sendable {
    case quantized
    case linear

    public var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .quantized:
            return "简洁节次时间轴"
        case .linear:
            return "详细线性时间轴"
        }
    }

    public var title: String {
        switch self {
        case .quantized:
            return "节次"
        case .linear:
            return "线性"
        }
    }

    var next: Self {
        switch self {
        case .quantized:
            return .linear
        case .linear:
            return .quantized
        }
    }
}

/// 线性时间轴的缩放与滚动几何模型。
#if os(iOS)
struct ScheduleTimelineViewport: Equatable {
    static var minimumScale: CGFloat { AppDesignSystem.Schedule.timelineMinimumScale }
    static var maximumScale: CGFloat { AppDesignSystem.Schedule.timelineMaximumScale }

    let viewportHeight: CGFloat
    let scale: CGFloat
    let offsetY: CGFloat

    init(viewportHeight: CGFloat, scale: CGFloat, offsetY: CGFloat) {
        self.viewportHeight = max(viewportHeight, 0)
        self.scale = Self.clampedScale(scale)
        self.offsetY = Self.clampedOffset(
            offsetY,
            viewportHeight: self.viewportHeight,
            scale: self.scale
        )
    }

    var contentHeight: CGFloat {
        viewportHeight * scale
    }

    static func initial(
        viewportHeight: CGFloat,
        scale: CGFloat,
        currentMinute: Int
    ) -> Self {
        let resolvedScale = clampedScale(scale)
        let contentHeight = max(viewportHeight, 0) * resolvedScale
        let minute = min(max(currentMinute, 0), 24 * 60)
        let offset = CGFloat(minute) / CGFloat(24 * 60) * contentHeight - viewportHeight / 2
        return Self(viewportHeight: viewportHeight, scale: resolvedScale, offsetY: offset)
    }

    func zoomed(
        to proposedScale: CGFloat,
        initialAnchorY: CGFloat,
        currentAnchorY: CGFloat
    ) -> Self {
        guard contentHeight > 0 else {
            return Self(viewportHeight: viewportHeight, scale: proposedScale, offsetY: 0)
        }
        let anchorY = min(max(initialAnchorY, 0), viewportHeight)
        let currentY = min(max(currentAnchorY, 0), viewportHeight)
        let anchoredRatio = (offsetY + anchorY) / contentHeight
        let resolvedScale = Self.clampedScale(proposedScale)
        let nextContentHeight = viewportHeight * resolvedScale
        return Self(
            viewportHeight: viewportHeight,
            scale: resolvedScale,
            offsetY: anchoredRatio * nextContentHeight - currentY
        )
    }

    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }

    private static func clampedOffset(
        _ value: CGFloat,
        viewportHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        min(max(value, 0), max(viewportHeight * scale - viewportHeight, 0))
    }
}

#endif
