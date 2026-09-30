import Foundation

/// 成绩页面消费的学校课程摘要，由应用组装层投影。
public nonisolated struct ScoreCourseSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let term: String
    public let name: String
    public let number: String
    public let type: String
    public let teacher: String
    public let classroom: String
    public let campus: String
    public let description: String
    public let creditText: String
    public let scheduleText: String
    public let weeksText: String
    public let hourText: String

    public init(
        id: String,
        term: String,
        name: String,
        number: String,
        type: String,
        teacher: String,
        classroom: String,
        campus: String,
        description: String,
        creditText: String,
        scheduleText: String,
        weeksText: String,
        hourText: String
    ) {
        self.id = id
        self.term = term
        self.name = name
        self.number = number
        self.type = type
        self.teacher = teacher
        self.classroom = classroom
        self.campus = campus
        self.description = description
        self.creditText = creditText
        self.scheduleText = scheduleText
        self.weeksText = weeksText
        self.hourText = hourText
    }
}

/// 此结构表示单个成绩字段。
///
/// 服务端以二维表返回成绩；模型将表头和值保存为键值对，详情页复用这些字段。
public nonisolated struct ScoreField: Codable, Hashable, Sendable {
    public let key: String
    public let value: String
}

/// 此结构表示成绩表中的一行课程记录。
///
/// 模型保留原始表头和值的对应关系，并提供常用字段访问器。
public nonisolated struct ScoreRow: Codable, Identifiable, Sendable {
    public let id: String
    public let values: [ScoreField]

    /// 使用表头和值数组构造单行成绩记录。
    ///
    /// 模型按表头名称建立字段映射；接口字段顺序变化时，访问器仍按键名读取字段。
    public init(index: Int, headers: [String], values: [String]) {
        let pairs = zip(headers, values).map { ScoreField(key: $0, value: $1) }
        self.values = pairs

        let identifier = pairs.first(where: { $0.key == "序号" })?.value
            ?? pairs.first(where: { $0.key == "课程编号" })?.value
            ?? "\(index)"
        // 同一课程可能存在多条记录，追加接口行号保持列表标识唯一。
        id = "\(identifier)|\(index)"
    }

    /// 此下标器按原始表头读取任意字段，详情页使用它读取字段。
    public subscript(_ key: String) -> String {
        values.first(where: { $0.key == key })?.value ?? ""
    }

    public var courseName: String { self["课程名称"] }
    public var score: String { self["成绩"] }
    public var averageScore: String { self["平均分"] }
    public var creditText: String { self["学分"] }
    public var term: String { self["开课学期"] }
    public var courseType: String { self["课程性质"] }
    public var classRank: String { self["本人成绩在班级中占"] }
    public var majorRank: String { self["本人成绩在专业中占"] }
    public var courseNumber: String { self["课程编号"] }
    public var teachingClassesCompletionStatus: String {
        self["该课程所有教学班成绩录入完毕"]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 此属性将学分转换为数值，统计逻辑用该数值计算加权结果。
    public var numericCredit: Double? {
        Double(creditText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

