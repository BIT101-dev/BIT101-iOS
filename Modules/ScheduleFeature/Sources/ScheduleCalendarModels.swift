import ScheduleDomain
import Foundation

/// 课表网格内部统一使用的条目类型。
///
/// 课程、考试和自定义日程统一投影为日历块，并分别使用对应的颜色和详情逻辑。
enum ScheduleCalendarKind {
    case course
    case exam
    case custom
}

/// 供课表网格渲染的统一条目模型。
///
/// 这是课表 UI 层内部的适配模型，数据生命周期止于展示流程。
struct ScheduleCalendarEntry: Identifiable {
    let id: String
    let sourceID: String
    /// 叠加模式下，一个格子可能对应多门课程；普通模式只有一个元素。
    let sourceIDs: [String]
    let dayOfWeek: Int
    let startSection: CGFloat
    let endSection: CGFloat
    let startMinutes: Int?
    let endMinutes: Int?
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
        startMinutes: Int? = nil,
        endMinutes: Int? = nil,
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
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
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

    func courseOccurrence(in courses: [CourseRecord], currentWeek: Int) -> (course: CourseRecord, week: Int)? {
        let sourceIDs = Set(resolvedSourceIDs)
        let candidates = courses.filter {
            sourceIDs.contains($0.id) && $0.weekday == dayOfWeek
                && CGFloat($0.startSection - 1) < endSection && CGFloat($0.endSection) > startSection
        }
        if let current = candidates.first(where: { $0.weeks.contains(currentWeek) }) { return (current, currentWeek) }
        guard let first = candidates.first(where: { $0.id == sourceID }) ?? candidates.first else { return nil }
        return (first, first.weeks.min() ?? currentWeek)
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
    convertMinutesToSection(minutes: TimeSlot.parseMinutes(timeText), timeTable: timeTable)
}

func convertMinutesToSection(minutes: Int, timeTable: [TimeSlot]) -> CGFloat {
    guard !timeTable.isEmpty else { return 0 }

    let sectionIndex = timeTable.firstIndex(where: { minutes <= $0.endMinutes }) ?? (timeTable.count - 1)
    let slot = timeTable[sectionIndex]
    let duration = max(slot.endMinutes - slot.startMinutes, 1)
    let rawRatio = CGFloat(minutes - slot.startMinutes) / CGFloat(duration)
    let ratio = min(max(rawRatio, 0), 1)
    return CGFloat(sectionIndex) + ratio
}

/// 根据首周日期计算课表页当前周次。
func resolvedCurrentWeek(firstDay: Date, now: Date = .now) -> Int {
    let start = ScheduleDateCodec.calendar.startOfDay(for: firstDay)
    let today = ScheduleDateCodec.calendar.startOfDay(for: now)
    let diff = ScheduleDateCodec.calendar.dateComponents([.day], from: start, to: today).day ?? 0
    return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
}

struct ScheduleCalendarPlacement: Identifiable {
    let entry: ScheduleCalendarEntry
    let column: Int
    let columnCount: Int
    var id: String { entry.id }
}

func quantizedCalendarGroups(entries: [ScheduleCalendarEntry]) -> (grid: [ScheduleCalendarEntry], outside: [ScheduleCalendarEntry]) {
    (entries.filter { $0.endSection > $0.startSection + 0.05 },
     entries.filter { $0.endSection <= $0.startSection + 0.05 })
}

/// 同日冲突条目并排展示，每个来源保留完整时间和详情入口。
func calendarPlacements(entries: [ScheduleCalendarEntry], separateOverlaps: Bool = true) -> [ScheduleCalendarPlacement] {
    guard separateOverlaps else { return entries.map { ScheduleCalendarPlacement(entry: $0, column: 0, columnCount: 1) } }
    let sorted = entries.sorted { lhs, rhs in
        if lhs.dayOfWeek != rhs.dayOfWeek {
            return lhs.dayOfWeek < rhs.dayOfWeek
        }
        if lhs.startSection != rhs.startSection {
            return lhs.startSection < rhs.startSection
        }
        if lhs.endSection != rhs.endSection {
            return lhs.endSection > rhs.endSection
        }
        return lhs.id < rhs.id
    }

    var result: [ScheduleCalendarPlacement] = []
    for day in 1 ... 7 {
        var cluster: [(entry: ScheduleCalendarEntry, column: Int)] = []
        var columnEnds: [CGFloat] = []
        var clusterEnd: CGFloat = 0
        func finishCluster() {
            result.append(contentsOf: cluster.map {
                ScheduleCalendarPlacement(entry: $0.entry, column: $0.column, columnCount: columnEnds.count)
            })
            cluster.removeAll(keepingCapacity: true)
            columnEnds.removeAll(keepingCapacity: true)
        }
        for entry in sorted where entry.dayOfWeek == day {
            if !cluster.isEmpty, entry.startSection >= clusterEnd {
                finishCluster()
            }
            let column: Int
            if let available = columnEnds.firstIndex(where: { $0 <= entry.startSection }) {
                column = available
                columnEnds[available] = entry.endSection
            } else {
                column = columnEnds.count
                columnEnds.append(entry.endSection)
            }
            cluster.append((entry, column))
            clusterEnd = cluster.count == 1 ? entry.endSection : max(clusterEnd, entry.endSection)
        }
        finishCluster()
    }

    return result
}
