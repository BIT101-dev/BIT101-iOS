import Foundation

/// 字段值随载荷往返保存，维护跨客户端的新增偏好。
nonisolated enum PreferenceJSONValue: Codable, Equatable {
    case null, bool(Bool), number(Decimal), string(String)
    case array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Decimal.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([Self].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }
}

/// 版本、字段修改时间与扩展字段共同构成偏好同步契约。
nonisolated struct ExperimentalPreferenceSyncEnvelope<Payload: Codable>: Codable {
    static var schemaVersion: Int { 2 }
    let updatedAt: Date
    let payload: Payload
    let fieldUpdatedAt: [String: Date]?
    var additionalFields: [String: PreferenceJSONValue]

    init(updatedAt: Date, payload: Payload, fieldUpdatedAt: [String: Date]? = nil,
         additionalFields: [String: PreferenceJSONValue] = [:]) {
        self.updatedAt = updatedAt
        self.payload = payload
        self.fieldUpdatedAt = fieldUpdatedAt
        self.additionalFields = additionalFields
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, updatedAt, payload, fieldUpdatedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                debugDescription: "Preference sync payload requires a supported schema version.")
        }
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        payload = try values.decode(Payload.self, forKey: .payload)
        fieldUpdatedAt = try values.decodeIfPresent([String: Date].self, forKey: .fieldUpdatedAt)
        let raw = try values.decode([String: PreferenceJSONValue].self, forKey: .payload)
        let known = try JSONDecoder().decode([String: PreferenceJSONValue].self, from: JSONEncoder().encode(payload))
        additionalFields = raw.filter { known[$0.key] == nil }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(fieldUpdatedAt, forKey: .fieldUpdatedAt)
        let known = try JSONDecoder().decode([String: PreferenceJSONValue].self, from: JSONEncoder().encode(payload))
        try values.encode(additionalFields.merging(known) { _, current in current }, forKey: .payload)
    }
}
