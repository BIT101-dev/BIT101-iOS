import SwiftUI

/// AppLoadingState 为页面级首屏加载状态提供统一的进度样式和可用空间约束。
struct AppLoadingState: View {
    let title: String

    var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppInlineLoadingState 为列表分区和滚动内容提供统一的加载状态与居中布局。
struct AppInlineLoadingState: View {
    let title: String?

    init(_ title: String? = nil) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Spacer()
            if let title {
                ProgressView(title)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding(.vertical, AppDesignSystem.Spacing.content)
    }
}

/// AppScrollStateContainer 通过容器提供的垂直空间居中呈现滚动页首屏状态，并适配不同设备的可用高度。
struct AppScrollStateContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }
}

/// AppFailureState 统一提供加载失败状态的图标、重试入口和诊断入口。
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

/// AppEmptyState 统一提供无数据状态的图标、说明和可选操作入口。
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
