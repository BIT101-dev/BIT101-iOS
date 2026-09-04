import Foundation

/// 日程相关跨 target 共用的展示规范化工具。
///
/// 当前主要收口两类“看起来一样、但之前散落在多处”的规则：
/// - 教室名称缩写
/// - 课程标题压缩
///
/// 这样主 App、widget、watch、Live Activity 后续只需要维护这一份展示约定。
enum ScheduleDisplayNormalizer {
    /// 压缩教室名称里的冗长楼名，提升小屏与卡片场景下的可读性。
    static func normalizeClassroom(_ value: String) -> String {
        compactLocation(for: value).lightText
    }

    /// 对课程标题做本地展示优化。
    ///
    /// 目前主要把 `体育/xx` 压缩成 `xx`，并把中文全角括号改成半角括号。
    static func normalizeCourseTitle(_ value: String) -> String {
        let withoutSportsPrefix = value.hasPrefix("体育/")
            ? String(value.dropFirst("体育/".count))
            : value
        return withoutSportsPrefix
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    /// 课程卡片使用“楼房\n教室”的紧凑地点格式；无法可靠拆分时保留压缩后的原文。
    static func courseCardClassroomText(_ value: String) -> String {
        let location = compactLocation(for: value)
        guard let room = location.room,
              !location.lightBuilding.isEmpty,
              !room.isEmpty
        else {
            return location.lightText
        }

        // 教学楼后缀字母属于教室编号的一部分，例如“文萃楼I101”显示为“文萃\nI101”。
        let building = location.lightBuilding
        let suffix = String(building.suffix(1))
        let buildingPrefix = String(building.dropLast())
        if !buildingPrefix.isEmpty,
           suffix.unicodeScalars.count == 1,
           suffix.rangeOfCharacter(from: .letters) != nil,
           suffix.unicodeScalars.first?.value ?? 0 < 128
        {
            return "\(buildingPrefix)\(suffix)\n\(room)"
        }

        return "\(building)\n\(room)"
    }

    /// 将地点压缩成 complication 友好的楼名 / 教室结构。
    static func compactLocation(for value: String) -> ScheduleCompactLocation {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ScheduleCompactLocation(lightText: "", maxText: "", lightBuilding: "", maxBuilding: "", room: nil)
        }

        let normalizedLightText = normalizeLocationText(trimmed, mode: .light)
        let normalizedMaxText = normalizeLocationText(trimmed, mode: .max)

        let buildingPair = normalizedBuildingPair(
            lightText: normalizedLightText,
            maxText: normalizedMaxText
        )
        let room = extractRoom(from: normalizedLightText, building: buildingPair.light)

        return ScheduleCompactLocation(
            lightText: normalizedLightText,
            maxText: normalizedMaxText,
            lightBuilding: buildingPair.light,
            maxBuilding: buildingPair.max,
            room: room
        )
    }

    private enum LocationAbbreviationMode {
        case light
        case max
    }

    private struct LocationAbbreviationRule {
        let source: String
        let light: String
        let max: String
    }

    private static let campusPrefixes = [
        "良乡校区",
        "中关村校区",
        "珠海校区",
    ]

