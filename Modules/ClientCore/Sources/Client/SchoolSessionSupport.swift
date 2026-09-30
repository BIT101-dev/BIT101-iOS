import Foundation

/// 学校系统请求短信验证码时交给应用层的交互上下文。
public struct SchoolSMSCodeRequest: Identifiable, Sendable {
    public let id: UUID
    public let maskedPhone: String
    public let purpose: String

    public init(id: UUID = UUID(), maskedPhone: String, purpose: String) {
        self.id = id
        self.maskedPhone = maskedPhone
        self.purpose = purpose
    }
}

public typealias SchoolSMSCodeHandler = @MainActor (SchoolSMSCodeRequest) async throws -> String

public nonisolated struct SchoolSecondFactorContext: Sendable {
    public let execution: String
    public let formAction: URL
    public let userObjectID: String

    public init(execution: String, formAction: URL, userObjectID: String) {
        self.execution = execution
        self.formAction = formAction
        self.userObjectID = userObjectID
    }
}

public nonisolated struct SchoolLoginContext: Sendable {
    public let salt: String?
    public let execution: String?
    public let isLoggedIn: Bool

    public init(salt: String?, execution: String?, isLoggedIn: Bool) {
        self.salt = salt
        self.execution = execution
        self.isLoggedIn = isLoggedIn
    }
}

/// 教学中心 WebVPN 会话的进程内状态。
///
/// 认证状态属于学校网络基础设施，页面层通过服务协议消费它。
public final class TeachingCenterSessionState {
    private let lock = NSLock()
    public let cookieStorage: HTTPCookieStorage
    private var authenticatedStudentID: String?
    private var preparedStudentID: String?
    private var directStudentID: String?
    private var directPreferenceUntil: Date?

    public init(cookieStorage: HTTPCookieStorage) {
        self.cookieStorage = cookieStorage
    }

    public func hasUsableSession(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !studentID.isEmpty else { return false }
        if isDirectPreferredLocked(for: studentID, now: Date()) {
            return false
        }
        guard hasWebVPNCookie else {
            authenticatedStudentID = nil
            preparedStudentID = nil
            return false
        }

        if authenticatedStudentID == nil {
            authenticatedStudentID = studentID
        }
        return authenticatedStudentID == studentID
    }

    public func markAuthenticated(for studentID: String) {
        lock.lock()
        authenticatedStudentID = studentID
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil
        lock.unlock()
    }

    public func shouldPreferDirect(for studentID: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard directStudentID == studentID,
              let directPreferenceUntil,
              directPreferenceUntil > now
        else {
            directStudentID = nil
            self.directPreferenceUntil = nil
            return false
        }
        return true
    }

    public func markDirectPreferred(for studentID: String, now: Date = Date()) {
        lock.lock()
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = studentID
        directPreferenceUntil = now.addingTimeInterval(10 * 60)
        lock.unlock()
    }

    public func isPrepared(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasUsableRouteLocked(for: studentID, now: Date())
            && preparedStudentID == studentID
    }

    public func markPrepared(for studentID: String) {
        lock.lock()
        defer { lock.unlock() }
        if hasUsableRouteLocked(for: studentID, now: Date()) {
            preparedStudentID = studentID
        }
    }

    public func invalidate(clearCookies: Bool = true) {
        lock.lock()
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil
        lock.unlock()

        guard clearCookies else { return }
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
        ])
    }

    public func clearSchoolAuthenticationCookies() {
        invalidate(clearCookies: false)
        deleteCookies(matching: [
            "webvpn.bit.edu.cn",
            "sso.bit.edu.cn",
            "jxzxehall.bit.edu.cn",
            "jxzxehallapp.bit.edu.cn",
            "jwms.bit.edu.cn",
            "lexue.bit.edu.cn",
        ])
    }

    private var hasWebVPNCookie: Bool {
        let now = Date()
        return cookieStorage.cookies?.contains { cookie in
            normalizedDomain(cookie.domain) == "webvpn.bit.edu.cn"
                && (cookie.expiresDate.map { $0 > now } ?? true)
        } ?? false
    }

    private func isDirectPreferredLocked(for studentID: String, now: Date) -> Bool {
        directStudentID == studentID && (directPreferenceUntil ?? .distantPast) > now
    }

    private func hasUsableRouteLocked(for studentID: String, now: Date) -> Bool {
        (authenticatedStudentID == studentID && hasWebVPNCookie)
            || isDirectPreferredLocked(for: studentID, now: now)
    }

    private func deleteCookies(matching domains: Set<String>) {
        cookieStorage.cookies?.forEach { cookie in
            let domain = normalizedDomain(cookie.domain)
            if domains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") }) {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    private func normalizedDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}
