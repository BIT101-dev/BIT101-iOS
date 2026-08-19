import Foundation

/// 课表导出文件的精简载荷。
///
/// 导出课表的目标是分享排课本身，而不是同步整份本地缓存，因此这里只保留：
/// - 学期
/// - 首周
/// - 时间表
/// - 课程
///
/// 不包含 DDL、考试、自定义日程和个人显示偏好，避免把本地私有设置一起带出去。
struct ScheduleExportPayload: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let currentTerm: String
    let firstDayString: String
    let timeTable: [TimeSlot]
    let courses: [CourseRecord]

    init(
        formatVersion: Int,
        exportedAt: Date,
        currentTerm: String,
        firstDayString: String,
        timeTable: [TimeSlot],
        courses: [CourseRecord]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.currentTerm = currentTerm
        self.firstDayString = firstDayString
        self.timeTable = timeTable
        self.courses = courses
    }

    init(cache: ScheduleCache, exportedAt: Date = Date()) {
        self.formatVersion = 1
        self.exportedAt = exportedAt
        self.currentTerm = cache.currentTerm
        self.firstDayString = cache.firstDayString
        self.timeTable = cache.timeTable
        self.courses = cache.courses
    }

    /// 导出是否具备最基本的课表内容。
    var isEmpty: Bool {
        courses.isEmpty
    }
}

/// 课表分享编码的紧凑载荷 V2。
///
/// 该协议保留用于导入旧分享码；当前导出端已经升级到 V3。
///
/// ## 设计约束
/// - 继续复用现有外层包装：`lzfse + base64`
/// - 仍然使用 JSON 作为“压缩前明文”，避免引入完全自定义协议
/// - 但 JSON 改成**纯数组结构**，去掉冗余 key
/// - 只分享“排课骨架”，不分享本机运行环境
///
/// ## 当前正式定义
/// 最外层布局固定为：
///
/// ```text
/// [
///   2,
///   [
///     [课程名, 教师, 教室, 周次数组, 星期, 开始节, 结束节],
///     ...
///   ]
/// ]
/// ```
///
/// 其中：
/// - 第 0 项永远是格式版本号 `2`
/// - 第 1 项是课程数组
/// - 每一门课都按固定顺序编码成 7 项数组，不再携带字段名
///
/// ## 明确不包含的内容
/// V2 **故意不携带**以下信息：
/// - 首周日期
/// - 时间表
/// - 考试
/// - DDL
/// - 自定义日程
/// - 课表显示偏好
///
/// 原因是分享课表的目标只是复用“课程排布”，而不是复制发送方的整套本地环境。
/// 当前产品里，用户在能导入/查看分享课表之前，必然已经先同步过自己的课表；
/// 因此导入时可直接复用本机现有的：
/// - `currentTerm`
/// - `firstDayString`
/// - `timeTable`
///
/// ## 兼容策略
/// 新版默认导出 `BIT101SCH3`；导入端继续支持 `BIT101SCH1`、`BIT101SCH2` 和 `BIT101SCH3`。
/// 低版本客户端如果尚未支持 V2，会无法导入新版分享码，因此高版本兜底提示仍然保留。
struct ScheduleExportCompactPayloadV2: Codable {
    static let formatVersion = 2

    /// V2 内部单门课的极简表示。
    ///
    /// 字段顺序必须稳定，因为压缩后的导入端完全依赖位置还原含义。
    struct CompactCourse: Codable, Hashable {
        let name: String
        let teacher: String
        let classroom: String
        let weeks: [Int]
        let weekday: Int
        let startSection: Int
        let endSection: Int

        nonisolated init(
            name: String,
            teacher: String,
            classroom: String,
            weeks: [Int],
            weekday: Int,
            startSection: Int,
            endSection: Int
        ) {
            self.name = name
            self.teacher = teacher
            self.classroom = classroom
            self.weeks = weeks
            self.weekday = weekday
            self.startSection = startSection
            self.endSection = endSection
        }

        nonisolated init(course: CourseRecord) {
            self.init(
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                weeks: course.weeks,
                weekday: course.weekday,
                startSection: course.startSection,
                endSection: course.endSection
            )
        }

