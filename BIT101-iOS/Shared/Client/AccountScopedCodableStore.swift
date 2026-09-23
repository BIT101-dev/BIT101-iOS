import Foundation
import OSLog

private let accountScopedStoreLogger = Logger(
    subsystem: "BIT101-dev.BIT101-iOS",
    category: "AccountScopedStore"
)

/// AccountScopedCodableStore 使用稳定前缀和账号后缀生成账号隔离的 Codable 快照存储键。
struct AccountScopedCodableStore<Value: Codable> {
    private let keyPrefix: String
    private let defaults: UserDefaults
    private let accountIdentifier: () -> String

    init(
        keyPrefix: String,
        defaults: UserDefaults = .standard,
        accountIdentifier: @escaping () -> String
    ) {
        self.keyPrefix = keyPrefix
        self.defaults = defaults
        self.accountIdentifier = accountIdentifier
    }

    func load() -> Value? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to decode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: storageKey)
        } catch {
            accountScopedStoreLogger.error(
                "Failed to encode account-scoped value keyPrefix=\(keyPrefix, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func remove() {
        defaults.removeObject(forKey: storageKey)
    }

    var storageKey: String {
        let identifier = accountIdentifier().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(keyPrefix).\(identifier.isEmpty ? "guest" : identifier)"
    }
}
