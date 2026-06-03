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
/// 当前导出端默认使用这套协议，V1 仍保留为导入兼容格式。
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
/// 新版默认导出 `BIT101SCH2`；导入端继续支持 `BIT101SCH1`、`BIT101SCH2`，并预置 `BIT101SCH3` 解码。
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
/// V3 在 V2 的课程排布骨架上追加学分字段。当前只预置解码能力，导出端仍默认使用 V2。
///
/// 最外层布局固定为：
///
/// ```text
/// [
///   3,
///   [
///     [课程名, 教师, 教室, 周次数组, 星期, 开始节, 结束节, 学分],
///     ...
///   ]
/// ]
/// ```
struct ScheduleExportCompactPayloadV3: Codable {
    static let formatVersion = 3

    /// V3 内部单门课的极简表示。
    ///
    /// 字段顺序必须稳定；第 8 项 `credit` 是相对 V2 新增的学分字段。
    struct CompactCourse: Codable, Hashable {
        let name: String
        let teacher: String
        let classroom: String
        let weeks: [Int]
        let weekday: Int
        let startSection: Int
        let endSection: Int
        let credit: Int

        nonisolated init(
            name: String,
            teacher: String,
            classroom: String,
            weeks: [Int],
            weekday: Int,
            startSection: Int,
            endSection: Int,
            credit: Int
        ) {
            self.name = name
            self.teacher = teacher
            self.classroom = classroom
            self.weeks = weeks
            self.weekday = weekday
            self.startSection = startSection
            self.endSection = endSection
            self.credit = credit
        }

        nonisolated init(course: CourseRecord) {
            self.init(
                name: course.name,
                teacher: course.teacher,
                classroom: course.classroom,
                weeks: course.weeks,
                weekday: course.weekday,
                startSection: course.startSection,
                endSection: course.endSection,
                credit: course.credit
            )
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
        self.courses = cache.courses.map(CompactCourse.init(course:))
    }

    init(payload: ScheduleExportPayload) {
        self.courses = payload.courses.map(CompactCourse.init(course:))
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
            var course = try coursesContainer.nestedUnkeyedContainer()
            decodedCourses.append(
                CompactCourse(
                    name: try course.decode(String.self),
                    teacher: try course.decode(String.self),
                    classroom: try course.decode(String.self),
                    weeks: try course.decode([Int].self),
                    weekday: try course.decode(Int.self),
                    startSection: try course.decode(Int.self),
                    endSection: try course.decode(Int.self),
                    credit: try course.decode(Int.self)
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
            try encodedCourse.encode(course.credit)
        }
    }
}
