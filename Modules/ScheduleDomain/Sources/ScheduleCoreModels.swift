import Foundation

/// 课程在周视图中的排布方式。
///
/// 按周显示是原有行为；全学期叠加用于快速查看一学期内固定时段的课程概览。
public nonisolated enum ScheduleDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case weekly
    case allWeeks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .weekly:
            return "按周显示"
        case .allWeeks:
            return "全学期叠加"
        }
    }
}

/// 课程卡片在“名称”和“地点”之间切换的内容模式。
public nonisolated enum ScheduleCardContentMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case nameAndLocation
    case name
    case location

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nameAndLocation:
            return "名称和地点"
        case .name:
            return "名称"
        case .location:
            return "地点"
        }
    }
}

/// 节次与时间段的映射。
///
/// `TimeSlot` 是课表、空教室、当前时间线、小组件和灵动岛共同依赖的基础模型。
public nonisolated struct TimeSlot: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let start: String
    public let end: String

    /// 节次开始时间对应的分钟数，便于当前时间线比较。
    public var startMinutes: Int {
        TimeSlot.parseMinutes(start)
    }

    /// 节次结束时间对应的分钟数。
    public var endMinutes: Int {
        TimeSlot.parseMinutes(end)
    }

    /// 节次区间的可读文本。
    public var rangeText: String {
        "\(start)-\(end)"
    }

    /// 北理当前默认节次表。
    public static let `default`: [TimeSlot] = [
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
    public static func parseMinutes(_ string: String) -> Int {
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
    public static func formatMinutes(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 24 * 60)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
    public init(id: Int, start: String, end: String) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// 课表课程记录。
///
/// 这是 iOS 端保存后的统一课程模型，教务接口、缓存、小组件、灵动岛都围绕它工作。
public nonisolated struct CourseRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let term: String
    public let name: String
    public let teacher: String
    public let classroom: String
    public let description: String
    public let weeks: [Int]
    public let weekday: Int
    public let startSection: Int
    public let endSection: Int
    public let campus: String
    public let number: String
    public let credit: Double
    public let hour: Int
    public let type: String
    public let category: String
    public let department: String

    /// 课程占用的节次文本。
    public var sectionText: String {
        "第\(startSection)-\(endSection)节"
    }

    public var creditText: String {
        guard credit > 0 else { return "-" }
        if credit.rounded() == credit {
            return String(format: "%.0f", credit)
        }
        return String(format: "%.1f", credit)
    }

    /// 根据当前时间表配置，把节次映射成具体的起止时间。
    public func timeText(using timeTable: [TimeSlot]) -> String {
        guard
            let start = timeTable.first(where: { $0.id == startSection }),
            let end = timeTable.first(where: { $0.id == endSection })
        else {
            return sectionText
        }

        return "\(start.start)-\(end.end)"
    }

    /// 只替换周次，供学校行解析和小学期整体校正共用。
    public nonisolated func replacingWeeks(_ weeks: [Int]) -> CourseRecord {
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
    public init(
        id: String,
        term: String,
        name: String,
        teacher: String,
        classroom: String,
        description: String,
        weeks: [Int],
        weekday: Int,
        startSection: Int,
        endSection: Int,
        campus: String,
        number: String,
        credit: Double,
        hour: Int,
        type: String,
        category: String,
        department: String
    ) {
        self.id = id
        self.term = term
        self.name = name
        self.teacher = teacher
        self.classroom = classroom
        self.description = description
        self.weeks = weeks
        self.weekday = weekday
        self.startSection = startSection
        self.endSection = endSection
        self.campus = campus
        self.number = number
        self.credit = credit
        self.hour = hour
        self.type = type
        self.category = category
        self.department = department
    }
}

/// 手动新增课程时使用的草稿模型。
///
/// 课程本体使用 `CourseRecord` 保存，草稿用于表单输入和本地校验。
public struct CourseDraft: Equatable {
    public var title = ""
    public var teacher = ""
    public var classroom = ""
    public var buildingName = ""
    public var roomNumber = ""
    public var weekday = 1
    public var startSection = 1
    public var endSection = 2
    public var weeksText = ""
    public var selectedSections: [Int] = []
    public init(
        title: String = "",
        teacher: String = "",
        classroom: String = "",
        buildingName: String = "",
        roomNumber: String = "",
        weekday: Int = 1,
        startSection: Int = 1,
        endSection: Int = 2,
        weeksText: String = "",
        selectedSections: [Int] = []
    ) {
        self.title = title
        self.teacher = teacher
        self.classroom = classroom
        self.buildingName = buildingName
        self.roomNumber = roomNumber
        self.weekday = weekday
        self.startSection = startSection
        self.endSection = endSection
        self.weeksText = weeksText
        self.selectedSections = selectedSections
    }
}

/// 课程本体的稳定身份，用于合并同一门课的多条排课记录。
public nonisolated func scheduleCourseIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)|name:\(name)"
    }
    return "name:\(name)|teacher:\(course.teacher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

/// 同一门课在同一星期、同一节次的排课身份。
public nonisolated func scheduleCourseArrangementIdentity(_ course: CourseRecord) -> String {
    let campus = course.campus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let classroom = course.classroom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return "\(scheduleCourseIdentity(course))|weekday:\(course.weekday)|sections:\(course.startSection)-\(course.endSection)|campus:\(campus)|classroom:\(classroom)"
}

