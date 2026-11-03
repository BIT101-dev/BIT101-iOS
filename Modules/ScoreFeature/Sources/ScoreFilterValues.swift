import Foundation

extension ScoreViewModel {
    /// 提取筛选项并保留原始出现顺序，缺失字段归入“未分类”。
    func uniqueFilterValues(from source: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for item in source {
            let trimmed = normalizedFilterValue(item)
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            values.append(trimmed)
        }
        return values
    }

    /// 课程号和名称比较时忽略空白及大小写差异。
    func normalizedCourseIdentity(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    func normalizedFilterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }
}
