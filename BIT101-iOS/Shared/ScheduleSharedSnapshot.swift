import Foundation

extension Notification.Name {
    /// 共享课表快照更新通知。
    ///
    /// Watch App 当前页和 Watch Widget 可在所属进程监听这条通知，在本地镜像更新后刷新视图。
    static let scheduleExternalSnapshotDidChange = Notification.Name("BIT101.ScheduleExternalSnapshotDidChange")
}

/// 课表外部展示能力共用的 App Group 标识。
///
/// 桌面/锁屏 Widget、Live Activity、Apple Watch App 和 Smart Stack 共用这份共享快照；
/// 各外部展示层复用这一层抽象，保持容器标识和文件路径一致。
enum ScheduleSharedContainer {
    static let identifier = "group.BIT101-dev.BIT101-iOS.shared"
    static let directoryName = "Widgets"
    /// Widget 已使用这个文件名。当前继续保留它，兼容已有快照读取路径。
    static let snapshotFileName = "schedule-widget-snapshot.json"
}

/// 对外部展示层暴露的精简节次模型。
///
/// 该模型独立于主 App 的 `TimeSlot`，供 Watch、Widget 和 Live Activity 依赖。
struct ScheduleExternalTimeSlotSnapshot: Codable, Hashable {
    let id: Int
    let start: String
    let end: String
}

/// 对外部展示层暴露的精简课程模型。
///
/// 当前只保留“计算下一节/后续课程”真正需要的字段。
struct ScheduleExternalCourseSnapshot: Codable, Hashable {
    let id: String
    let name: String
    let classroom: String
    let teacher: String
    let weeks: [Int]
    let weekday: Int
    let startSection: Int
    let endSection: Int
}

/// 主 App 导出、Widget、Live Activity 和 Watch 读取的统一课表快照。
///
/// 这份结构定义跨 target 的稳定边界：
/// - 主 App 从完整缓存裁剪出可共享的最小信息
/// - Widget、Live Activity 和 Watch 依赖这份快照，与主 App 状态机保持解耦
struct ScheduleExternalSnapshot: Codable, Hashable {
    let generatedAt: Date
    let isLoggedIn: Bool
    let studentID: String
    let firstDayString: String
    let timeTable: [ScheduleExternalTimeSlotSnapshot]
    let courses: [ScheduleExternalCourseSnapshot]

    init(
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

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case isLoggedIn
        case studentID
        case firstDayString
        case timeTable
        case courses
    }

    init(from decoder: Decoder) throws {
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
enum ScheduleExternalSnapshotCodec {
    static func encode(
        _ snapshot: ScheduleExternalSnapshot,
        outputFormatting: JSONEncoder.OutputFormatting = []
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> ScheduleExternalSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScheduleExternalSnapshot.self, from: data)
    }
}

/// iPhone 与 Watch 之间传输课表镜像时使用的稳定字段约定。
enum WatchScheduleTransferProtocol {
    nonisolated static let snapshotDataKey = "schedule_external_snapshot_data"
    nonisolated static let requestLatestSnapshotKey = "request_latest_schedule_snapshot"
    nonisolated static let requestData = Data(requestLatestSnapshotKey.utf8)

    nonisolated static func snapshotContext(_ data: Data) -> [String: Any] {
        [snapshotDataKey: data]
    }

    nonisolated static var requestContext: [String: Any] {
        [requestLatestSnapshotKey: true]
    }

    nonisolated static func snapshotData(from context: [String: Any]) -> Data? {
        context[snapshotDataKey] as? Data
    }

    nonisolated static func requestsLatestSnapshot(_ context: [String: Any]) -> Bool {
        context[requestLatestSnapshotKey] as? Bool == true
    }
}

enum ScheduleExternalSnapshotStoreError: Error {
    case sharedContainerUnavailable
}

/// 跨 target 共享快照的磁盘仓库。
///
/// 主 App 写入这份快照，Widget、Live Activity 和 Watch 读取这份快照；
/// 各 target 复用这里的路径拼接与编解码逻辑。
enum ScheduleExternalSnapshotStore {
    @discardableResult
    static func save(_ snapshot: ScheduleExternalSnapshot) -> Bool {
        do {
            try write(snapshot)
            return true
        } catch {
            return false
        }
    }

    /// 可抛错的写入入口供同步链路使用，让传输层能够区分解码失败与落盘失败。
    static func write(_ snapshot: ScheduleExternalSnapshot) throws {
        guard let fileURL else {
            throw ScheduleExternalSnapshotStoreError.sharedContainerUnavailable
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ScheduleExternalSnapshotCodec.encode(
            snapshot,
            outputFormatting: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: fileURL, options: [.atomic])
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scheduleExternalSnapshotDidChange, object: nil)
        }
    }

    static func load() -> ScheduleExternalSnapshot? {
        guard
            let fileURL,
            let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }

        return try? ScheduleExternalSnapshotCodec.decode(data)
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scheduleExternalSnapshotDidChange, object: nil)
        }
    }

    static var fileURL: URL? {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ScheduleSharedContainer.identifier
            )
        else {
            return nil
        }

        return containerURL
            .appending(path: ScheduleSharedContainer.directoryName, directoryHint: .isDirectory)
            .appending(path: ScheduleSharedContainer.snapshotFileName)
    }
}
