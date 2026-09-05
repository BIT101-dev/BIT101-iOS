import SwiftUI

/// 成绩、DDL 等数据页统一的最近更新时间与手动刷新行。
struct AppRefreshStatusRow: View {
    let isRefreshing: Bool
    let refreshingText: String
    let lastUpdatedText: String
    let actionTitle: String
    let onRefresh: () -> Void
    @State private var feedbackToken = 0

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Group {
                if isRefreshing {
                    ProgressView()
                    Text(refreshingText)
                } else {
                    Text(lastUpdatedText)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(actionTitle) {
                feedbackToken &+= 1
                onRefresh()
            }
            .disabled(isRefreshing)
            .appImpactFeedback(trigger: feedbackToken)
        }
    }
}
