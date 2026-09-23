import SwiftUI

extension AppDesignSystem {
    enum Gallery {
        static let thumbnailHeightContainerCount = 4
        static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        static let overflowOverlayOpacity: CGFloat = 0.45
        static let unreadIndicator: CGFloat = 7
        static let messageDividerLeading: CGFloat = 52
    }
}
