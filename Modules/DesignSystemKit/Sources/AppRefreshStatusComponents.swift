#if os(iOS)
import SwiftUI

/// AppRefreshStatusRow 统一呈现课表、成绩、DDL、空教室等数据页的最近更新时间和手动刷新入口。
public struct AppRefreshStatusRow: View {
    let isRefreshing: Bool
    let refreshingText: String
    let lastUpdatedText: String
    let actionTitle: String?
    let onRefresh: (() -> Void)?
    let trailingText: String?
    let actionAccessibilityIdentifier: String?
    @State private var feedbackToken = 0

    public init(
        isRefreshing: Bool,
        refreshingText: String,
        lastUpdatedText: String,
        actionTitle: String? = nil,
        onRefresh: (() -> Void)? = nil,
        trailingText: String? = nil,
        actionAccessibilityIdentifier: String? = nil
    ) {
        self.isRefreshing = isRefreshing
        self.refreshingText = refreshingText
        self.lastUpdatedText = lastUpdatedText
        self.actionTitle = actionTitle
        self.onRefresh = onRefresh
        self.trailingText = trailingText
        self.actionAccessibilityIdentifier = actionAccessibilityIdentifier
    }

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Group {
                if isRefreshing {
                    ProgressView()
                    Text(refreshingText)
                } else {
                    Text(lastUpdatedText)
                }
            }
            .font(AppDesignSystem.Typography.subheadline)
            .foregroundStyle(AppDesignSystem.Foreground.primary)

            Spacer(minLength: AppDesignSystem.Spacing.none)

            if let actionTitle, let onRefresh {
                Button(actionTitle) {
                    feedbackToken &+= 1
                    onRefresh()
                }
                .accessibilityIdentifier(actionAccessibilityIdentifier ?? "app.refresh-status.action")
                .disabled(isRefreshing)
                .appImpactFeedback(trigger: feedbackToken)
            } else if let trailingText {
                Text(trailingText)
                    .font(AppDesignSystem.Typography.subheadline)
                    .foregroundStyle(AppDesignSystem.Foreground.primary)
            }
        }
    }
}
#endif
