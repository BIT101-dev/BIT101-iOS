//
//  ScheduleModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 课表名称的统一长度上限。
///
/// 这一上限同时约束：
/// - 设置页里的重命名输入
/// - 导入分享课表后的默认命名
/// - 旧缓存恢复后的标题展示
nonisolated let scheduleNameCharacterLimit = 8

/// 本地缓存发生变化时发出的通知。
///
/// 课表页、小组件导出和灵动岛刷新都会监听这条通知，用来做跨模块同步。
extension Notification.Name {
    static let scheduleCacheDidChange = Notification.Name("BIT101.ScheduleCacheDidChange")
}

/// 日程页的一级分栏。
///
/// 课表、DDL、空教室虽然都挂在“日程”一级页签下，但数据来源和容器差异很大，
/// 所以先用统一枚举收敛它们的切换语义。
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

    /// 把 `HH:mm` 字符串解析成分钟数。
    static func parseMinutes(_ string: String) -> Int {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return 0
        }
        return hour * 60 + minute
    }

    /// 把分钟数格式化回 `HH:mm` 文本。
    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = max(minutes, 0)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// 课表课程记录。
///
/// 这是 iOS 端落盘后的统一课程模型，教务接口、缓存、小组件、灵动岛都围绕它工作。
struct CourseRecord: Codable, Identifiable, Hashable {
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
    let credit: Int
    let hour: Int
    let type: String
    let category: String
    let department: String

