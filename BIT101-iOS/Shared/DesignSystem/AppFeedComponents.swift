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
