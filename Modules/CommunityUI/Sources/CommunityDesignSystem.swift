#if os(iOS)
import DesignSystemKit
import SwiftUI
import UIKit

extension AppDesignSystem {
    public enum Community {
        @MainActor
        public static var thumbnailHeight: CGFloat {
            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.bounds.height ?? 0
            return screenHeight / 6
        }
        public static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        public static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        public static let identitySurfaceOpacity = AppDesignSystem.Opacity.subtle
    }
}

#endif
