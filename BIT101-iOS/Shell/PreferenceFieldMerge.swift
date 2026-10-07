import Foundation

/// 设置与筛选按字段维护版本，同版本分歧按规范编码排序收敛。
nonisolated enum PreferenceFieldMerge {
    static func recording<Payload: Codable>(
        _ payload: Payload,
        previous: ExperimentalPreferenceSyncEnvelope<Payload>?,
        at timestamp: Date
    ) throws -> ExperimentalPreferenceSyncEnvelope<Payload> {
        let values = try fields(payload)
        let oldValues = try previous.map { try fields($0.payload) } ?? [:]
        var versions = previous?.fieldUpdatedAt
            ?? Dictionary(uniqueKeysWithValues: oldValues.keys.map { ($0, previous?.updatedAt ?? .distantPast) })
        for key in Set(values.keys).union(oldValues.keys) {
            if try encoded(values[key]) != encoded(oldValues[key]) { versions[key] = timestamp }
        }
        return ExperimentalPreferenceSyncEnvelope(
            updatedAt: max(previous?.updatedAt ?? .distantPast, versions.values.max() ?? timestamp),
            payload: payload, fieldUpdatedAt: versions
        )
    }

    static func merging<Payload: Codable>(
        _ local: ExperimentalPreferenceSyncEnvelope<Payload>,
        _ remote: ExperimentalPreferenceSyncEnvelope<Payload>
    ) throws -> ExperimentalPreferenceSyncEnvelope<Payload> {
        let localValues = try fields(local.payload)
        let remoteValues = try fields(remote.payload)
        let keys = Set(localValues.keys).union(remoteValues.keys)
            .union(local.fieldUpdatedAt?.keys.map { $0 } ?? [])
            .union(remote.fieldUpdatedAt?.keys.map { $0 } ?? [])
        var values: [String: Any] = [:]
        var versions: [String: Date] = [:]
        for key in keys {
            let localDate = version(of: key, in: local)
            let remoteDate = version(of: key, in: remote)
            let remoteWinsTie = try encoded(localValues[key]).lexicographicallyPrecedes(encoded(remoteValues[key]))
            let useRemote = remoteDate > localDate || (remoteDate == localDate && remoteWinsTie)
            values[key] = useRemote ? remoteValues[key] : localValues[key]
            versions[key] = max(localDate, remoteDate)
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        return ExperimentalPreferenceSyncEnvelope(
            updatedAt: max(local.updatedAt, remote.updatedAt),
            payload: try JSONDecoder().decode(Payload.self, from: data), fieldUpdatedAt: versions
        )
    }

    private static func version<Payload>(of key: String, in envelope: ExperimentalPreferenceSyncEnvelope<Payload>) -> Date {
        envelope.fieldUpdatedAt.map { $0[key] ?? .distantPast } ?? envelope.updatedAt
    }

    private static func fields<Payload: Encodable>(_ payload: Payload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return values
    }

    private static func encoded(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    }
}
