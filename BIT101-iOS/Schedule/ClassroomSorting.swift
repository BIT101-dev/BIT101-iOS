import Foundation

/// 按教室名自然升序排列空教室，空名称排在末尾，名称相同时按 `id` 排序。
///
/// `localizedStandardCompare` 为 `101 -> 102 -> 103` 这类教室名提供人类直觉排序。
func classroomNameAscending(_ lhs: ClassroomAvailability, _ rhs: ClassroomAvailability) -> Bool {
    let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)

    if lhsName.isEmpty != rhsName.isEmpty {
        return !lhsName.isEmpty
    }

    let nameOrder = lhsName.localizedStandardCompare(rhsName)
    if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
    }

    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
}
