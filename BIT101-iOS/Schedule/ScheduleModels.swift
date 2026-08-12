//
//  ScheduleModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation
#if canImport(os)
import os
#endif
#if canImport(CloudKit)
import CloudKit
#endif

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
enum ScheduleSection: String, CaseIterable, Identifiable {
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
    /// 最近一次从学校成功同步课表与考试的时间，用于按天数触发自动更新。
    var coursesUpdatedAt: Date = .distantPast
    var lexueCalendarURL: String = ""
    var courses: [CourseRecord] = []
    /// 已成功同步过的各学期课表快照，供成绩页本地判断尚未出分的课程。
    var cachedCoursesByTerm: [String: [CourseRecord]] = [:]
    var exams: [ExamRecord] = []
    var customSchedules: [CustomScheduleRecord] = []
    var ddlEvents: [DDLEventRecord] = []
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
        case exams
        case customSchedules
        case ddlEvents
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
        // 从旧版单学期缓存平滑迁移；升级不会丢失用户已经保存的课表。
        if cachedCoursesByTerm.isEmpty, !currentTerm.isEmpty, !courses.isEmpty {
            cachedCoursesByTerm[currentTerm] = courses
        }
        exams = try container.decodeIfPresent([ExamRecord].self, forKey: .exams) ?? []
        customSchedules = try container.decodeIfPresent([CustomScheduleRecord].self, forKey: .customSchedules) ?? []
        ddlEvents = try container.decodeIfPresent([DDLEventRecord].self, forKey: .ddlEvents) ?? []
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
        // 避免用户升级后的第一次启动立即触发一次意外自动更新。
        coursesUpdatedAt = decodedCoursesUpdatedAt ?? (courses.isEmpty ? .distantPast : updatedAt)
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

/// 日程模块本地缓存仓库。
///
/// 统一负责 `ScheduleCache` 的磁盘读写和变更通知发送。
enum ScheduleCacheStore {
    enum SaveSource {
        case local
        case localWithoutCloudPush
        case cloud
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 当前账号对应的缓存文件路径。
    ///
    /// 课表、DDL 和灵动岛设置都已按账号隔离，所以路径会带当前学号。
    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: currentAccountIdentifier(), directoryHint: .isDirectory)
        return directory.appending(path: "schedule-cache.json")
    }

    /// 把当前学号转换成安全的目录名。
    static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "__default__"
        }

        let invalid = CharacterSet.alphanumerics.inverted
        return raw.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 读取当前账号的缓存快照。
    static func load() -> ScheduleCache {
        guard
            let data = try? Data(contentsOf: fileURL),
            let cache = try? decoder.decode(ScheduleCache.self, from: data)
        else {
            return ScheduleCache()
        }

        return cache
    }

    /// 写回缓存，并同步触发小组件导出和全局变更通知。
    static func save(_ cache: ScheduleCache, source: SaveSource = .local) {
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        var cacheToSave = cache

        if source == .local {
            cacheToSave.updatedAt = Date()
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(cacheToSave)
            try data.write(to: url, options: [.atomic])
            ScheduleWidgetExporter.sync(cache: cacheToSave)
            postCacheDidChange()
            #if canImport(CloudKit)
            if source == .local, cacheToSave.iCloudSyncEnabled {
                Task {
                    await ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()
                }
            }
            #endif
        } catch {}
    }

    /// 清空当前账号的日程缓存。
    ///
    /// 这里不会碰其它账号目录，避免多账号切换后互相误删数据。
    static func clear() {
        let url = fileURL
        let directory = url.deletingLastPathComponent()

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            if FileManager.default.fileExists(atPath: directory.path),
               (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try FileManager.default.removeItem(at: directory)
            }

            ScheduleWidgetExporter.syncFromCurrentCache()
            postCacheDidChange()
        } catch {}
    }

    /// 在主线程广播“课表缓存已变化”。
    ///
    /// 保存与清空缓存后都需要发这条通知，因此集中收口，避免两个入口各自重复写一遍
    /// `DispatchQueue.main.async + post`。
    private static func postCacheDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scheduleCacheDidChange, object: nil)
        }
    }
}