    private static let locationAbbreviationRules: [LocationAbbreviationRule] = {
        var rules: [LocationAbbreviationRule] = [
            .init(source: "中关村体育馆地下羽毛球场", light: "馆羽", max: "馆羽"),
            .init(source: "中关村体育馆北厅140", light: "馆北厅", max: "馆北"),
            .init(source: "良乡体育馆羽毛球场", light: "馆羽", max: "馆羽"),
            .init(source: "良乡体育馆篮球场", light: "馆篮", max: "馆篮"),
            .init(source: "良乡体育馆健身房", light: "馆健", max: "馆健"),
            .init(source: "体育馆乐团排练厅", light: "馆排练", max: "馆排"),
            .init(source: "体育馆夹层J13", light: "馆J13", max: "馆J13"),
            .init(source: "羽毛球场（乒羽中心）", light: "羽球场", max: "羽球"),
            .init(source: "轮滑场（西排球场）", light: "轮滑场", max: "轮滑"),
            .init(source: "南校区排球场", light: "南排", max: "南排"),
            .init(source: "南校区篮球场", light: "南篮", max: "南篮"),
            .init(source: "南校区网球场", light: "南网", max: "南网"),
            .init(source: "南校区足球场", light: "南足", max: "南足"),
            .init(source: "游泳馆浅水区北侧", light: "游泳馆", max: "游泳"),
            .init(source: "游泳馆浅水区南侧", light: "游泳馆", max: "游泳"),
            .init(source: "游泳馆深水区", light: "游泳馆", max: "游泳"),
            .init(source: "文体综合馆", light: "文体馆", max: "文体"),
            .init(source: "篮球训练场", light: "篮球场", max: "篮球"),
            .init(source: "足球场", light: "足球场", max: "足球"),
            .init(source: "田径场主席台", light: "操场", max: "操场"),
            .init(source: "中关村东操场主席台", light: "操场", max: "操场"),
            .init(source: "田径场", light: "田径场", max: "田径"),
            .init(source: "法学院智慧法治实验室", light: "法学楼", max: "法学"),
            .init(source: "前沿交叉大楼", light: "前沿楼", max: "前沿"),
            .init(source: "综合教学楼A", light: "综教A", max: "综A"),
            .init(source: "综合教学楼B", light: "综教B", max: "综B"),
            .init(source: "综教A", light: "综教A", max: "综A"),
            .init(source: "综教B", light: "综教B", max: "综B"),
            .init(source: "理科教学楼", light: "理教", max: "理教"),
            .init(source: "工科实训楼", light: "工训", max: "工训"),
            .init(source: "工程训练中心", light: "工训", max: "工训"),
            .init(source: "良乡实训楼", light: "工训", max: "工训"),
            .init(source: "实训楼", light: "工训", max: "工训"),
            .init(source: "理学楼C座", light: "理学楼", max: "理学"),
            .init(source: "理学楼A", light: "理学楼", max: "理学"),
            .init(source: "理学B2", light: "理学楼", max: "理学"),
            .init(source: "理学C1", light: "理学楼", max: "理学"),
            .init(source: "理学C", light: "理学楼", max: "理学"),
            .init(source: "5号教学楼", light: "5号楼", max: "5号"),
            .init(source: "6号教学楼", light: "6号楼", max: "6号"),
            .init(source: "9号教学楼", light: "9号楼", max: "9号"),
            .init(source: "疏桐园A地下", light: "疏桐", max: "疏桐"),
            .init(source: "良乡体育馆", light: "体馆", max: "体馆"),
            .init(source: "交叉大楼", light: "交叉楼", max: "交叉"),
            .init(source: "行政楼", light: "行政楼", max: "行政"),
            .init(source: "天佑楼T", light: "天佑楼", max: "天佑"),
            .init(source: "工业生态楼", light: "工业楼", max: "工业"),
            .init(source: "化学实验中心", light: "化学楼", max: "化学"),
            .init(source: "宇航楼", light: "宇航楼", max: "宇航"),
            .init(source: "西山阻燃中心", light: "西山", max: "西山"),
            .init(source: "南操场", light: "南操场", max: "操场"),
            .init(source: "5号楼", light: "5号楼", max: "5号"),
            .init(source: "6号楼", light: "6号楼", max: "6号"),
            .init(source: "8号楼", light: "8号楼", max: "8号"),
            .init(source: "9号楼", light: "9号楼", max: "9号"),
            .init(source: "3号楼", light: "3号楼", max: "3号"),
            .init(source: "主楼", light: "主楼", max: "主楼"),
            .init(source: "中教", light: "中教", max: "中教"),
            .init(source: "研楼", light: "研楼", max: "研楼"),
            .init(source: "理教楼", light: "理教", max: "理教"),
        ]

        for suffix in UInt8(ascii: "A")...UInt8(ascii: "M") {
            let letter = String(UnicodeScalar(suffix))
            rules.append(.init(source: "文萃楼\(letter)", light: "文萃\(letter)", max: "文\(letter)"))
        }

        return rules.sorted { lhs, rhs in
            if lhs.source.count != rhs.source.count {
                return lhs.source.count > rhs.source.count
            }
            return lhs.source > rhs.source
        }
    }()