    /// 课程占用的节次文本。
    var sectionText: String {
        "第\(startSection)-\(endSection)节"
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
}

/// 手动新增课程时使用的草稿模型。
///
/// 课程本体仍然落成 `CourseRecord`，草稿只服务于表单输入和本地校验。
struct CourseDraft: Equatable {
    var title = ""
    var teacher = ""
    var classroom = ""
    var weekday = 1
    var startSection = 1
    var endSection = 2
    var weeksText = ""
}

/// 考试记录。
///
/// 当前考试数据主要在课表页下方和锁屏/桌面未来扩展中复用，所以保留完整字段。
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
/// 乐学同步数据和手动新建数据都落成这一种本地记录。
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
/// 草稿模型不直接落盘，只服务于表单编辑过程。
struct DDLDraft: Equatable {
    var title = ""
    var dueAt = Date()
    var text = ""
}

/// 自定义课程块记录。
///
/// 用于补充学校接口之外的个人日程，后续也会参与灵动岛“下一项”判断。
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
/// 这是服务端返回的元数据模型，不直接参与排课运算，只负责驱动选择器。
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

/// 日程模块本地缓存。
///
/// 这是 iOS 端整个日程模块的单一持久化快照：
/// - 课表
/// - 考试
/// - DDL
/// - 自定义日程
/// - 空教室偏好
/// - 课表显示设置
/// - 灵动岛提醒设置
nonisolated struct ScheduleCache: Codable {
    var primaryScheduleTitle = "课表"
    var currentTerm: String = ""
    var firstDayString: String = ""
    /// 最近一次从学校成功同步课表与考试的时间，用于缓存迁移和快照时间戳。
    var coursesUpdatedAt: Date = .distantPast
    var lexueCalendarURL: String = ""
    var courses: [CourseRecord] = []
    /// 已成功同步过的各学期课表快照，供成绩页本地判断尚未出分的课程。
    var cachedCoursesByTerm: [String: [CourseRecord]] = [:]
    /// Current and next semester as complete, already-converted offline snapshots.
    var termSchedulesByTerm: [String: TermScheduleSnapshot] = [:]
    var exams: [ExamRecord] = []
    var customSchedules: [CustomScheduleRecord] = []
    var ddlEvents: [DDLEventRecord] = []
    /// 最近一次成功同步乐学 DDL 的时间；为空表示尚未成功同步。
    var ddlUpdatedAt: Date?
    var ddlBeforeDay = 7
    var ddlAfterDay = 3
    var selectedCampusName: String = ""
    var selectedCampusCode: String = ""
    var selectedBuildingID: String = ""
    var cachedClassroomCampuses: [CampusRecord] = []
    var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]] = [:]
    var selectedClassroomSectionIDs: [Int] = []
    var showSaturday = true
    var showSunday = true
    var showBorder = true
    var showHighlightToday = true
    var showDivider = true
    var showCurrentTime = true
    var showExamInfo = true
    var scheduleDisplayMode: ScheduleDisplayMode = .weekly
    var scheduleCardContentMode: ScheduleCardContentMode = .nameAndLocation
    var showCourseLiveActivityReminder = false
    var courseLiveActivityLeadMinutes = 20
    var timeTable: [TimeSlot] = TimeSlot.default
    var sharedSchedules: [SharedScheduleRecord] = []
    var iCloudSyncEnabled = true
    var updatedAt: Date = .distantPast

    /// 首周日期的解码结果，便于课表直接计算当前周数。
    var firstDay: Date? {
        Self.parseFirstDay(firstDayString)
    }

    private enum CodingKeys: String, CodingKey {
        case primaryScheduleTitle
        case currentTerm
        case firstDayString
        case coursesUpdatedAt
        case lexueCalendarURL
        case courses
        case cachedCoursesByTerm
        case termSchedulesByTerm
        case exams
        case customSchedules
        case ddlEvents
        case ddlUpdatedAt
        case ddlBeforeDay
        case ddlAfterDay
        case selectedCampusName
        case selectedCampusCode
        case selectedBuildingID
        case cachedClassroomCampuses
        case cachedClassroomBuildingsByCampusCode
        case selectedClassroomSectionIDs
        case showSaturday
        case showSunday
        case showBorder
        case showHighlightToday
        case showDivider
        case showCurrentTime
        case showExamInfo
        case scheduleDisplayMode
        case scheduleCardContentMode = "scheduleCardContentModeV2"
        case showCourseLiveActivityReminder
        case courseLiveActivityLeadMinutes
        case timeTable
        case sharedSchedules
        case iCloudSyncEnabled
        case updatedAt
    }

    /// 提供一份带默认值的空缓存。
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        currentTerm = try container.decodeIfPresent(String.self, forKey: .currentTerm) ?? ""
        primaryScheduleTitle = Self.clampedScheduleTitle(
            try container.decodeIfPresent(String.self, forKey: .primaryScheduleTitle) ?? "课表"
        )
        firstDayString = try container.decodeIfPresent(String.self, forKey: .firstDayString) ?? ""
        let decodedCoursesUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .coursesUpdatedAt)
        lexueCalendarURL = try container.decodeIfPresent(String.self, forKey: .lexueCalendarURL) ?? ""
        courses = try container.decodeIfPresent([CourseRecord].self, forKey: .courses) ?? []
        cachedCoursesByTerm = try container.decodeIfPresent(
            [String: [CourseRecord]].self,
            forKey: .cachedCoursesByTerm
        ) ?? [:]
        termSchedulesByTerm = try container.decodeIfPresent(
            [String: TermScheduleSnapshot].self,
            forKey: .termSchedulesByTerm
        ) ?? [:]
        // 从旧版单学期缓存平滑迁移；升级不会丢失用户已经保存的课表。
        if cachedCoursesByTerm.isEmpty, !currentTerm.isEmpty, !courses.isEmpty {
            cachedCoursesByTerm[currentTerm] = courses
        }
        exams = try container.decodeIfPresent([ExamRecord].self, forKey: .exams) ?? []
        customSchedules = try container.decodeIfPresent([CustomScheduleRecord].self, forKey: .customSchedules) ?? []
        ddlEvents = try container.decodeIfPresent([DDLEventRecord].self, forKey: .ddlEvents) ?? []
        ddlUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .ddlUpdatedAt)
        ddlBeforeDay = try container.decodeIfPresent(Int.self, forKey: .ddlBeforeDay) ?? 7
        ddlAfterDay = try container.decodeIfPresent(Int.self, forKey: .ddlAfterDay) ?? 3
        selectedCampusName = try container.decodeIfPresent(String.self, forKey: .selectedCampusName) ?? ""
        selectedCampusCode = try container.decodeIfPresent(String.self, forKey: .selectedCampusCode) ?? ""
        selectedBuildingID = try container.decodeIfPresent(String.self, forKey: .selectedBuildingID) ?? ""
        cachedClassroomCampuses = try container.decodeIfPresent([CampusRecord].self, forKey: .cachedClassroomCampuses) ?? []
        cachedClassroomBuildingsByCampusCode = try container.decodeIfPresent(
            [String: [BuildingRecord]].self,
            forKey: .cachedClassroomBuildingsByCampusCode
        ) ?? [:]
        selectedClassroomSectionIDs = try container.decodeIfPresent([Int].self, forKey: .selectedClassroomSectionIDs) ?? []
        showSaturday = try container.decodeIfPresent(Bool.self, forKey: .showSaturday) ?? true
        showSunday = try container.decodeIfPresent(Bool.self, forKey: .showSunday) ?? true
        showBorder = try container.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true
        showHighlightToday = try container.decodeIfPresent(Bool.self, forKey: .showHighlightToday) ?? true
        showDivider = try container.decodeIfPresent(Bool.self, forKey: .showDivider) ?? true
        showCurrentTime = try container.decodeIfPresent(Bool.self, forKey: .showCurrentTime) ?? true
        showExamInfo = try container.decodeIfPresent(Bool.self, forKey: .showExamInfo) ?? true
        scheduleDisplayMode = try container.decodeIfPresent(ScheduleDisplayMode.self, forKey: .scheduleDisplayMode) ?? .weekly
        // V2 首次引入三态轮换；不读取早期开发版的两态实验值，确保默认回到名称+地点。
        scheduleCardContentMode = try container.decodeIfPresent(ScheduleCardContentMode.self, forKey: .scheduleCardContentMode) ?? .nameAndLocation
        showCourseLiveActivityReminder = try container.decodeIfPresent(Bool.self, forKey: .showCourseLiveActivityReminder) ?? false
        courseLiveActivityLeadMinutes = min(
            max(try container.decodeIfPresent(Int.self, forKey: .courseLiveActivityLeadMinutes) ?? 20, 1),
            60
        )
        timeTable = try container.decodeIfPresent([TimeSlot].self, forKey: .timeTable) ?? TimeSlot.default
        sharedSchedules = (try container.decodeIfPresent([SharedScheduleRecord].self, forKey: .sharedSchedules) ?? []).map {
            var schedule = $0
            schedule.title = Self.clampedScheduleTitle(schedule.title)
            return schedule
        }
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        // 老版本没有独立的课表同步时间；迁移时以原缓存更新时间作为保守基线，
        // 保留已有缓存的时间语义。
        coursesUpdatedAt = decodedCoursesUpdatedAt ?? (courses.isEmpty ? .distantPast : updatedAt)
        if termSchedulesByTerm.isEmpty, !currentTerm.isEmpty, !courses.isEmpty {
            termSchedulesByTerm[currentTerm] = TermScheduleSnapshot(
                term: currentTerm,
                firstDayString: firstDayString,
                courses: courses,
                exams: exams,
                updatedAt: coursesUpdatedAt
            )
        }

        // 旧版已经落盘的 `-1` 小学期课表也在解码时确定性迁移。校正后的数据再次
        // 解码会得到 offset=0，因此不会重复平移；其它学期不会进入该规则。
        for (term, snapshot) in termSchedulesByTerm {
            let normalized = SmallTermWeekNormalizer.normalize(
                term: term,
                firstDayString: snapshot.firstDayString,
                courses: snapshot.courses
            )
            guard normalized.offset > 0 else { continue }
            let migrated = TermScheduleSnapshot(
                term: term,
                firstDayString: normalized.firstDayString,
                courses: normalized.courses,
                exams: snapshot.exams,
                updatedAt: snapshot.updatedAt
            )
            termSchedulesByTerm[term] = migrated
            cachedCoursesByTerm[term] = normalized.courses
            if currentTerm == term {
                firstDayString = normalized.firstDayString
                courses = normalized.courses
            }
        }
    }

    /// 把课表标题裁到统一长度上限。
    ///
    /// 这里不额外做空值兜底，调用方如果需要“默认标题”，应先给出默认值再传入。
    private static func clampedScheduleTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scheduleNameCharacterLimit))
    }

    /// 非隔离地解析 `yyyy-MM-dd`，供 `Codable` 和云同步 actor 使用。
    ///
    /// 这里不用 `DateFormatter`，避免默认 MainActor 隔离下在非隔离编解码路径里访问共享 formatter。
    private static func parseFirstDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// A complete converted timetable for one semester. Only the adjacent two terms
