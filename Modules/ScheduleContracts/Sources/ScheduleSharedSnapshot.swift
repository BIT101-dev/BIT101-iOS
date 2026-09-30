import CryptoKit
import Foundation

extension Notification.Name {
    /// 共享课表快照更新通知。
    ///
    /// 当前进程的 Watch App 页面监听这条通知，在本地镜像更新后刷新视图；
    /// Widget 通过 `WidgetCenter` 刷新时间线。iPhone 与 Watch 的跨进程更新
    /// 通过 App Group 文件和 WatchConnectivity 传递。
    public static let scheduleExternalSnapshotDidChange = Notification.Name("BIT101.ScheduleExternalSnapshotDidChange")
}

/// 课表外部展示能力共用的 App Group 标识。
///
/// 桌面/锁屏 Widget、Apple Watch App 和 Smart Stack 共用这份共享快照；
/// Live Activity 由 ActivityKit 状态契约承载展示内容。各外部展示层复用这一层抽象，
/// 保持容器标识和文件路径一致。
public nonisolated enum ScheduleSharedContainer {
    public static let identifier = "group.BIT101-dev.BIT101-iOS.shared"
    public static let directoryName = "Widgets"
    /// 主 App、Widget 与 Watch 通过 App Group 使用此快照文件名。
    public static let snapshotFileName = "schedule-widget-snapshot.json"
}

/// 对外部展示层暴露的精简节次模型。
///
/// 该模型独立于主 App 的 `TimeSlot`，供 Watch、Widget 和 Live Activity 依赖。
public nonisolated struct ScheduleExternalTimeSlotSnapshot: Codable, Hashable, Sendable {
    public init(id: Int, start: String, end: String) {
        self.id = id
        self.start = start
        self.end = end
    }

    public let id: Int
    public let start: String
    public let end: String
}

/// 对外部展示层暴露的精简课程模型。
///
/// 共享模型包含计算当前课程与后续课程所需字段。
public nonisolated struct ScheduleExternalCourseSnapshot: Codable, Hashable, Sendable {
    public init(id: String, name: String, classroom: String, teacher: String, weeks: [Int], weekday: Int, startSection: Int, endSection: Int) {
        self.id = id
        self.name = name
        self.classroom = classroom
        self.teacher = teacher
        self.weeks = weeks
        self.weekday = weekday
        self.startSection = startSection
        self.endSection = endSection
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, classroom, teacher, weeks, weekday, startSection, endSection
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        classroom = try values.decodeIfPresent(String.self, forKey: .classroom) ?? ""
        teacher = try values.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        weeks = try values.decode([Int].self, forKey: .weeks)
        weekday = try values.decode(Int.self, forKey: .weekday)
        startSection = try values.decode(Int.self, forKey: .startSection)
        endSection = try values.decodeIfPresent(Int.self, forKey: .endSection) ?? startSection
    }

    public let id: String
    public let name: String
    public let classroom: String
    public let teacher: String
    public let weeks: [Int]
    public let weekday: Int
    public let startSection: Int
    public let endSection: Int
}

/// 主 App 导出、Widget 和 Watch 读取的统一课表快照。
///
/// 这份结构定义跨 target 的稳定边界：
/// - 主 App 从完整缓存裁剪出可共享的最小信息
/// - Widget 和 Watch 依赖这份快照，与主 App 状态机保持解耦
public nonisolated struct ScheduleExternalSnapshot: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let isLoggedIn: Bool
    /// 跨设备账号隔离使用的稳定摘要；字段名沿用既有传输约定。
    public let studentID: String
    public let firstDayString: String
    public let timeTable: [ScheduleExternalTimeSlotSnapshot]
    public let courses: [ScheduleExternalCourseSnapshot]

    public init(
        generatedAt: Date = Date(),
        isLoggedIn: Bool,
        studentID: String,
        firstDayString: String,
        timeTable: [ScheduleExternalTimeSlotSnapshot],
        courses: [ScheduleExternalCourseSnapshot]
    ) {
        self.generatedAt = generatedAt
        self.isLoggedIn = isLoggedIn
        self.studentID = studentID
        self.firstDayString = firstDayString
        self.timeTable = timeTable
        self.courses = courses
    }

    /// Returns a copy carrying the opaque local account namespace used for cross-device validation.
    public func replacingStudentID(with identifier: String) -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: generatedAt,
            isLoggedIn: isLoggedIn,
            studentID: identifier,
            firstDayString: firstDayString,
            timeTable: timeTable,
            courses: courses
        )
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case isLoggedIn
        case studentID
        case firstDayString
        case timeTable
        case courses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        isLoggedIn = try container.decodeIfPresent(Bool.self, forKey: .isLoggedIn) ?? false
        studentID = try container.decodeIfPresent(String.self, forKey: .studentID) ?? ""
        firstDayString = try container.decodeIfPresent(String.self, forKey: .firstDayString) ?? ""
        timeTable = try container.decodeIfPresent([ScheduleExternalTimeSlotSnapshot].self, forKey: .timeTable) ?? []
        courses = try container.decodeIfPresent([ScheduleExternalCourseSnapshot].self, forKey: .courses) ?? []
    }
}

/// `ScheduleExternalSnapshot` 的统一传输编解码器。
///
/// 磁盘快照和 WatchConnectivity 采用相同的日期策略。每次调用创建独立的
/// encoder / decoder，隔离并发消费方的可变 Foundation 编码器。
public nonisolated enum ScheduleExternalSnapshotCodec {
    public nonisolated static func encode(
        _ snapshot: ScheduleExternalSnapshot,
        outputFormatting: JSONEncoder.OutputFormatting = []
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public nonisolated static func decode(_ data: Data) throws -> ScheduleExternalSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScheduleExternalSnapshot.self, from: data)
    }
}

/// iPhone 与 Watch 之间传输课表镜像时使用的稳定字段约定。
public enum WatchScheduleTransferProtocol {
    public nonisolated static let snapshotDataKey = "schedule_external_snapshot_data"
    public nonisolated static let requestLatestSnapshotKey = "request_latest_schedule_snapshot"
    public nonisolated static let requestData = Data(requestLatestSnapshotKey.utf8)

    public nonisolated static func snapshotContext(_ data: Data) -> [String: Any] {
        [snapshotDataKey: data]
    }

    public nonisolated static var requestContext: [String: Any] {
        [requestLatestSnapshotKey: true]
    }

    public nonisolated static func snapshotData(from context: [String: Any]) -> Data? {
        context[snapshotDataKey] as? Data
    }

    public nonisolated static func requestsLatestSnapshot(_ context: [String: Any]) -> Bool {
        context[requestLatestSnapshotKey] as? Bool == true
    }
}
