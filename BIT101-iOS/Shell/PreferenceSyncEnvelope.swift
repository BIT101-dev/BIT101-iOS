import Foundation
import CryptoKit

nonisolated enum ScoreSyncEncryptionError: LocalizedError {
    case keyPending

    var errorDescription: String? {
        "成绩同步正在等待 iCloud 钥匙串。请确认各设备登录相同 iCloud 账号并启用钥匙串，稍后重试。"
    }
}

/// 成绩载荷使用账号绑定的密文；每份密钥由 iCloud Keychain 按独立身份同步。
@MainActor
final class ScoreCacheSyncEncryption {
    private static let magic = Data("BIT101_SCORE_AES_GCM".utf8)
    private let defaults: UserDefaults
    private let credentials: any LoginCredentialsStoring

    init(defaults: UserDefaults, credentials: any LoginCredentialsStoring) {
        self.defaults = defaults
        self.credentials = credentials
    }

    static func production(defaults: UserDefaults) -> ScoreCacheSyncEncryption {
        ScoreCacheSyncEncryption(defaults: defaults, credentials:
            KeychainLoginCredentials(service: "BIT101.PreferenceCloud.ScoreKeys", synchronizable: true))
    }

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    func seal(_ data: Data, account: String) throws -> Data {
        let activeKey = "experimental.preference-cloud-sync.score-key.\(account)"
        let id: String
        let key: SymmetricKey
        if let saved = defaults.string(forKey: activeKey) {
            id = saved
            key = try readKey(id: id, account: account)
        } else {
            id = UUID().uuidString
            key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            try credentials.save(bytes.base64EncodedString(), account: keyAccount(id: id, account: account))
            defaults.set(id, forKey: activeKey)
        }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(account.utf8))
        guard let combined = sealed.combined else { throw PreferenceSyncRecordError.invalidStoredValue }
        let identifier = Data(id.utf8)
        guard identifier.count <= Int(UInt8.max) else { throw PreferenceSyncRecordError.invalidStoredValue }
        return Self.magic + Data([1, UInt8(identifier.count)]) + identifier + combined
    }

    func open(_ data: Data, account: String) throws -> Data {
        guard Self.isEncrypted(data) else { return data }
        let header = data.startIndex + Self.magic.count
        guard data.endIndex >= header + 2 else { throw PreferenceSyncRecordError.invalidStoredValue }
        let version = Int(data[header])
        guard version == 1 else { throw PreferenceSyncRecordError.unsupportedVersion(version) }
        let end = header + 2 + Int(data[header + 1])
        guard end < data.endIndex, let id = String(data: data[(header + 2)..<end], encoding: .utf8),
              UUID(uuidString: id) != nil else { throw PreferenceSyncRecordError.invalidStoredValue }
        let key = try readKey(id: id, account: account)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(data[end...])), using: key, authenticating: Data(account.utf8))
    }

    @discardableResult
    func removeActiveKey(account: String) -> Bool {
        let activeKey = "experimental.preference-cloud-sync.score-key.\(account)"
        guard let id = defaults.string(forKey: activeKey) else { return true }
        guard credentials.delete(account: keyAccount(id: id, account: account)) else { return false }
        defaults.removeObject(forKey: activeKey)
        return true
    }

    private func readKey(id: String, account: String) throws -> SymmetricKey {
        let secret = try credentials.read(account: keyAccount(id: id, account: account))
        guard !secret.isEmpty else { throw ScoreSyncEncryptionError.keyPending }
        guard let data = Data(base64Encoded: secret), data.count == 32 else { throw PreferenceSyncRecordError.invalidStoredValue }
        return SymmetricKey(data: data)
    }

    private func keyAccount(id: String, account: String) -> String { "\(account).\(id)" }
}

nonisolated enum PreferenceSyncRecordError: LocalizedError {
    case invalidStoredValue
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue: "偏好同步记录格式异常，原始记录已保留。"
        case .unsupportedVersion(let version): "偏好同步记录使用格式版本 \(version)，请更新应用后继续。"
        }
    }
}

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
            throw PreferenceSyncRecordError.unsupportedVersion(version)
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
