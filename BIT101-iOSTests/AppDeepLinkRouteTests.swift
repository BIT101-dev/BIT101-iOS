import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
@testable import BIT101_iOS

@Suite("App deep links")
struct AppDeepLinkRouteTests {
    @Test("Universal links route gallery and course details")
    func universalLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/gallery/123"))) == .gallery(123))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/course/456"))) == .course(456))
    }

    @Test("Custom links remain supported and foreign hosts are rejected")
    func customAndForeignLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/courses"))) == .scheduleCourses)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/ddl"))) == .scheduleDDL)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/schedule/ddl"))) == .scheduleDDL)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://paper/7"))) == .paper(7))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://example.com/gallery/123"))) == nil)
    }
}