/// are retained by the rolling local cache.
nonisolated struct TermScheduleSnapshot: Codable {
    let term: String
    let firstDayString: String
    let courses: [CourseRecord]
    let exams: [ExamRecord]
    let updatedAt: Date

    var firstDay: Date? {
        let parts = firstDayString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    var hasDisplayableData: Bool {
        !courses.isEmpty || !exams.isEmpty
    }
}

/// 导入到本地后的分享课表记录。
///
/// 这类课表只承担“查看与切换”的职责，不参与提醒、DDL、空教室偏好等当前账号私有逻辑。
struct SharedScheduleRecord: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    let importedAt: Date
    let currentTerm: String
    let firstDayString: String
    let timeTable: [TimeSlot]
    let courses: [CourseRecord]

    init(
        id: String = UUID().uuidString,
        title: String,
        importedAt: Date = Date(),
        payload: ScheduleExportPayload
    ) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.currentTerm = payload.currentTerm
        self.firstDayString = payload.firstDayString
        self.timeTable = payload.timeTable
        self.courses = payload.courses
    }

    var isEmpty: Bool {
        courses.isEmpty
    }
}

/// 课程表和 DDL 共用的日期编解码工具。
///
/// 日程模块内部有多种日期展示形式，因此集中维护一组格式器，避免各页面各自创建。
enum ScheduleDateCodec {
    /// 固定使用公历，避免系统日历设置影响周数计算。
    static let calendar = ScheduleSharedDateCodec.calendar

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let relativeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        ScheduleSharedDateCodec.parseDate(string)
    }

    /// 解析 `HH:mm` 文本为一个只关心时分的 `Date`。
    static func parseTime(_ string: String) -> Date? {
        timeFormatter.date(from: string)
    }

    /// 格式化时分文本。
    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// 格式化 `yyyy-MM-dd` 文本。
    static func formatDate(_ date: Date) -> String {
        ScheduleSharedDateCodec.formatDate(date)
    }

    /// 返回给定日期所在自然周的周一，用于保证课表首周基准始终从周一开始。
    static func monday(containing date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysAfterMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysAfterMonday, to: startOfDay) ?? startOfDay
    }

    /// 格式化 `M月d日` 短日期。
    static func formatShortDate(_ date: Date) -> String {
        ScheduleSharedDateCodec.formatShortDate(date)
    }

    /// 格式化精确到分钟的完整日期时间。
    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// 格式化列表里常用的相对简写日期时间。
    static func formatRelativeDateTime(_ date: Date) -> String {
        relativeFormatter.string(from: date)
    }

    /// 直接把 `HH:mm` 文本转成分钟数。
    static func minutesOfDay(from string: String) -> Int {
        TimeSlot.parseMinutes(string)
    }

    /// 把系统 weekday 映射成项目内部使用的“周一=1 ... 周日=7”。
    static func weekdayIndex(from date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7) + 1
    }

    /// 读取某个 `Date` 在一天中的分钟偏移。
    static func minutesOfDay(from date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// 课表周次与首周偏移的双向转换。
///
/// 产品周次不使用“第 0 周”：第一周之前紧邻的一周记作第 -1 周，再往前是第 -2 周。
enum ScheduleWeekCodec {
    static func weekNumber(forDayOffset dayOffset: Int) -> Int {
        let quotient = dayOffset / 7
        let remainder = dayOffset % 7
        let weekOffset = remainder < 0 ? quotient - 1 : quotient
        return weekOffset >= 0 ? weekOffset + 1 : weekOffset
    }

    static func weekOffset(forWeekNumber week: Int) -> Int {
        week > 0 ? week - 1 : week
    }

    static func previousWeek(before week: Int) -> Int {
        if week == 1 || week == 0 { return -1 }
        return week - 1
    }

    static func nextWeek(after week: Int) -> Int {
        if week == -1 || week == 0 { return 1 }
        return week + 1
    }
}
