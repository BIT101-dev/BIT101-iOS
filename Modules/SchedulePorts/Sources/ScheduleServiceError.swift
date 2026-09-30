import ClientCore
import Foundation

/// 日程同步过程中的统一错误。
///
/// 该枚举承接 UI 展示所需的错误；接口差异和字段缺失在此归并为少量用户可理解的文案。
public nonisolated enum ScheduleServiceError: LocalizedError {
    case notLoggedIn
    case secondFactorRequired(BITLoginAuthenticationChallenge)
    case challengeInvalid(String)
    case teachingCenterSessionExpired
    case authenticationFailed(String)
    case schoolTransportFailure
    case schoolSecondFactorRequired
    case schoolSMSCodeInvalid(String)
    case schoolSMSUnavailable(String)
    case invalidResponse
    case invalidLexuePage
    case invalidCalendarURL
    case invalidCalendarData
    case schoolResponse(String)

    public var isUnpublishedCourseSchedule: Bool {
        guard case let .schoolResponse(message) = self else { return false }
        return message.contains("课表未发布") || message.contains("课表尚未发布")
    }

    /// 学校统一认证后端可能把 WebVPN/TLS 故障作为 challenge 的失败消息返回。
    /// 此类消息归入学校传输失败，验证码失效分支保留给 challenge 无效响应。
    public var isSchoolTransportFailure: Bool {
        switch self {
        case .schoolTransportFailure:
            return true
        case let .challengeInvalid(message), let .authenticationFailed(message):
            return Self.looksLikeTransportFailure(message)
        default:
            return false
        }
    }

    public var schoolTransportFailureMessage: String {
        "学校统一认证服务暂时无法建立安全连接，请稍后重试。"
    }

    private static func looksLikeTransportFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("ssl")
            || value.contains("certificate")
            || value.contains("证书")
            || value.contains("httpsconnectionpool")
            || value.contains("tls")
            || value.contains("timeout")
            || value.contains("timed out")
            || value.contains("超时")
    }

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再同步日程。"
        case .secondFactorRequired:
            return "需要短信验证码才能继续访问学校教务服务。"
        case let .challengeInvalid(message):
            return message
        case .teachingCenterSessionExpired:
            return "学校会话自动恢复失败，请稍后重试；无需退出 App 或重新登录。"
        case let .authenticationFailed(message):
            return message
        case .schoolTransportFailure:
            return schoolTransportFailureMessage
        case .schoolSecondFactorRequired:
            return "学校统一身份认证要求短信二次验证。"
        case let .schoolSMSCodeInvalid(message):
            return message
        case let .schoolSMSUnavailable(message):
            return message
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .invalidLexuePage:
            return "无法从乐学页面提取日历订阅信息。"
        case .invalidCalendarURL:
            return "乐学日历订阅链接无效。"
        case .invalidCalendarData:
            return "乐学日历数据解析失败。"
        case let .schoolResponse(message):
            return message
        }
    }
}