        /// 把极简课程重新扩展成完整的 `CourseRecord`。
        ///
        /// 这里会显式使用导入侧本机已经存在的课表环境作为补全来源。
        /// 当前策略是：
        /// - `term` 复用本机当前学期
        /// - 其余未分享字段统一回填为空或 0
        ///
        /// 之所以保留这个还原入口，即使当前还没正式启用 V2，也是为了让
        /// “协议定义” 和 “未来导入如何落地” 写在同一个地方，避免以后切换时遗漏。
        func expandedCourse(term: String) -> CourseRecord {
            CourseRecord(
                id: UUID().uuidString,
                term: term,
                name: name,
                teacher: teacher,
                classroom: classroom,
                description: "",
                weeks: weeks,
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                campus: "",
                number: "",
                credit: 0,
                hour: 0,
                type: "",
                category: "",
                department: ""
            )
        }
    }

    let courses: [CompactCourse]

    init(cache: ScheduleCache) {
        self.courses = cache.courses.map(CompactCourse.init(course:))
    }

    init(payload: ScheduleExportPayload) {
        self.courses = payload.courses.map(CompactCourse.init(course:))
    }

    var isEmpty: Bool { courses.isEmpty }

    /// 用导入侧的本机环境，把 V2 重新还原成 V1 等价载荷。
    ///
    /// 这不是说未来一定要先“V2 -> V1 -> SharedScheduleRecord”两跳转换，
    /// 而是为了把 V2 缺失字段的补全规则先写清楚，避免真正启用时出现歧义。
    func expandedPayload(using cache: ScheduleCache, importedAt: Date = Date()) -> ScheduleExportPayload {
        ScheduleExportPayload(
            formatVersion: 1,
            exportedAt: importedAt,
            currentTerm: cache.currentTerm,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable,
            courses: courses.map { $0.expandedCourse(term: cache.currentTerm) }
        )
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let version = try container.decode(Int.self)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的紧凑课表分享格式版本：\(version)"
            )
        }

        var coursesContainer = try container.nestedUnkeyedContainer()
        var decodedCourses: [CompactCourse] = []
        while !coursesContainer.isAtEnd {
            var course = try coursesContainer.nestedUnkeyedContainer()
            decodedCourses.append(
                CompactCourse(
                    name: try course.decode(String.self),
                    teacher: try course.decode(String.self),
                    classroom: try course.decode(String.self),
                    weeks: try course.decode([Int].self),
                    weekday: try course.decode(Int.self),
                    startSection: try course.decode(Int.self),
                    endSection: try course.decode(Int.self)
                )
            )
        }
        courses = decodedCourses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(Self.formatVersion)

        var coursesContainer = container.nestedUnkeyedContainer()
        for course in courses {
            var encodedCourse = coursesContainer.nestedUnkeyedContainer()
            try encodedCourse.encode(course.name)
            try encodedCourse.encode(course.teacher)
            try encodedCourse.encode(course.classroom)
            try encodedCourse.encode(course.weeks)
            try encodedCourse.encode(course.weekday)
            try encodedCourse.encode(course.startSection)
            try encodedCourse.encode(course.endSection)
        }
    }
}


/// 课表分享编码的紧凑载荷 V3。
///
/// V3 在 V2 的课程排布骨架上追加学分字段，是当前默认导出格式。
struct ScheduleExportCompactPayloadV3: Codable {
    static let formatVersion = 3

    struct CompactCourse: Codable, Hashable {
        let name: String
        let teacher: String
        let classroom: String
        let weeks: [Int]
        let weekday: Int
        let startSection: Int
        let endSection: Int
        let credit: Int

        nonisolated init(course: CourseRecord) {
            name = course.name
            teacher = course.teacher
            classroom = course.classroom
            weeks = course.weeks
            weekday = course.weekday
            startSection = course.startSection
            endSection = course.endSection
            credit = course.credit
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            name = try container.decode(String.self)
            teacher = try container.decode(String.self)
            classroom = try container.decode(String.self)
            weeks = try container.decode([Int].self)
            weekday = try container.decode(Int.self)
            startSection = try container.decode(Int.self)
            endSection = try container.decode(Int.self)
            credit = try container.decode(Int.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(name)
            try container.encode(teacher)
            try container.encode(classroom)
            try container.encode(weeks)
            try container.encode(weekday)
            try container.encode(startSection)
            try container.encode(endSection)
            try container.encode(credit)
        }

        func expandedCourse(term: String) -> CourseRecord {
            CourseRecord(
                id: UUID().uuidString,
                term: term,
                name: name,
                teacher: teacher,
                classroom: classroom,
                description: "",
                weeks: weeks,
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                campus: "",
                number: "",
                credit: credit,
                hour: 0,
                type: "",
                category: "",
                department: ""
            )
        }
    }

