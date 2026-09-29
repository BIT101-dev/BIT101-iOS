import Foundation

/// 日程页统一使用的提示模型。
///
/// 日程模块的同步、保存和空教室查询动作通过这个提示模型向视图层传递错误。
nonisolated struct ScheduleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: AppRecoveryAction?
    let allowsDiagnostics: Bool
    let showsRecoveryLinks: Bool

    init(
        title: String,
        message: String,
        recoveryAction: AppRecoveryAction? = nil,
        allowsDiagnostics: Bool = true,
        showsRecoveryLinks: Bool = true
    ) {
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
        self.allowsDiagnostics = allowsDiagnostics
        self.showsRecoveryLinks = showsRecoveryLinks
    }

    static func userInput(
        title: String,
        message: String,
        recoveryAction: AppRecoveryAction? = nil
    ) -> ScheduleNotice {
        ScheduleNotice(
            title: title,
            message: message,
            recoveryAction: recoveryAction,
            allowsDiagnostics: false
        )
    }

    static func informational(title: String, message: String) -> ScheduleNotice {
        ScheduleNotice(title: title, message: message, allowsDiagnostics: false)
    }
}

extension ScheduleStateConsumer {
    func schoolFailureNotice(
        title: String,
        message: String,
        networkFailure: Bool = false
    ) -> ScheduleNotice {
        let snapshot = NetworkConnectionDescription.shared.snapshot
        guard networkFailure, snapshot.virtualNetworkLikely else {
            return ScheduleNotice(title: title, message: message)
        }
        return ScheduleNotice(
            title: title,
            message: "\(message)\n\n先关掉魔法试试。",
            allowsDiagnostics: false,
            showsRecoveryLinks: false
        )
    }

    nonisolated static func isLikelySchoolTransportError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
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

        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isLikelySchoolTransportError(underlying)
        }
        return false
    }
}

/// 空教室页业务级超时错误。
struct ClassroomRequestTimeoutError: LocalizedError {
    var errorDescription: String? {
        "请求超时，请稍后重试。"
    }
}
