import CryptoKit
import Foundation

/// Shared opaque account identity used by the app, widgets, and watch snapshot.
public nonisolated enum AccountStorageIdentity {
    private static let tokenPrefix = "account-"
    private static let tokenCharacters = CharacterSet(charactersIn: "0123456789abcdef")

    public static func stableToken(for accountIdentifier: String) -> String {
        let normalizedIdentifier = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else { return "__default__" }
        guard !isStableToken(normalizedIdentifier) else { return normalizedIdentifier }

        let digest = SHA256.hash(data: Data(normalizedIdentifier.utf8))
        return tokenPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isStableToken(_ identifier: String) -> Bool {
        guard identifier.hasPrefix(tokenPrefix) else { return false }
        let digest = identifier.dropFirst(tokenPrefix.count)
        return digest.count == 64 && digest.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }
}

/// 当前登录账号的本地存储会话。
///
/// 业务模块按当前用户读写数据；账号标识、稳定键后缀与磁盘目录名由存储层统一映射。
public nonisolated struct AppStorageSession: Sendable, Equatable {
    public let accountIdentifier: String

    public init(accountIdentifier: String) {
        self.accountIdentifier = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isGuest: Bool { accountIdentifier.isEmpty }

    public func key(_ prefix: String, guestIdentifier: String = "guest") -> String {
        "\(prefix).\(isGuest ? guestIdentifier : accountStorageIdentifier)"
    }

    /// Previous defaults key used the account identifier verbatim.
    public func legacyKey(_ prefix: String, guestIdentifier: String = "guest") -> String {
        "\(prefix).\(isGuest ? guestIdentifier : accountIdentifier)"
    }

    /// 保留旧版账号映射，供 CloudKit 标识和本地数据迁移沿用。
    public var accountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        guard accountIdentifier.rangeOfCharacter(from: invalid) != nil else { return accountIdentifier }
        return "__encoded__" + accountIdentifier.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// 本地存储使用稳定摘要作为账号命名空间。
    public var accountStorageIdentifier: String {
        guard !isGuest else { return "__default__" }
        return AccountStorageIdentity.stableToken(for: accountIdentifier)
    }

    /// 旧版账号文件夹名，用于现有缓存迁移。
    public var legacyAccountDirectoryName: String {
        guard !isGuest else { return "__default__" }
        let invalid = CharacterSet.alphanumerics.inverted
        return accountIdentifier.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 兼容迁移沿用既有稳定账号目录名；规范化旧目录保留为独立历史路径。
    public var legacyAccountDirectoryNameForMigration: String {
        accountDirectoryName
    }
}
