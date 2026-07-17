import Foundation

/// 空教室列表里的教室名自然升序比较器。
///
/// 这里使用 `localizedStandardCompare`，让 `101 -> 102 -> 103` 这类教室名
/// 按人类直觉排序，而不是简单字典序。
func classroomNameAscending(_ lhs: ClassroomAvailability, _ rhs: ClassroomAvailability) -> Bool {
    let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)

    switch (lhsName.isEmpty, rhsName.isEmpty) {
    case (true, false):
        return false
    case (false, true):
        return true
    default:
        break
    }

    let nameOrder = lhsName.localizedStandardCompare(rhsName)
    if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
    }

    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
}

