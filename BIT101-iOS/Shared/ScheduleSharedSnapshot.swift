import Foundation

extension Notification.Name {
    /// 共享课表快照已更新。
    ///
    /// watch app 当前页、watch widget 以及未来可能出现的其它外部展示层
    /// 都可以监听这条通知，在本地镜像更新后立即刷新视图。
    static let scheduleExternalSnapshotDidChange = Notification.Name("BIT101.ScheduleExternalSnapshotDidChange")
}

/// 课表外部展示能力共用的 App Group 标识。
///
/// 当前桌面/锁屏 widget 会直接读取这份共享快照；
/// 后续如果接入 watch 端，也应优先复用这一层抽象，而不是重新约定一套字段名。
enum ScheduleSharedContainer {
    static let identifier = "group.BIT101-dev.BIT101-iOS.shared"
    static let directoryName = "Widgets"
    /// 历史上 widget 已经使用这个文件名；当前保留它，避免平滑演进时出现读取断层。
    static let snapshotFileName = "schedule-widget-snapshot.json"
}

/// 对外部展示层暴露的精简节次模型。
///
/// 它有意不直接复用主 app 的 `TimeSlot`，
/// 这样未来 watch / widget / 其它扩展都能只依赖这一份更稳定的契约。
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

/// 主 app 导出、widget / watch 读取的统一课表快照。
///
/// 这份结构是跨 target 的稳定边界：
/// - 主 app 负责从完整缓存裁剪出可共享的最小信息
/// - 外部展示层只依赖这里，而不反向耦合主 app 内部状态机
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
/// 磁盘快照和 WatchConnectivity 必须使用相同的日期策略。每次调用创建独立的
/// encoder / decoder，也避免多个并发消费方共享可变 Foundation 编码器。
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
/// 当前主 app 会写入它，widget 读取它；
/// 后续接入 watch 时，也应优先复用这里，而不是再手搓一套路径拼接与编解码逻辑。
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
