import ClientCore
import CommunityCore
import CommunityPersistence
import CommunityTransport
import CommunityUI
import DesignSystemKit
import Foundation
import ScheduleDomain
import ScoreDomain
import ScoreInfrastructure
import ScorePorts
import StorageCore
import SwiftUI
import Testing
import TransportCore
import UIKit
import WebKit

@testable import BIT101_iOS
@testable import CourseFeature
@testable import GalleryFeature
@testable import MediaKit
@testable import MineFeature
@testable import PaperFeature
@testable import ScheduleFeature
@testable import ScoreFeature

extension FeatureCompositionTests {
    @Test func orientation() {
        for (idiom, horizontal, vertical, mask) in [
            (
                UIUserInterfaceIdiom.phone, UIUserInterfaceSizeClass.compact,
                UIUserInterfaceSizeClass.regular, UIInterfaceOrientationMask.portrait
            ),
            (.phone, .regular, .compact, .portrait),
            (.phone, .regular, .regular, .allButUpsideDown),
            (.pad, .compact, .regular, .all), (.pad, .regular, .regular, .all),
        ] {
            let traits = UITraitCollection { traits in
                traits.userInterfaceIdiom = idiom
                traits.horizontalSizeClass = horizontal
                traits.verticalSizeClass = vertical
            }
            #expect(AppInterfaceOrientationPolicy.supportedOrientations(for: traits) == mask)
        }
        let wide = AppWindowLayout(
            size: CGSize(width: 1_194, height: 834), isRegularWidth: true, interfaceIdiom: .pad)
        #expect(wide.isLandscape && wide.gridColumns.count == 2)
        #expect(
            !AppWindowLayout(size: CGSize(width: 834, height: 1_194), isRegularWidth: true)
                .isLandscape)
        #expect(!AppWindowLayout(size: wide.size, isRegularWidth: false).isLandscape)
        #expect(
            !AppWindowLayout(size: wide.size, isRegularWidth: true, usesAccessibilityText: true)
                .isLandscape)
        #expect(
            !AppWindowLayout(size: wide.size, isRegularWidth: true, availableWidth: 540).isLandscape
        )
        #expect(
            AppWindowLayout(size: wide.size, isRegularWidth: true, availableWidth: 760).gridColumns
                .count == 2)
        for height: CGFloat in [640, 744, 960] {
            let layout = AppWindowLayout(
                size: wide.size, isRegularWidth: true, availableHeight: height, interfaceIdiom: .pad
            )
            #expect(layout.sidebarWidth == height * 9 / 16)
            #expect(layout.singleColumn.sidebarWidth == layout.sidebarWidth)
        }
        let duo = AppWindowLayout(
            size: CGSize(width: 1_046, height: 744), isRegularWidth: true,
            availableWidth: 962, availableHeight: 724, interfaceIdiom: .phone,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 84), divisionX: 523)
        #expect(duo.isLandscape && duo.hasLandscapeDivision && duo.contentTopInset == 16)
        #expect(
            !duo.usesBottomTabBar && !wide.usesBottomTabBar && !wide.singleColumn.usesBottomTabBar)
        #expect(duo.sidebarWidth == 523 && duo.singleColumn.sidebarWidth == 523)
        let closed = AppWindowLayout(
            size: CGSize(width: 466, height: 678),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84))
        #expect(!closed.hasLandscapeDivision && closed.contentTopInset == 16)
        #expect(!closed.usesBottomTabBar)
        #if targetEnvironment(macCatalyst)
        #expect(!closed.usesSideToolbar)
        #else
        if #available(iOS 27.1, *) {
            #expect(closed.usesSideToolbar && closed.singleColumn.usesSideToolbar)
        }
        #endif
        #expect(!duo.usesSideToolbar && !wide.usesSideToolbar)
        let expandedPortrait = AppWindowLayout(
            size: CGSize(width: 744, height: 1_046), isRegularWidth: true,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84))
        #expect(!expandedPortrait.usesSideToolbar && !expandedPortrait.singleColumn.usesSideToolbar)
        #expect(
            AppWindowLayout(
                size: CGSize(width: 402, height: 874), interfaceIdiom: .phone,
                safeAreaInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
            ).usesBottomTabBar)
        #expect(
            AppWindowLayout(
                size: duo.size, isRegularWidth: true,
                safeAreaInsets: UIEdgeInsets(top: 0, left: 84, bottom: 20, right: 0), divisionX: 523
            ).sidebarWidth == 439)
        #expect(
            AppWindowLayout(
                size: wide.size,
                safeAreaInsets: UIEdgeInsets(top: 32, left: 0, bottom: 20, right: 0)
            ).contentTopInset == 0)
    }
}
