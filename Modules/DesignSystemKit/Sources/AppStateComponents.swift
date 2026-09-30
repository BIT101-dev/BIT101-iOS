#if os(iOS)
import SwiftUI

public typealias AppFailureDiagnosticsBuilder = (String, String) -> AnyView

private struct AppFailureDiagnosticsKey: EnvironmentKey {
    static let defaultValue: AppFailureDiagnosticsBuilder? = nil
}

extension EnvironmentValues {
    public var appFailureDiagnostics: AppFailureDiagnosticsBuilder? {
        get { self[AppFailureDiagnosticsKey.self] }
        set { self[AppFailureDiagnosticsKey.self] = newValue }
    }
}

/// AppLoadingState 为页面级首屏加载状态提供统一的进度样式和可用空间约束。
public struct AppLoadingState: View {
    public init(title: String) {
        self.title = title
    }

    let title: String

    public var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppInlineLoadingState 为列表分区和滚动内容提供统一的加载状态与居中布局。
public struct AppInlineLoadingState: View {
    let title: String?

    public init(_ title: String? = nil) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
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
public struct AppScrollStateContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack {
            Spacer(minLength: AppDesignSystem.Spacing.none)
            content
            Spacer(minLength: AppDesignSystem.Spacing.none)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }
}

/// AppFailureState 统一提供加载失败状态的图标、重试入口和诊断入口。
public struct AppFailureState: View {
    let title: String
    let systemImage: String
    let message: String
    let retryTitle: String
    let onRetry: (() -> Void)?
    let allowsDiagnostics: Bool
    @Environment(\.appFailureDiagnostics) private var appFailureDiagnostics

    public init(
        title: String,
        systemImage: String,
        message: String,
        retryTitle: String = "重试",
        allowsDiagnostics: Bool = true,
        onRetry: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.allowsDiagnostics = allowsDiagnostics
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let onRetry {
                Button(retryTitle, action: onRetry)
            }
            if allowsDiagnostics, let appFailureDiagnostics {
                appFailureDiagnostics(title, message)
            }
        }
    }
}

/// AppEmptyState 统一提供无数据状态的图标、说明和可选操作入口。
public struct AppEmptyState: View {
    let title: String
    let systemImage: String
    let message: String?
    let actionTitle: String?
    let onAction: (() -> Void)?

    public init(
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

    public var body: some View {
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
#endif
