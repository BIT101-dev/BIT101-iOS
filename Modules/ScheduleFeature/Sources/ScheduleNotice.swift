import DesignSystemKit
import Foundation
import TransportCore

/// 日程页统一使用的提示模型。
///
/// 日程模块的同步、保存和空教室查询动作通过这个提示模型向视图层传递错误。
public typealias ScheduleNotice = AppAlert

extension ScheduleStateConsumer {
    func schoolFailureNotice(
        title: String,
        message: String,
        networkFailure: Bool = false,
        underlyingError: (any Error)? = nil
    ) -> ScheduleNotice {
        guard networkFailure, virtualNetworkLikely() else {
            return ScheduleNotice(title: title, message: message, underlyingError: underlyingError)
        }
        return ScheduleNotice(
            title: title,
            message: "\(message)\n\n先关掉魔法试试。",
            allowsDiagnostics: false,
            showsRecoveryLinks: false,
            underlyingError: underlyingError
        )
    }

    nonisolated static func isLikelySchoolTransportError(_ error: Error) -> Bool {
        ErrorChain.contains(error) { candidate in
            guard let urlError = candidate as? URLError else { return false }
            return [
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .networkConnectionLost,
                .notConnectedToInternet,
                .secureConnectionFailed,
                .timedOut
            ].contains(urlError.code)
        }
    }
}

/// 空教室页业务级超时错误。
struct ClassroomRequestTimeoutError: LocalizedError {
    var errorDescription: String? {
        "请求超时，请稍后重试。"
    }
}
