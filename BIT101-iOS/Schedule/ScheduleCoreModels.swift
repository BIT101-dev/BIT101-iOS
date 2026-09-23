import Foundation

enum ScheduleSection: String, CaseIterable, Identifiable, Hashable {
    case courses
    case ddl
    case classroom

    /// 供分段控件和手势切换使用的稳定标识。
    var id: String { rawValue }

    /// 顶部分段控件展示的标题。
    var title: String {
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

/// 课程在周视图中的排布方式。
///
/// 按周显示是原有行为；全学期叠加用于快速查看一学期内固定时段的课程概览。
enum ScheduleDisplayMode: String, CaseIterable, Codable, Identifiable {
    case weekly
    case allWeeks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly:
            return "按周显示"
        case .allWeeks:
            return "全学期叠加"
        }
    }
}

/// 课程卡片在“名称”和“地点”之间切换的内容模式。
enum ScheduleCardContentMode: String, Codable, Identifiable {
    case nameAndLocation
    case name
    case location

    var id: String { rawValue }
}

/// 课表纵轴的时间表达方式。
enum ScheduleCalendarAxisMode: String, CaseIterable, Identifiable {
    case quantized
    case linear

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .quantized:
            return "简洁节次时间轴"
        case .linear:
            return "详细线性时间轴"
        }
    }

    var title: String {
        switch self {
        case .quantized:
            return "节次"
        case .linear:
            return "时间"
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

/// 节次与时间段的映射。
///
/// `TimeSlot` 是课表、空教室、当前时间线、小组件和灵动岛共同依赖的基础模型。
nonisolated struct TimeSlot: Codable, Hashable, Identifiable {
    let id: Int
    let start: String
    let end: String

    /// 节次开始时间对应的分钟数，便于当前时间线比较。
    var startMinutes: Int {
        TimeSlot.parseMinutes(start)
    }

    /// 节次结束时间对应的分钟数。
    var endMinutes: Int {
        TimeSlot.parseMinutes(end)
    }

    /// 节次区间的可读文本。
    var rangeText: String {
        "\(start)-\(end)"
    }

    /// 北理当前默认节次表。
    static let `default`: [TimeSlot] = [
        TimeSlot(id: 1, start: "08:00", end: "08:45"),
        TimeSlot(id: 2, start: "08:50", end: "09:35"),
        TimeSlot(id: 3, start: "09:55", end: "10:40"),
        TimeSlot(id: 4, start: "10:45", end: "11:30"),
        TimeSlot(id: 5, start: "11:35", end: "12:20"),
        TimeSlot(id: 6, start: "13:20", end: "14:05"),
        TimeSlot(id: 7, start: "14:10", end: "14:55"),
        TimeSlot(id: 8, start: "15:15", end: "16:00"),
        TimeSlot(id: 9, start: "16:05", end: "16:50"),
        TimeSlot(id: 10, start: "16:55", end: "17:40"),
        TimeSlot(id: 11, start: "18:30", end: "19:15"),
        TimeSlot(id: 12, start: "19:20", end: "20:05"),
        TimeSlot(id: 13, start: "20:10", end: "20:55"),
    ]

    /// 把 `HH:mm` 字符串解析成分钟数，支持 `24:00` 作为日界点。
    static func parseMinutes(_ string: String) -> Int {
        let parts = string.split(separator: ":")
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0 ... 23).contains(hour) || (hour == 24 && minute == 0),
            (0 ... 59).contains(minute)
        else {
            return 0
        }
        return hour * 60 + minute
    }

    /// 把分钟数格式化回 `HH:mm` 文本，最大值为 `24:00`。
    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 24 * 60)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// 课表课程记录。
///
/// 这是 iOS 端保存后的统一课程模型，教务接口、缓存、小组件、灵动岛都围绕它工作。
nonisolated struct CourseRecord: Codable, Identifiable, Hashable {
    let id: String
    let term: String
    let name: String
    let teacher: String
    let classroom: String
    let description: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
    let campus: String
    let number: String
    let credit: Double
    let hour: Int
    let type: String
    let category: String
    let department: String

    /// 课程占用的节次文本。
    var sectionText: String {
        "第\(startSection)-\(endSection)节"
    }

    var creditText: String {
        guard credit > 0 else { return "-" }
        if credit.rounded() == credit {
            return String(format: "%.0f", credit)
        }
        return String(format: "%.1f", credit)
    }

    /// 根据当前时间表配置，把节次映射成具体的起止时间。
    func timeText(using timeTable: [TimeSlot]) -> String {
        guard
            let start = timeTable.first(where: { $0.id == startSection }),
            let end = timeTable.first(where: { $0.id == endSection })
        else {
            return sectionText
        }

        return "\(start.start)-\(end.end)"
    }

    /// 只替换周次，供学校行解析和小学期整体校正共用。
    nonisolated func replacingWeeks(_ weeks: [Int]) -> CourseRecord {
        CourseRecord(
            id: id,
            term: term,
            name: name,
            teacher: teacher,
            classroom: classroom,
            description: description,
            weeks: weeks,
            weekday: weekday,
            startSection: startSection,
            endSection: endSection,
            campus: campus,
            number: number,
            credit: credit,
            hour: hour,
            type: type,
            category: category,
            department: department
        )
    }
}

/// 手动新增课程时使用的草稿模型。
///
/// 课程本体使用 `CourseRecord` 保存，草稿用于表单输入和本地校验。
struct CourseDraft: Equatable {
    var title = ""
    var teacher = ""
    var classroom = ""
    var buildingName = ""
    var roomNumber = ""
    var weekday = 1
    var startSection = 1
    var endSection = 2
    var weeksText = ""
    var selectedSections: [Int] = []
}

/// 课程本体的稳定身份，用于合并同一门课的多条排课记录。
nonisolated func scheduleCourseIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)|name:\(name)"
    }
    return "name:\(name)|teacher:\(course.teacher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

