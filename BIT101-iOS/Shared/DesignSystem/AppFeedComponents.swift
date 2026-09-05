import SwiftUI

/// 信息流统一的行容器和分割线。
struct AppFeedRow<Content: View>: View {
    let isLast: Bool
    private let content: Content

    init(isLast: Bool, @ViewBuilder content: () -> Content) {
        self.isLast = isLast
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content

            if !isLast {
                Divider()
                    .padding(.leading, AppDesignSystem.Spacing.container)
            }
        }
    }
}