    private static let knownBuildingPairs: [(light: String, max: String)] = {
        var pairs = locationAbbreviationRules.map { ($0.light, $0.max) }
        pairs.append(("综教A", "综A"))
        pairs.append(("综教B", "综B"))
        for suffix in UInt8(ascii: "A")...UInt8(ascii: "M") {
            let letter = String(UnicodeScalar(suffix))
            pairs.append(("文萃\(letter)", "文\(letter)"))
        }
        return Array(Set(pairs.map { "\($0.0)\u{0}\($0.1)" }))
            .map { token in
                let parts = token.split(separator: "\u{0}", maxSplits: 1).map(String.init)
                return (parts[0], parts[1])
            }
            .sorted { lhs, rhs in
                if lhs.0.count != rhs.0.count {
                    return lhs.0.count > rhs.0.count
                }
                return lhs.0 > rhs.0
            }
    }()

    private static func normalizeLocationText(_ value: String, mode: LocationAbbreviationMode) -> String {
        var normalized = value

        for prefix in campusPrefixes {
            normalized = normalized.replacingOccurrences(of: prefix, with: "")
        }

        for rule in locationAbbreviationRules {
            normalized = normalized.replacingOccurrences(
                of: rule.source,
                with: mode == .light ? rule.light : rule.max
            )
        }

        return normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "－", with: "")
            .replacingOccurrences(of: "—", with: "")
            .replacingOccurrences(of: "–", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBuildingPair(lightText: String, maxText: String) -> (light: String, max: String) {
        if let pair = knownBuildingPairs.first(where: { lightText.hasPrefix($0.light) }) {
            return pair
        }

        return (lightText, maxText)
    }

    private static func extractRoom(from text: String, building: String) -> String? {
        guard text.hasPrefix(building) else { return nil }
        let room = String(text.dropFirst(building.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return nil }
        return room
    }
}

/// complication 展示时使用的地点结构。
struct ScheduleCompactLocation: Hashable {
    let lightText: String
    let maxText: String
    let lightBuilding: String
    let maxBuilding: String
    let room: String?
}

/// 日程相关跨 target 共用的日期编解码与时间组合工具。
///
/// 共享层、小组件、watch、Live Activity 都依赖同一套“日期字符串 / 节次时间 -> 绝对时间”
/// 的规则，因此把重叠部分统一收口到这里，避免多个模块各自维护一份。
enum ScheduleSharedDateCodec {
    /// 固定使用公历，避免系统日历设置影响周数计算。
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd"
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

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return dateFormatter.date(from: string)
    }

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func formatShortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func combine(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = (week - 1) * 7 + (weekday - 1)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }
        return combine(date: day, time: time)
    }

