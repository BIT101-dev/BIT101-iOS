//
//  ScheduleStringParsing.swift
//  BIT101-iOS
//

import Foundation

/// 返回字符串中首个匹配结果的捕获组。
///
/// 无捕获组时返回完整匹配；可选捕获组缺少匹配文本时返回空字符串。
/// 无效正则表达式和匹配失败时返回空数组。
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

        return (1 ..< match.numberOfRanges).map { index in
            let capture = match.range(at: index)
            guard capture.location != NSNotFound,
                  let captureRange = Range(capture, in: self)
            else {
                return ""
            }
            return String(self[captureRange])
        }
    }
}
