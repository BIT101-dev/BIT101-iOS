import Foundation
import OSLog

private let accountScopedStoreLogger = Logger(
    subsystem: "BIT101",
    category: "AccountScopedStore"
)

public enum AccountScopedValueRead<Value> {
    case missing
    case value(Value)
    case unreadable

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// AccountScopedCodableStore 使用稳定前缀和账号后缀生成账号隔离的 Codable 快照存储键。
public struct AccountScopedCodableStore<Value: Codable> {
    private let keyPrefix: String
    private let defaults: UserDefaults
    private let session: () -> AppStorageSession
    private let guestIdentifier: String
    /// 快照声明已知键后，保存保留其余扩展字段，并清空缺省的已知可选字段。
    private let snapshotKeys: Set<String>?

    public init(
        keyPrefix: String,
        defaults: UserDefaults,
        sessionProvider: @escaping () -> AppStorageSession,
        guestIdentifier: String = "guest",
        snapshotKeys: Set<String>? = nil
    ) {
        self.keyPrefix = keyPrefix
        self.defaults = defaults
        self.session = sessionProvider
        self.guestIdentifier = guestIdentifier
        self.snapshotKeys = snapshotKeys
    }

    public func load() -> Value? { read().value }

    public func read() -> AccountScopedValueRead<Value> {
        let key = storageKey
        if let stored = defaults.object(forKey: key) {
            guard let data = stored as? Data, let value = decode(data) else { return .unreadable }
            return .value(value)
        }

        let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
        guard legacyKey != key, let stored = defaults.object(forKey: legacyKey) else { return .missing }
        guard let data = stored as? Data, let value = decode(data) else { return .unreadable }

        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacyKey)
        return .value(value)
    }

    private func decode(_ data: Data) -> Value? {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to decode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        if case .unreadable = read() { return false }
        do {
            var data = try JSONEncoder().encode(value)
            let key = storageKey
            if let snapshotKeys {
                guard let encoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.coderInvalidValue)
                }
                let stored = try defaults.data(forKey: key).map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
                let fields = (stored ?? [:]).filter { !snapshotKeys.contains($0.key) }
                    .merging(encoded) { _, new in new }
                data = try JSONSerialization.data(withJSONObject: fields)
            }
            defaults.set(data, forKey: key)
            let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
            if legacyKey != key, let data = defaults.data(forKey: legacyKey), decode(data) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
            return true
        } catch {
            accountScopedStoreLogger.error(
                "Failed to encode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    public func remove() {
        let key = storageKey
        defaults.removeObject(forKey: key)
        let legacyKey = session().legacyKey(keyPrefix, guestIdentifier: guestIdentifier)
        if legacyKey != key { defaults.removeObject(forKey: legacyKey) }
    }

    public var storageKey: String {
        session().key(keyPrefix, guestIdentifier: guestIdentifier)
    }
}