    static func combine(date: Date, time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

/// 跨外部展示层共用的课程实例。
///
/// 它是把“周次 + 星期 + 节次”展开后的最终结果：
/// 拿到它之后，widget / watch / Live Activity 都可以直接做排序、展示和倒计时。
struct ScheduleExternalOccurrence: Identifiable, Hashable {
    let id: String
    let title: String
    let classroom: String
    let teacher: String
    let startDate: Date
    let endDate: Date
    let displayUntilDate: Date

    func isCurrent(at date: Date = Date()) -> Bool {
        startDate <= date && date < displayUntilDate
    }

    func countdownTargetDate(at date: Date = Date()) -> Date {
        isCurrent(at: date) ? displayUntilDate : startDate
    }

    var rangeText: String {
        "\(ScheduleSharedDateCodec.formatTime(startDate))-\(ScheduleSharedDateCodec.formatTime(endDate))"
    }

    func relativeDayText(referenceDate: Date = Date()) -> String {
        let startOfToday = Self.calendar.startOfDay(for: referenceDate)
        let startOfClassDay = Self.calendar.startOfDay(for: startDate)
        let dayDiff = Self.calendar.dateComponents([.day], from: startOfToday, to: startOfClassDay).day ?? 0

        switch dayDiff {
        case ...0:
            return "今天"
        case 1:
            return "明天"
        case 2:
            return "后天"
        case 3:
            return "大后天"
        default:
            return ScheduleSharedDateCodec.formatShortDate(startDate)
        }
    }

    private static let calendar = ScheduleSharedDateCodec.calendar
}

/// 外部展示层使用的“快照 + 未来课程”解析结果。
///
/// watch app、watch widget 等消费方经常会重复做三件事：
/// 1. 读取共享快照
/// 2. 推导未来课程
/// 3. 取出第一节作为“当前 / 下一节”
///
/// 这里把这套胶水逻辑收成一个轻量结果，避免各端各写一遍。
struct ScheduleExternalResolvedSnapshot {
    let snapshot: ScheduleExternalSnapshot?
    let upcomingOccurrences: [ScheduleExternalOccurrence]
    let contentState: ScheduleExternalContentState

    var nextOccurrence: ScheduleExternalOccurrence? {
        upcomingOccurrences.first
    }
}

/// 外部课表展示层共同消费的业务状态。
///
/// 文案仍由各端决定，但状态含义必须一致，避免同一份损坏快照在手机 Widget 显示
/// “请同步”，在 Watch 上却显示“今天没课”。
enum ScheduleExternalContentState: Equatable {
    case missing
    case loggedOut
    case invalid
    case rest
    case ready
}

/// Widget 时间线的统一刷新时间规划器。
enum ScheduleTimelineRefreshPlanner {
    static func nextRefreshDate(
        for occurrences: [ScheduleExternalOccurrence],
        now: Date = Date(),
        includeDisplayUntilDates: Bool,
        includeNextMidnight: Bool,
        fallbackInterval: TimeInterval = 30 * 60
    ) -> Date {
        let threshold = now.addingTimeInterval(30)
        var candidates = occurrences.map(\.startDate)

        if includeDisplayUntilDates {
            candidates.append(contentsOf: occurrences.map(\.displayUntilDate))
        }

        if includeNextMidnight,
           let nextMidnight = ScheduleSharedDateCodec.calendar.date(
               byAdding: .day,
               value: 1,
               to: ScheduleSharedDateCodec.calendar.startOfDay(for: now)
           )?.addingTimeInterval(1) {
            candidates.append(nextMidnight)
        }

        return candidates
            .filter { $0 > threshold }
            .min()
            ?? now.addingTimeInterval(fallbackInterval)
    }
}

/// 共享快照到课程 occurrence 的统一解析器。
///
/// 当前 widget 与未来 watch 端都应该复用它，避免各自维护一套“首周 + 周次 + 节次 -> 实际上课时间”的推导逻辑。
enum ScheduleOccurrenceResolver {
    static let defaultCurrentCourseDisplayDuration: TimeInterval = 5 * 60

    static func upcomingOccurrences(
        from snapshot: ScheduleExternalSnapshot,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration
    ) -> [ScheduleExternalOccurrence] {
        guard let firstDay = ScheduleSharedDateCodec.parseDate(snapshot.firstDayString) else {
            return []
        }

        let slotMap = Dictionary(uniqueKeysWithValues: snapshot.timeTable.map { ($0.id, $0) })

        let rawOccurrences = snapshot.courses
            .flatMap { course in
                course.weeks.compactMap { week -> ScheduleExternalOccurrence? in
                    guard
                        let startSlot = slotMap[course.startSection],
                        let endSlot = slotMap[course.endSection],
                        let startDate = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: startSlot.start),
                        let endDate = ScheduleSharedDateCodec.combine(firstDay: firstDay, week: week, weekday: course.weekday, time: endSlot.end),
                        endDate > now
                    else {
                        return nil
                    }

                    return ScheduleExternalOccurrence(
                        id: "\(course.id)-\(week)",
                        title: ScheduleDisplayNormalizer.normalizeCourseTitle(course.name),
                        classroom: ScheduleDisplayNormalizer.normalizeClassroom(course.classroom),
                        teacher: course.teacher,
                        startDate: startDate,
                        endDate: endDate,
                        displayUntilDate: endDate
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title < rhs.title
            }

        return rawOccurrences.enumerated().compactMap { index, occurrence in
            let hasLaterOccurrence = rawOccurrences.indices.contains(index + 1)
            let displayUntilDate: Date

            if hasLaterOccurrence {
                displayUntilDate = min(
                    occurrence.endDate,
                    occurrence.startDate.addingTimeInterval(currentCourseDisplayDuration)
                )
            } else {
                displayUntilDate = occurrence.endDate
            }

            guard displayUntilDate > now else {
                return nil
            }

            return ScheduleExternalOccurrence(
                id: occurrence.id,
                title: occurrence.title,
                classroom: occurrence.classroom,
                teacher: occurrence.teacher,
                startDate: occurrence.startDate,
                endDate: occurrence.endDate,
                displayUntilDate: displayUntilDate
            )
        }
    }

    static func parseDate(_ string: String) -> Date? {
        ScheduleSharedDateCodec.parseDate(string)
    }

    /// 从一份共享快照解析外部展示层真正关心的最小状态。
    ///
    /// `limit` 允许 watch 这类小屏设备只保留前若干节候选，
    /// 从而在不改变 UI 的前提下减少重复切片与状态分发逻辑。
    static func resolvedSnapshot(
        from snapshot: ScheduleExternalSnapshot?,
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        guard let snapshot else {
            return ScheduleExternalResolvedSnapshot(
                snapshot: nil,
                upcomingOccurrences: [],
                contentState: .missing
            )
        }

        guard snapshot.isLoggedIn else {
            return ScheduleExternalResolvedSnapshot(
                snapshot: snapshot,
                upcomingOccurrences: [],
                contentState: .loggedOut
            )
        }

        guard ScheduleSharedDateCodec.parseDate(snapshot.firstDayString) != nil else {
            return ScheduleExternalResolvedSnapshot(
                snapshot: snapshot,
                upcomingOccurrences: [],
                contentState: .invalid
            )
        }

        // 已同步的空学期是有效业务结果，不能与“从未获取课表”混为 invalid。
        guard !snapshot.courses.isEmpty else {
            return ScheduleExternalResolvedSnapshot(
                snapshot: snapshot,
                upcomingOccurrences: [],
                contentState: .rest
            )
        }

        // 只有真正需要解析课程时，缺失节次表才是损坏快照。
        guard !snapshot.timeTable.isEmpty else {
            return ScheduleExternalResolvedSnapshot(
                snapshot: snapshot,
                upcomingOccurrences: [],
                contentState: .invalid
            )
        }

        let occurrences = upcomingOccurrences(
            from: snapshot,
            now: now,
            currentCourseDisplayDuration: currentCourseDisplayDuration
        )
        let trimmedOccurrences: [ScheduleExternalOccurrence]
        if let limit, limit >= 0 {
            trimmedOccurrences = Array(occurrences.prefix(limit))
        } else {
            trimmedOccurrences = occurrences
        }

        return ScheduleExternalResolvedSnapshot(
            snapshot: snapshot,
            upcomingOccurrences: trimmedOccurrences,
            contentState: trimmedOccurrences.isEmpty ? .rest : .ready
        )
    }

    /// 直接从共享仓库读取并解析。
    static func loadResolvedSnapshot(
        now: Date = Date(),
        currentCourseDisplayDuration: TimeInterval = defaultCurrentCourseDisplayDuration,
        limit: Int? = nil
    ) -> ScheduleExternalResolvedSnapshot {
        resolvedSnapshot(
            from: ScheduleExternalSnapshotStore.load(),
            now: now,
            currentCourseDisplayDuration: currentCourseDisplayDuration,
            limit: limit
        )
    }
}