/// 课表刷新时用于定位同一门学校课程的稳定身份。
public nonisolated func scheduleCourseSourceIdentity(_ course: CourseRecord) -> String {
    let number = course.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !number.isEmpty {
        return "number:\(number)"
    }
    return "name:\(course.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

/// 比较学校课程来源数据，排除服务器记录 ID。
public nonisolated func scheduleCourseSourceValue(_ course: CourseRecord) -> String {
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

public nonisolated func scheduleCourseSourceRecordsEqual(_ lhs: [CourseRecord], _ rhs: [CourseRecord]) -> Bool {
    lhs.map(scheduleCourseSourceValue).sorted() == rhs.map(scheduleCourseSourceValue).sorted()
}

public nonisolated func scheduleCourseDisplayRecordsEqual(_ lhs: [CourseRecord], _ rhs: [CourseRecord]) -> Bool {
    lhs.map { "\($0.id)\u{001F}\(scheduleCourseSourceValue($0))" }.sorted()
        == rhs.map { "\($0.id)\u{001F}\(scheduleCourseSourceValue($0))" }.sorted()
}

/// 考试记录。
///
/// 考试数据用于课表页展示，模型保留完整字段，供扩展按需复用。
public nonisolated struct ExamRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let term: String
    public let name: String
    public let courseID: String
    public let teacher: String
    public let classroom: String
    public let dateString: String
    public let beginTime: String
    public let endTime: String
    public let examMode: String
    public let seatID: String
    public init(
        id: String,
        term: String,
        name: String,
        courseID: String,
        teacher: String,
        classroom: String,
        dateString: String,
        beginTime: String,
        endTime: String,
        examMode: String,
        seatID: String
    ) {
        self.id = id
        self.term = term
        self.name = name
        self.courseID = courseID
        self.teacher = teacher
        self.classroom = classroom
        self.dateString = dateString
        self.beginTime = beginTime
        self.endTime = endTime
        self.examMode = examMode
        self.seatID = seatID
    }
}

/// DDL 列表项。
///
/// 乐学同步数据和手动新建数据都使用这一种本地记录。
public nonisolated struct DDLEventRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var group: String
    public var title: String
    public var text: String
    public var dueAt: Date
    public var done: Bool
    public var isSchoolSynced: Bool { group == "lexue" || group == "eclass" }
    public var sourceTitle: String {
        switch group {
        case "lexue": "乐学"
        case "eclass": "课程中心"
        default: "自定义"
        }
    }
    public init(id: String, group: String, title: String, text: String, dueAt: Date, done: Bool) {
        self.id = id
        self.group = group
        self.title = title
        self.text = text
        self.dueAt = dueAt
        self.done = done
    }
}

/// 手动新增 / 编辑 DDL 时使用的草稿模型。
///
/// 草稿模型用于表单编辑过程。
public struct DDLDraft: Equatable {
    public var title = ""
    public var dueAt = Date()
    public var text = ""
    public init(title: String = "", dueAt: Date = Date(), text: String = "") {
        self.title = title
        self.dueAt = dueAt
        self.text = text
    }
}

/// 自定义课程块记录。
///
/// 用于补充学校接口之外的个人日程，也参与灵动岛“下一项”判断。
public nonisolated struct CustomScheduleRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String
    public var description: String
    public var dateString: String
    public var beginTime: String
    public var endTime: String
    public init(id: String, title: String, subtitle: String, description: String, dateString: String, beginTime: String, endTime: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.dateString = dateString
        self.beginTime = beginTime
        self.endTime = endTime
    }
}

/// 自定义课程块编辑草稿。
public struct CustomScheduleDraft: Equatable {
    public var title = ""
    public var subtitle = ""
    public var description = ""
    public var date = Date()
    public var beginTime = Date()
    public var endTime = Date()
    public init(
        title: String = "",
        subtitle: String = "",
        description: String = "",
        date: Date = Date(),
        beginTime: Date = Date(),
        endTime: Date = Date()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.date = date
        self.beginTime = beginTime
        self.endTime = endTime
    }
}

/// 空教室查询使用的校区记录。
///
/// 这是服务端返回的元数据模型，仅驱动选择器。
public nonisolated struct CampusRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    public init(id: String, name: String, code: String) {
        self.id = id
        self.name = name
        self.code = code
    }
}

/// 空教室查询使用的教学楼记录。
///
/// 教学楼记录会被缓存，并用于“根据下一节课教室自动匹配教学楼”的逻辑。
public nonisolated struct BuildingRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let buildingCode: String
    public let campusName: String
    public let campusCode: String
    public init(id: String, name: String, buildingCode: String, campusName: String, campusCode: String) {
        self.id = id
        self.name = name
        self.buildingCode = buildingCode
        self.campusName = campusName
        self.campusCode = campusCode
    }
}

/// 空教室接口原始教室记录。
///
/// 原始记录只包含“哪些时间忙”，具体的中文空闲文案会在视图模型层再加工。
public nonisolated struct ClassroomRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let busyTimeCodes: [Int]
    public init(id: String, name: String, busyTimeCodes: [Int]) {
        self.id = id
        self.name = name
        self.busyTimeCodes = busyTimeCodes
    }
}

/// 供界面展示的教室空闲状态。
///
/// 这是已经完成格式化、适合直接渲染到列表中的衍生模型。
public nonisolated struct ClassroomAvailability: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let prettyFreeTimes: String
    public let statusText: String
    public let isFreeNow: Bool
    public let freeSections: [Int]
    public init(id: String, name: String, prettyFreeTimes: String, statusText: String, isFreeNow: Bool, freeSections: [Int]) {
        self.id = id
        self.name = name
        self.prettyFreeTimes = prettyFreeTimes
        self.statusText = statusText
        self.isFreeNow = isFreeNow
        self.freeSections = freeSections
    }
}
