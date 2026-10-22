#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 保留列表当前位置，沿原分页游标继续加载或重试。
public struct CommunityPaginationFooter: View {
    private let isLoading: Bool
    private let errorMessage: String?
    private let showsContinuation: Bool
    private let onRetry: () async -> Void
    @State private var retryRequested = false

    public init(isLoading: Bool, errorMessage: String?, showsContinuation: Bool = false,
        onRetry: @escaping () async -> Void) {
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.showsContinuation = showsContinuation
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: AppDesignSystem.Spacing.regular) {
            if isLoading {
                AppInlineLoadingState()
            } else if errorMessage != nil || showsContinuation {
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppDesignSystem.Typography.caption)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
                Button(errorMessage == nil ? "继续加载" : "重试加载") { retryRequested = true }
                    .buttonStyle(.bordered)
                    .appInteractiveListRow()
                    .disabled(retryRequested)
                    .accessibilityIdentifier("community.pagination.retry")
            }
        }
        .task(id: retryRequested) {
            guard retryRequested else { return }
            await onRetry()
            retryRequested = false
        }
    }
}
#endif
