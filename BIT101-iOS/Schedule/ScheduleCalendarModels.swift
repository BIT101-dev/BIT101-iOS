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
        Double((startSection + endSection) / 2)
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
func resolvedCurrentWeek(firstDay: Date) -> Int {
    let start = ScheduleDateCodec.calendar.startOfDay(for: firstDay)
    let today = ScheduleDateCodec.calendar.startOfDay(for: Date())
    let diff = ScheduleDateCodec.calendar.dateComponents([.day], from: start, to: today).day ?? 0
    return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
}

/// 处理同一天中互相重叠的日历块，为先前条目保留可见区域。
func normalize(entries: [ScheduleCalendarEntry]) -> [ScheduleCalendarEntry] {
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

    var result: [ScheduleCalendarEntry] = []

    for day in 1 ... 7 {
        var dayEntries: [ScheduleCalendarEntry] = []
        for entry in sorted where entry.dayOfWeek == day {
            if let last = dayEntries.last, last.endSection > entry.startSection {
                if last.endSection < entry.endSection {
                    let trimmedStart = last.endSection
                    let trimmedEnd = entry.endSection
                    let trimmedLayers = entry.backgroundLayers.compactMap { layer -> ScheduleCalendarLayer? in
                        let startSection = max(layer.startSection, trimmedStart)
                        let endSection = min(layer.endSection, trimmedEnd)
                        guard endSection > startSection else { return nil }
                        return ScheduleCalendarLayer(
                            id: layer.id,
                            startSection: startSection,
                            endSection: endSection
                        )
                    }
                    dayEntries.append(
                        ScheduleCalendarEntry(
                            id: "\(entry.id)-trim-\(last.endSection)",
                            sourceID: entry.sourceID,
                            sourceIDs: entry.resolvedSourceIDs,
                            dayOfWeek: entry.dayOfWeek,
                            startSection: trimmedStart,
                            endSection: trimmedEnd,
                            startMinutes: entry.startMinutes,
                            endMinutes: entry.endMinutes,
                            title: entry.title,
                            subtitle: entry.subtitle,
                            detailLines: entry.detailLines,
                            kind: entry.kind,
                            backgroundLayers: trimmedLayers
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
