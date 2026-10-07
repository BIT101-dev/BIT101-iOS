import Foundation
import ScheduleDomain

/// 相对已确认基线合并独立编辑；同一记录的分歧交给现有冲突选择。
nonisolated enum ScheduleCloudStateMerge {
    static func baseline(for cache: ScheduleCache) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ScheduleCloudSyncState(cache: cache))
    }

    static func merge(local: ScheduleCloudSyncState, remote: ScheduleCloudSyncState,
                      baseline: Data) throws -> ScheduleCloudSyncState? {
        let base = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] ?? [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lhs = try JSONSerialization.jsonObject(with: encoder.encode(local)) as? [String: Any] ?? [:]
        let rhs = try JSONSerialization.jsonObject(with: encoder.encode(remote)) as? [String: Any] ?? [:]
        // 校区与所属教学楼共同维护选择身份。
        let campusKeys: Set<String> = ["selectedCampusName", "selectedCampusCode", "selectedBuildingID"]
        guard case .merged(let campus) = try choose(base.filter { campusKeys.contains($0.key) },
            lhs.filter { campusKeys.contains($0.key) }, rhs.filter { campusKeys.contains($0.key) }) else { return nil }
        var result = campus as? [String: Any] ?? [:]
        for key in Set(base.keys).union(lhs.keys).union(rhs.keys).subtracting(campusKeys) {
            let value: Value
            switch key {
            case "customSchedules", "manualDDLEvents", "sharedSchedules":
                value = try mergeRecords(base[key], lhs[key], rhs[key])
            case "lexueDDLCompletionByID":
                value = try mergeDictionary(base[key], lhs[key], rhs[key])
            case "manualCourseRulesByTerm":
                value = try mergeDictionary(base[key], lhs[key], rhs[key], records: true)
            default:
                value = try choose(base[key], lhs[key], rhs[key])
            }
            switch value {
            case .conflict: return nil
            case .merged(let selected): result[key] = selected
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScheduleCloudSyncState.self,
            from: JSONSerialization.data(withJSONObject: result))
    }

    private enum Value { case conflict, merged(Any?) }

    private static func bytes(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func choose(_ base: Any?, _ lhs: Any?, _ rhs: Any?) throws -> Value {
        if try bytes(lhs) == bytes(rhs) { return .merged(lhs) }
        if try bytes(lhs) == bytes(base) { return .merged(rhs) }
        if try bytes(rhs) == bytes(base) { return .merged(lhs) }
        return .conflict
    }

    private static func mergeRecords(_ base: Any?, _ lhs: Any?, _ rhs: Any?) throws -> Value {
        func keyed(_ value: Any?) throws -> [String: Any] {
            var result: [String: Any] = [:]
            for row in value as? [[String: Any]] ?? [] {
                guard let id = row["id"] as? String, result[id] == nil else { throw CocoaError(.coderReadCorrupt) }
                result[id] = row
            }
            return result
        }
        let value = try mergeDictionary(keyed(base), keyed(lhs), keyed(rhs))
        switch value {
        case .conflict: return .conflict
        case .merged(let selected):
            let rows = selected as? [String: Any] ?? [:]
            return .merged(rows.keys.sorted().compactMap { rows[$0] })
        }
    }

    private static func mergeDictionary(_ base: Any?, _ lhs: Any?, _ rhs: Any?, records: Bool = false) throws -> Value {
        let base = base as? [String: Any] ?? [:]
        let lhs = lhs as? [String: Any] ?? [:]
        let rhs = rhs as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        for key in Set(base.keys).union(lhs.keys).union(rhs.keys) {
            let selected = try records ? mergeRecords(base[key], lhs[key], rhs[key]) : choose(base[key], lhs[key], rhs[key])
            switch selected {
            case .conflict: return .conflict
            case .merged(let value): result[key] = value
            }
        }
        return .merged(result)
    }
}
