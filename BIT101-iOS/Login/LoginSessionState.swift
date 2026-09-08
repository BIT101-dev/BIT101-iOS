//
//  LoginSessionState.swift
//  BIT101-iOS
//

import Foundation
import Security

/// 本地保存的登录凭据。
///
/// 这里保存足以静默重登学校 SSO 的最小信息组合；fake-cookie 等会话态保持在结构外。
struct StoredCredentials {
    let studentID: String
    let password: String
}

/// 教学中心 WebVPN 会话的进程内状态。
///
/// 状态绑定具体学号，每次使用前检查对应 Cookie。网络层发现会话失效时调用 `invalidate`，
/// 下一次请求重新经过 bit-login。
final class TeachingCenterSessionState {
    static let shared = TeachingCenterSessionState()

    private let lock = NSLock()
    private let cookieStorage = HTTPCookieStorage.shared
    private var authenticatedStudentID: String?
    private var preparedStudentID: String?
    private var directStudentID: String?
    private var directPreferenceUntil: Date?

    private init() {}

    func hasUsableSession(for studentID: String) -> Bool {
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

        // App 重启后系统 Cookie 仍可能有效。登录流程在切换账号前清除学校 Cookie，因此
        // 这里可以把现存 Cookie 重新绑定到当前保存的学号。
        if authenticatedStudentID == nil {
            authenticatedStudentID = studentID
        }
        return authenticatedStudentID == studentID
    }

    func markAuthenticated(for studentID: String) {
        lock.lock()
        authenticatedStudentID = studentID
        preparedStudentID = nil
        directStudentID = nil
        directPreferenceUntil = nil
        lock.unlock()
    }

    /// WebVPN 在当前网络失败后，短期复用已经验证成功的校内直连路线。
    func shouldPreferDirect(for studentID: String, now: Date = Date()) -> Bool {
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

    func markDirectPreferred(for studentID: String, now: Date = Date()) {
        lock.lock()
        authenticatedStudentID = nil
        preparedStudentID = nil
        directStudentID = studentID
        directPreferenceUntil = now.addingTimeInterval(10 * 60)
        lock.unlock()
    }

    func isPrepared(for studentID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasUsableRouteLocked(for: studentID, now: Date())
            && preparedStudentID == studentID
    }

    func markPrepared(for studentID: String) {
        lock.lock()
        defer { lock.unlock() }
        if hasUsableRouteLocked(for: studentID, now: Date()) {
            preparedStudentID = studentID
        }
    }

    /// 使内存状态失效；传入 `true` 时删除教学中心/WebVPN 域的 Cookie。
    func invalidate(clearCookies: Bool = true) {
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

    /// 退出、重新登录或切换账号时清理学校身份相关 Cookie，其他网站 Cookie 保持不变。
    func clearSchoolAuthenticationCookies() {
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

/// 从学校登录页里解析出来的必要上下文。
///
/// 学校 CAS 登录页返回 HTML，不提供稳定 JSON 接口。本结构提取后续登录所需字段，
/// 供业务层继续传递。
struct SchoolLoginContext {
    let salt: String?
    let execution: String?
    let isLoggedIn: Bool
}

/// 登录链路中的统一错误定义。
enum LoginServiceError: LocalizedError {
    case invalidSchoolLoginPage
    case schoolLoginFailed
    case unableToRestoreSchoolSession
    case invalidServerResponse
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSchoolLoginPage:
            return "学校登录页结构发生变化，暂时无法完成登录。"
        case .schoolLoginFailed:
            return "学校统一身份认证登录失败，请检查学号和密码。"
        case .unableToRestoreSchoolSession:
            return "学校登录状态已过期，且缺少可用于静默恢复的本地凭据。"
        case .invalidServerResponse:
            return "服务器返回了无法识别的数据。"
        case let .keychainWriteFailed(status):
            return "无法保存登录信息（Keychain 状态码: \(status)）。"
        case let .keychainReadFailed(status):
            return "无法读取登录信息（Keychain 状态码: \(status)）。"
        }
    }
}
