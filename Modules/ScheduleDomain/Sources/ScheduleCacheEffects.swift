import StorageCore
import Foundation

/// 持久化完成后的外部展示与同步接口。
@MainActor
public protocol ScheduleCacheEffects {
    func didSave(_ courses: ScheduleCourseSnapshot, session: AppStorageSession, source: ScheduleCacheSaveSource, cloudSyncEnabled: Bool) async
    func didClear() async
}

/// 用户操作触发的平台能力，由应用组装层提供。
@MainActor
public protocol SchedulePlatformActions {
    func enableCloudSync(cache: ScheduleCache, session: AppStorageSession) async
    func enableCourseReminder(session: AppStorageSession) async
    func importSystemCalendar(cache: ScheduleCache) async throws -> Int
    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int
    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult
    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult
    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult
}

/// 日程向平台适配器传递业务记录，事件展开与系统写入由适配器维护。
public nonisolated enum ScheduleSystemCalendarContent: Equatable, Sendable {
    case courses([CourseRecord], firstDay: Date, timeTable: [TimeSlot], week: Int? = nil)
    case exam(ExamRecord)
    case customSchedule(CustomScheduleRecord)
}

public nonisolated enum ScheduleSystemCalendarMutationResult: Equatable, Sendable {
    case changed(Int)
    case noOp

    public var count: Int {
        switch self {
        case let .changed(count): return count
        case .noOp: return 0
        }
    }
}

/// 系统日历业务错误与权限恢复条件。
public nonisolated enum ScheduleSystemCalendarError: LocalizedError {
    case permissionDenied
    case noWritableCalendarSource
    case missingSchedule
    case noImportedEvents
    case invalidEntry(String)

    public var requiresCalendarSettings: Bool {
        switch self {
        case .permissionDenied, .noWritableCalendarSource:
            return true
        case .missingSchedule, .noImportedEvents, .invalidEntry:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "当前日历账户的写入权限需要调整。请在系统设置的“隐私与安全性－日历”中开启 BIT101 权限，并确认 iCloud 或本地日历账户处于可写状态。"
        case .noWritableCalendarSource:
            return "未找到可以写入的系统日历账户。请先在“日历”App 中启用 iCloud 或本地日历。"
        case .missingSchedule:
            return "当前学期还没有可导入的课程，或尚未取得学期起始日期。"
        case .noImportedEvents:
            return "没有找到由 BIT101 导入的日历事件。"
        case let .invalidEntry(message):
            return message
        }
    }
}

