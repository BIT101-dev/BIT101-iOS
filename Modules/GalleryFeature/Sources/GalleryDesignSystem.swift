#if os(iOS)
import DesignSystemKit
import SwiftUI

extension AppDesignSystem {
    public enum Gallery {
        public static let tabAccent = Color.orange
        public static let unreadIndicator: CGFloat = 7
        public static let messageDividerLeading: CGFloat = Size.Avatar.standard + Spacing.content
    }
}

#endif
