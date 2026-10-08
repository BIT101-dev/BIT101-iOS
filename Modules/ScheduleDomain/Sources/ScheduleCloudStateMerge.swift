import Foundation

/// 相对已确认基线合并独立编辑；同一记录的分歧交给现有冲突选择。
public nonisolated enum ScheduleCloudStateMerge {
    public static func baseline(for cache: ScheduleCache) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ScheduleCloudSyncState(cache: cache))
    }

    public static func merge(local: ScheduleCloudSyncState, remote: ScheduleCloudSyncState,
                      baseline: Data, resolution: ScheduleCacheConflictResolution? = nil) throws -> ScheduleCloudSyncState? {
        let base = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] ?? [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lhs = try JSONSerialization.jsonObject(with: encoder.encode(local)) as? [String: Any] ?? [:]
        let rhs = try JSONSerialization.jsonObject(with: encoder.encode(remote)) as? [String: Any] ?? [:]
        // 校区与所属教学楼共同维护选择身份。
        let campusKeys: Set<String> = ["selectedCampusName", "selectedCampusCode", "selectedBuildingID"]
        guard case .merged(let campus) = try choose(base.filter { campusKeys.contains($0.key) },
            lhs.filter { campusKeys.contains($0.key) }, rhs.filter { campusKeys.contains($0.key) }, resolution: resolution) else { return nil }
        var result = campus as? [String: Any] ?? [:]
        for key in Set(base.keys).union(lhs.keys).union(rhs.keys).subtracting(campusKeys) {
            let value: Value
            switch key {
            case "customSchedules", "manualDDLEvents", "sharedSchedules":
                value = try mergeRecords(base[key], lhs[key], rhs[key], resolution: resolution)
            case "lexueDDLCompletionByID":
                value = try mergeDictionary(base[key], lhs[key], rhs[key], resolution: resolution)
            case "schoolDDLCompletionRetiredAtByID":
                value = try mergeDictionary(base[key], lhs[key], rhs[key], earliestDate: true, resolution: resolution)
            case "manualCourseRulesByTerm":
                value = try mergeDictionary(base[key], lhs[key], rhs[key], records: true, resolution: resolution)
            default:
                value = try choose(base[key], lhs[key], rhs[key], resolution: resolution)
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

    private static func choose(_ base: Any?, _ lhs: Any?, _ rhs: Any?, resolution: ScheduleCacheConflictResolution? = nil) throws -> Value {
        if try bytes(lhs) == bytes(rhs) { return .merged(lhs) }
        if try bytes(lhs) == bytes(base) { return .merged(rhs) }
        if try bytes(rhs) == bytes(base) { return .merged(lhs) }
        switch resolution {
        case .keepLocal: return .merged(lhs)
        case .useCloud: return .merged(rhs)
        case nil: return .conflict
        }
    }

    private static func mergeRecords(_ base: Any?, _ lhs: Any?, _ rhs: Any?, resolution: ScheduleCacheConflictResolution?) throws -> Value {
        func keyed(_ value: Any?) throws -> [String: Any] {
            var result: [String: Any] = [:]
            for row in value as? [[String: Any]] ?? [] {
                guard let id = row["id"] as? String, result[id] == nil else { throw CocoaError(.coderReadCorrupt) }
                result[id] = row
            }
            return result
        }
        let baseRows = try keyed(base), localRows = try keyed(lhs), remoteRows = try keyed(rhs)
        if case .merged(let selected) = try choose(base, lhs, rhs) { return .merged(selected) }
        let value = try mergeDictionary(baseRows, localRows, remoteRows, resolution: resolution)
        switch value {
        case .conflict: return .conflict
        case .merged(let selected):
            let rows = selected as? [String: Any] ?? [:]
            func retainedOrder(_ value: Any?) -> [String] {
                (value as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    .filter { baseRows[$0] != nil && rows[$0] != nil }
            }
            guard case .merged(let order) = try choose(retainedOrder(base), retainedOrder(lhs), retainedOrder(rhs), resolution: resolution)
            else { return .conflict }
            let ordered = order as? [String] ?? []
            let retainedIDs = Set(ordered)
            let remaining = rows.keys.filter { !retainedIDs.contains($0) }.sorted()
            return .merged((ordered + remaining).compactMap { rows[$0] })
        }
    }

    private static func mergeDictionary(_ base: Any?, _ lhs: Any?, _ rhs: Any?, records: Bool = false, earliestDate: Bool = false, resolution: ScheduleCacheConflictResolution?) throws -> Value {
        let base = base as? [String: Any] ?? [:]
        let lhs = lhs as? [String: Any] ?? [:]
        let rhs = rhs as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        for key in Set(base.keys).union(lhs.keys).union(rhs.keys) {
            let selected = try records ? mergeRecords(base[key], lhs[key], rhs[key], resolution: resolution) : choose(base[key], lhs[key], rhs[key], resolution: earliestDate ? nil : resolution)
            switch selected {
            case .conflict:
                if earliestDate, let local = lhs[key] as? String, let remote = rhs[key] as? String {
                    result[key] = min(local, remote)
                } else { return .conflict }
            case .merged(let value): result[key] = value
            }
        }
        return .merged(result)
    }
}
