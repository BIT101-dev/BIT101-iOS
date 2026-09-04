import SwiftUI

/// 加载失败状态统一的图标、重试入口和诊断入口。
struct AppFailureState: View {
    let title: String
    let systemImage: String
    let message: String
    let retryTitle: String
    let onRetry: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String,
        retryTitle: String = "重试",
        onRetry: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let onRetry {
                Button(retryTitle, action: onRetry)
            }
            DiagnosticRecoveryActions(title: title, message: message)
        }
    }
}

/// 无数据状态统一的图标、说明和可选操作入口。
struct AppEmptyState: View {
    let title: String
    let systemImage: String
    let message: String?
    let actionTitle: String?
    let onAction: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let onAction, let actionTitle {
                Button(actionTitle, action: onAction)
            }
        }
    }
}
