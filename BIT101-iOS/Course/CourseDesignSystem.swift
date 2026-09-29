import DesignSystemKit
import SwiftUI

extension AppDesignSystem {
    enum Course {
        static let historyChartHeight: CGFloat = 240
        static let metricSurfaceOpacity = AppDesignSystem.Opacity.subtle
        static let historyWarningOpacity = AppDesignSystem.Opacity.emphasis
        static let accent = Color.pink
        static let accentSurface = accent.opacity(AppDesignSystem.Opacity.subtle)
    }
}

/// 日程和成绩详情页共用的课程评价入口行。
struct AppCourseEvaluationRow: View {
    let isLoading: Bool

    init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    var body: some View {
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
