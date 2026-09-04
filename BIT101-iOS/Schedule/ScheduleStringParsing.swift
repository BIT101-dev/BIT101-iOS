//
//  ScheduleStringParsing.swift
//  BIT101-iOS
//

import Foundation

/// 正则捕获工具。
///
/// 这里只提供最小能力：返回首个命中的捕获组数组，供乐学和学校页面解析复用。
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
