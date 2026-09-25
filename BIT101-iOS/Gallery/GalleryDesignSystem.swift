import SwiftUI
import UIKit

extension AppDesignSystem {
    enum Gallery {
        static let tabAccent = Color.orange
        @MainActor
        static var thumbnailHeight: CGFloat {
            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.bounds.height ?? 0
            return screenHeight / 6
        }
        static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        static let identitySurfaceOpacity = AppDesignSystem.Opacity.subtle
        static let dangerOverlayOpacity = AppDesignSystem.Opacity.emphasis
        static let unreadIndicator: CGFloat = 7
        static let messageDividerLeading: CGFloat = 52
    }
}