    let courses: [CompactCourse]

    init(cache: ScheduleCache) {
        courses = cache.courses.map(CompactCourse.init(course:))
    }

    var isEmpty: Bool { courses.isEmpty }

    func expandedPayload(using cache: ScheduleCache, importedAt: Date = Date()) -> ScheduleExportPayload {
        ScheduleExportPayload(
            formatVersion: 1,
            exportedAt: importedAt,
            currentTerm: cache.currentTerm,
            firstDayString: cache.firstDayString,
            timeTable: cache.timeTable,
            courses: courses.map { $0.expandedCourse(term: cache.currentTerm) }
        )
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let version = try container.decode(Int.self)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的紧凑课表分享格式版本：\(version)"
            )
        }

        var coursesContainer = try container.nestedUnkeyedContainer()
        var decodedCourses: [CompactCourse] = []
        while !coursesContainer.isAtEnd {
            decodedCourses.append(try coursesContainer.decode(CompactCourse.self))
        }
        courses = decodedCourses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(Self.formatVersion)
        try container.encode(courses)
    }
}

enum ScheduleShareCodeError: LocalizedError, Equatable {
    case empty
    case unsupportedNewerFormat(Int)
    case invalidFormat
    case invalidBase64
    case compressionFailed
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .empty:
            "请输入或粘贴课表编码。"
        case let .unsupportedNewerFormat(version):
            "该课表使用 BIT101SCH\(version) 格式，请更新 BIT101 后再导入。"
        case .invalidFormat:
            "课表编码格式不正确。"
        case .invalidBase64:
            "课表编码无法解码。"
        case .compressionFailed:
            "课表压缩失败。"
        case .decompressionFailed:
            "课表编码解压失败。"
        }
    }
}

/// 课表分享码的唯一编解码入口；默认导出 V3，导入继续兼容 V1/V2/V3。
enum ScheduleShareCodeCodec {
    static let latestVersion = 3
    static let supportedPrefixes = ["BIT101SCH1:", "BIT101SCH2:", "BIT101SCH3:"]

    static func encodeLatest(cache: ScheduleCache) throws -> String {
        let payload = ScheduleExportCompactPayloadV3(cache: cache)
        let jsonData = try JSONEncoder().encode(payload)
        guard let compressedData = try (jsonData as NSData).compressed(using: .lzfse) as Data? else {
            throw ScheduleShareCodeError.compressionFailed
        }
        return "BIT101SCH3:\(compressedData.base64EncodedString())"
    }

    static func decode(_ text: String, using cache: ScheduleCache) throws -> ScheduleExportPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScheduleShareCodeError.empty }

        if !supportedPrefixes.contains(where: trimmed.hasPrefix),
           let version = declaredVersion(in: trimmed),
           version > latestVersion
        {
            throw ScheduleShareCodeError.unsupportedNewerFormat(version)
        }

        guard let prefix = supportedPrefixes.first(where: trimmed.hasPrefix) else {
            throw ScheduleShareCodeError.invalidFormat
        }
        let body = String(trimmed.dropFirst(prefix.count))
        guard let compressedData = Data(base64Encoded: body) else {
            throw ScheduleShareCodeError.invalidBase64
        }
        guard let jsonData = try (compressedData as NSData).decompressed(using: .lzfse) as Data? else {
            throw ScheduleShareCodeError.decompressionFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch prefix {
        case "BIT101SCH1:":
            return try decoder.decode(ScheduleExportPayload.self, from: jsonData)
        case "BIT101SCH2:":
            return try decoder.decode(ScheduleExportCompactPayloadV2.self, from: jsonData)
                .expandedPayload(using: cache)
        case "BIT101SCH3:":
            return try decoder.decode(ScheduleExportCompactPayloadV3.self, from: jsonData)
                .expandedPayload(using: cache)
        default:
            throw ScheduleShareCodeError.invalidFormat
        }
    }

    private static func declaredVersion(in code: String) -> Int? {
        let marker = "BIT101SCH"
        guard code.hasPrefix(marker), let colon = code.firstIndex(of: ":") else { return nil }
        let start = code.index(code.startIndex, offsetBy: marker.count)
        guard start < colon else { return nil }
        return Int(code[start ..< colon])
    }
}
