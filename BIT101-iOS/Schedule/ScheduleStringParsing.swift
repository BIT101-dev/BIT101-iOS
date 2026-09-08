//
//  ScheduleStringParsing.swift
//  BIT101-iOS
//

import Foundation

/// 返回字符串中首个匹配结果的捕获组。
///
/// 正则表达式没有捕获组时返回完整匹配；正则表达式无效或未找到匹配时返回空数组。
extension String {
    func captureGroups(pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range) else {
            return []
        }

        guard match.numberOfRanges > 1 else {
            guard let range = Range(match.range, in: self) else { return [] }
            return [String(self[range])]
        }

        return (1 ..< match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: self) else {
                return nil
            }
            return String(self[captureRange])
        }
    }
}
