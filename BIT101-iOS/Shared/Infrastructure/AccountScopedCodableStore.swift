import Foundation

/// 用稳定前缀和账号后缀隔离 Codable 快照，避免各业务模块重复拼接存储键。
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
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func remove() {
        defaults.removeObject(forKey: storageKey)
    }

    var storageKey: String {
        let identifier = accountIdentifier().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(keyPrefix).\(identifier.isEmpty ? "guest" : identifier)"
    }
}
