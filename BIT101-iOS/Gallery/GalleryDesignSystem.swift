import SwiftUI

extension AppDesignSystem {
    enum Gallery {
        static let tabAccent = Color.orange
        static let thumbnailHeightContainerCount = 4
        static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        static let identitySurfaceOpacity = AppDesignSystem.Opacity.subtle
        static let dangerOverlayOpacity = AppDesignSystem.Opacity.emphasis
        static let unreadIndicator: CGFloat = 7
        static let messageDividerLeading: CGFloat = 52
    }
}
