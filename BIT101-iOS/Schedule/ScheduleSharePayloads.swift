import Foundation

/// 课表导出文件的精简载荷。
///
/// 课表导出用于分享排课信息，载荷保留：
/// - 学期
/// - 首周
/// - 时间表
/// - 课程
///
/// DDL、考试、自定义日程和个人显示偏好继续保留在本机。
struct ScheduleExportPayload {
    let exportedAt: Date
    let currentTerm: String
    let firstDayString: String
    let timeTable: [TimeSlot]
    let courses: [CourseRecord]

    init(
        exportedAt: Date,
        currentTerm: String,
        firstDayString: String,
        timeTable: [TimeSlot],
        courses: [CourseRecord]
    ) {
        self.exportedAt = exportedAt
        self.currentTerm = currentTerm
        self.firstDayString = firstDayString
        self.timeTable = timeTable
        self.courses = courses
    }

    init(cache: ScheduleCache, exportedAt: Date = Date()) {
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

private func makeExpandedPayload(
    importedAt: Date,
    cache: ScheduleCache,
    courses: [CourseRecord]
) -> ScheduleExportPayload {
    ScheduleExportPayload(
        exportedAt: importedAt,
        currentTerm: cache.currentTerm,
        firstDayString: cache.firstDayString,
        timeTable: cache.timeTable,
        courses: courses
    )
}

private func makeExpandedCourse(
    term: String,
    name: String,
    teacher: String,
    classroom: String,
    weeks: [Int],
    weekday: Int,
    startSection: Int,
    endSection: Int,
    credit: Int
) -> CourseRecord {
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

/// 课表分享编码的紧凑载荷 V2。
///
/// 该载荷服务于较早紧凑分享码的导入，当前导出端使用 V3。
///
/// ## 设计约束
/// - 继续复用现有外层包装：`lzfse + base64`
/// - 压缩前数据继续使用 JSON，保留现有协议结构
/// - JSON 使用**纯数组结构**，字段含义由固定位置表达
/// - 载荷范围限定为“排课骨架”，运行环境继续由本机维护
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
/// - 每一门课都按固定顺序编码成 7 项数组，字段含义由位置表达
///
/// ## 导入时使用的本机信息
/// V2 载荷范围限定为课程排布，导入时从本机缓存读取以下信息：
/// - 首周日期
/// - 时间表
/// - 考试
/// - DDL
/// - 自定义日程
/// - 课表显示偏好
///
/// 分享课表复用“课程排布”，发送方的本地环境留在发送方。
/// 当前产品流程要求用户在导入或查看分享课表前先同步自己的课表；
/// 因此导入时可直接复用本机现有的：
/// - `currentTerm`
/// - `firstDayString`
/// - `timeTable`
///
/// ## 兼容策略
/// 新版默认导出 `BIT101SCH3`；导入端继续支持 `BIT101SCH2` 和 `BIT101SCH3`。
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

        /// 把极简课程扩展成完整的 `CourseRecord`。
        ///
        /// 导入使用本机现有课表环境补全字段。
        /// 当前策略是：
        /// - `term` 复用本机当前学期
        /// - 其余未分享字段统一回填为空或 0
        ///
        /// V2 作为兼容导入格式保留，协议定义和导入落地逻辑放在同一处，格式切换时可以沿用同一入口。
        func expandedCourse(term: String) -> CourseRecord {
            makeExpandedCourse(
                term: term,
                name: name,
                teacher: teacher,
                classroom: classroom,
                weeks: weeks,
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                credit: 0
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

    /// V2 使用导入侧本机环境生成统一的课表载荷。
    func expandedPayload(using cache: ScheduleCache, importedAt: Date = Date()) -> ScheduleExportPayload {
        makeExpandedPayload(
            importedAt: importedAt,
            cache: cache,
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
            makeExpandedCourse(
                term: term,
                name: name,
                teacher: teacher,
                classroom: classroom,
                weeks: weeks,
                weekday: weekday,
                startSection: startSection,
                endSection: endSection,
                credit: credit
            )
        }
    }

    let courses: [CompactCourse]

    init(cache: ScheduleCache) {
        courses = cache.courses.map(CompactCourse.init(course:))
    }

    var isEmpty: Bool { courses.isEmpty }

    func expandedPayload(using cache: ScheduleCache, importedAt: Date = Date()) -> ScheduleExportPayload {
        makeExpandedPayload(
            importedAt: importedAt,
            cache: cache,
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

/// 课表分享码统一由此编解码；默认导出 V3，导入继续兼容 V2/V3。
enum ScheduleShareCodeCodec {
    static let latestVersion = 3
    static let supportedPrefixes = ["BIT101SCH2:", "BIT101SCH3:"]

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
        switch prefix {
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
