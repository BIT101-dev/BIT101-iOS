import SwiftUI

/// AppRefreshStatusRow 统一呈现课表、成绩、DDL、空教室等数据页的最近更新时间和手动刷新入口。
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
