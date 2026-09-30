import Foundation

public enum SchoolSessionRestorationError: Error {
    case secondFactorRequired(SchoolSecondFactorContext)
}

/// 负责恢复学校 CAS 会话的应用适配入口。
public protocol SchoolSessionRestoring: Sendable {
    func restoreSchoolSessionIfNeeded() async throws -> String?
}

/// 学校认证凭据，应用层提供具体存储实现。
public protocol SchoolCredentialsProviding {
    var currentStudentID: String { get }
    var currentPassword: String { get }
}

/// 学校 URL 加密能力，应用层提供具体密码学实现。
public protocol SchoolServiceCryptoProviding: Sendable {
    var schoolURLCryptoPublicKey: String { get }
    var browserUserAgent: String { get }

    func schoolProtectedHeaders() -> [String: String]
    func encryptSchoolURLCryptoBody(
        object: [String: String],
        publicKeyPEM: String
    ) throws -> (body: String, encryptedKey: String, aesKey: Data)
    func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data
}

public extension SchoolServiceCryptoProviding {
    func isAcceptedSchoolLoginCompletion(
        statusCode: Int,
        url: URL,
        schoolHost: String? = "sso.bit.edu.cn"
    ) -> Bool {
        if (200 ..< 300).contains(statusCode) {
            return true
        }
        return statusCode == 401
            && url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == schoolHost?.lowercased()
            && url.path == "/gate/cas-success"
    }
}