/// 同一门课在同一星期、同一节次的排课身份。
nonisolated func scheduleCourseArrangementIdentity(_ course: CourseRecord) -> String {
    let campus = course.campus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let classroom = course.classroom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(scheduleCourseIdentity(course))|weekday:\(course.weekday)|sections:\(course.startSection)-\(course.endSection)|campus:\(campus)|classroom:\(classroom)"
}

/// 课表刷新时用于定位同一门学校课程的稳定身份。
nonisolated func scheduleCourseSourceIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)"
    }
    return "name:\(course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

/// 比较学校课程来源数据，排除服务器记录 ID。
nonisolated func scheduleCourseSourceValue(_ course: CourseRecord) -> String {
    [
        course.term,
        course.name,
        course.teacher,
        course.classroom,
        course.description,
        course.weeks.sorted().map(String.init).joined(separator: ","),
        String(course.weekday),
        String(course.startSection),
        String(course.endSection),
        course.campus,
        course.number,
        course.credit.description,
        String(course.hour),
        course.type,
        course.category,
        course.department,
    ].joined(separator: "\u{001F}")
}

nonisolated func scheduleCourseSourceRecordsEqual(_ lhs: [CourseRecord], _ rhs: [CourseRecord]) -> Bool {
    lhs.map(scheduleCourseSourceValue).sorted() == rhs.map(scheduleCourseSourceValue).sorted()
}

nonisolated func scheduleCourseDisplayRecordsEqual(_ lhs: [CourseRecord], _ rhs: [CourseRecord]) -> Bool {
    lhs.map { "\($0.id)\u{001F}\(scheduleCourseSourceValue($0))" }.sorted()
        == rhs.map { "\($0.id)\u{001F}\(scheduleCourseSourceValue($0))" }.sorted()
}

/// 考试记录。
///
/// 考试数据用于课表页展示，模型保留完整字段，供扩展按需复用。
struct ExamRecord: Codable, Identifiable, Hashable {
    let id: String
    let term: String
    let name: String
    let courseID: String
    let teacher: String
    let classroom: String
    let dateString: String
    let beginTime: String
    let endTime: String
    let examMode: String
    let seatID: String
}

/// DDL 列表项。
///
/// 乐学同步数据和手动新建数据都使用这一种本地记录。
struct DDLEventRecord: Codable, Identifiable, Hashable {
    let id: String
    var group: String
    var title: String
    var text: String
    var dueAt: Date
    var done: Bool
}

/// 手动新增 / 编辑 DDL 时使用的草稿模型。
///
/// 草稿模型用于表单编辑过程。
struct DDLDraft: Equatable {
    var title = ""
    var dueAt = Date()
    var text = ""
}

/// 自定义课程块记录。
///
/// 用于补充学校接口之外的个人日程，也参与灵动岛“下一项”判断。
struct CustomScheduleRecord: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var description: String
    var dateString: String
    var beginTime: String
    var endTime: String
}

/// 自定义课程块编辑草稿。
struct CustomScheduleDraft: Equatable {
    var title = ""
    var subtitle = ""
    var description = ""
    var date = Date()
    var beginTime = Date()
    var endTime = Date()
}

/// 空教室查询使用的校区记录。
///
/// 这是服务端返回的元数据模型，仅驱动选择器。
struct CampusRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
}

/// 空教室查询使用的教学楼记录。
///
/// 教学楼记录会被缓存，并用于“根据下一节课教室自动匹配教学楼”的逻辑。
struct BuildingRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let buildingCode: String
    let campusName: String
    let campusCode: String
}

/// 空教室接口原始教室记录。
///
/// 原始记录只包含“哪些时间忙”，具体的中文空闲文案会在视图模型层再加工。
struct ClassroomRecord: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let busyTimeCodes: [Int]
}

/// 供界面展示的教室空闲状态。
///
/// 这是已经完成格式化、适合直接渲染到列表中的衍生模型。
struct ClassroomAvailability: Identifiable, Hashable {
    let id: String
    let name: String
    let prettyFreeTimes: String
    let statusText: String
    let detailText: String
    let isFreeNow: Bool
    let freeSections: [Int]
}