#if canImport(CloudKit)
actor ScheduleCloudSyncManager {
    static let shared = ScheduleCloudSyncManager()

    private enum FieldKey {
        static let studentID = "studentID"
        static let payloadJSON = "payloadJSON"
        static let updatedAt = "updatedAt"
    }

    /// CloudKit containers require a signed host carrying the iCloud entitlement.
    /// Resolve it only after the persisted opt-in check, so unit-test hosts and
    /// unsigned simulator builds can launch without touching CloudKit.
    private var container: CKContainer { CKContainer.default() }
    private let recordType = "ScheduleCacheSyncRecord"
    #if canImport(os)
    private let logger = Logger(subsystem: "BIT101", category: "ScheduleCloudSync")
    #endif
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func refreshFromCloudIfNeeded() async {
        let localCache = await MainActor.run { ScheduleCacheStore.load() }
        guard localCache.iCloudSyncEnabled else {
            logDebug("skip refresh: iCloud sync disabled")
            return
        }
        await reconcile(localCache: localCache, allowCloudApply: true)
    }

    func reconcileAfterEnabling(localCache: ScheduleCache) async {
        logDebug("reconcile after enabling")
        await reconcile(localCache: localCache, allowCloudApply: true)
    }

    func pushLatestLocalCacheIfNeeded() async {
        let localCache = await MainActor.run { ScheduleCacheStore.load() }
        guard localCache.iCloudSyncEnabled else {
            logDebug("skip push: iCloud sync disabled")
            return
        }
        do {
            _ = try await upsert(remoteWith: localCache)
        } catch {
            logError("push latest local cache failed: \(describe(error))")
        }
    }

    private func reconcile(localCache: ScheduleCache, allowCloudApply: Bool) async {
        guard let recordID = await currentRecordID() else {
            logDebug("skip reconcile: current student id is empty")
            return
        }

        let accountStatus = await accountStatusText()
        logDebug(
            "reconcile start record=\(recordID.recordName) accountStatus=\(accountStatus) localUpdatedAt=\(debugDate(localCache.updatedAt)) allowCloudApply=\(allowCloudApply)"
        )

        do {
            let remoteRecord = try await container.privateCloudDatabase.record(for: recordID)
            guard let remoteCache = decodeCache(from: remoteRecord) else {
                logError("reconcile abort: remote payload decode failed record=\(recordID.recordName)")
                return
            }

            logDebug(
                "reconcile fetched remoteUpdatedAt=\(debugDate(remoteCache.updatedAt)) localUpdatedAt=\(debugDate(localCache.updatedAt))"
            )

            if remoteCache.updatedAt > localCache.updatedAt, allowCloudApply {
                let cacheToApply: ScheduleCache = {
                    var cache = remoteCache
                    cache.iCloudSyncEnabled = true
                    return cache
                }()
                logDebug("applying remote cache to local")
                await MainActor.run {
                    ScheduleCacheStore.save(cacheToApply, source: .cloud)
                }
                return
            }

            if localCache.updatedAt > remoteCache.updatedAt {
                logDebug("local cache newer than remote; uploading local copy")
                _ = try? await upsert(remoteWith: localCache)
            } else {
                logDebug("reconcile no-op: remote not newer and local not newer")
            }
        } catch let error as CKError {
            if error.code == .unknownItem || error.code == .serverRejectedRequest {
                logDebug("remote record unavailable (\(error.code.rawValue)); uploading initial local cache")
                var initialUpload = localCache
                if initialUpload.updatedAt == .distantPast {
                    initialUpload.updatedAt = Date()
                }
                do {
                    _ = try await upsert(remoteWith: initialUpload)
                } catch {
                    logError("initial upload after unknownItem failed: \(describe(error))")
                }
            } else {
                logError("reconcile cloud error: \(describe(error))")
            }
        } catch {
            logError("reconcile failed: \(describe(error))")
        }
    }

    private func upsert(remoteWith cache: ScheduleCache) async throws -> CKRecord {
        guard let recordID = await currentRecordID() else {
            throw CKError(.badContainer)
        }

        logDebug("upsert start record=\(recordID.recordName) updatedAt=\(debugDate(cache.updatedAt))")

        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: recordID)
            logDebug("upsert fetched existing remote record")
        } catch let error as CKError where error.code == .unknownItem || error.code == .serverRejectedRequest {
            record = CKRecord(recordType: recordType, recordID: recordID)
            logDebug("upsert will create new remote record after fetch error code=\(error.code.rawValue)")
        }

        let payloadJSON = try await encodeCache(cache)
        record[FieldKey.studentID] = await currentStudentID() as CKRecordValue
        record[FieldKey.updatedAt] = cache.updatedAt as CKRecordValue
        record[FieldKey.payloadJSON] = payloadJSON as CKRecordValue
        let saved = try await container.privateCloudDatabase.save(record)
        logDebug("upsert saved remote record successfully")
        return saved
    }

    private func decodeCache(from record: CKRecord) -> ScheduleCache? {
        if let payloadJSON = record[FieldKey.payloadJSON] as? String {
            return try? decoder.decode(ScheduleCache.self, from: Data(payloadJSON.utf8))
        }
        return nil
    }

    private func currentRecordID() async -> CKRecord.ID? {
        let studentID = await currentStudentID()
        guard !studentID.isEmpty else { return nil }
        let account = await MainActor.run { ScheduleCacheStore.currentAccountIdentifier() }
        return CKRecord.ID(recordName: "schedule-cache-\(account)")
    }

    private func currentStudentID() async -> String {
        await MainActor.run {
            LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func encodeCache(_ cache: ScheduleCache) async throws -> String {
        let data = try encoder.encode(cache)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return json
    }

    private func accountStatusText() async -> String {
        do {
            let status = try await container.accountStatus()
            return switch status {
            case .available: "available"
            case .couldNotDetermine: "couldNotDetermine"
            case .noAccount: "noAccount"
            case .restricted: "restricted"
            case .temporarilyUnavailable: "temporarilyUnavailable"
            @unknown default: "unknown"
            }
        } catch {
            return "error:\(describe(error))"
        }
    }

    private func debugDate(_ date: Date) -> String {
        if date == .distantPast {
            return "distantPast"
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private func describe(_ error: Error) -> String {
        if let ckError = error as? CKError {
            let userInfoSummary = ckError.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            return "CKError(code=\(ckError.code.rawValue) \(ckError.code), localized=\(ckError.localizedDescription), userInfo=[\(userInfoSummary)])"
        }
        return error.localizedDescription
    }

    private func logDebug(_ message: String) {
        #if canImport(os)
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    private func logError(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #endif
    }
}
#endif
