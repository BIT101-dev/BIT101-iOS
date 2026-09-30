#if os(iOS)
import SwiftUI

/// AppFeedRow 为信息流提供零间距行容器，并为非末行显示缩进分割线。
public struct AppFeedRow<Content: View>: View {
    let isLast: Bool
    private let content: Content

    public init(isLast: Bool, @ViewBuilder content: () -> Content) {
        self.isLast = isLast
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: AppDesignSystem.Spacing.none) {
            content

            if !isLast {
                Divider()
                    .padding(.leading, AppDesignSystem.Spacing.content)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif

#if os(iOS)


/// 日程和成绩详情页共用的课程评价入口行。
public struct AppCourseEvaluationRow: View {
    let isLoading: Bool

    public init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Text("查看课程评价")
                .foregroundStyle(AppDesignSystem.Course.accent)

            Spacer(minLength: AppDesignSystem.Spacing.none)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#endif
