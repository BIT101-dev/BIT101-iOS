import ClientCore
import Combine
import CommunityCore
import CommunityTransport
import Foundation
import Network
import ScheduleActivityContracts
import ScheduleContracts
import ScheduleDomain
import SchedulePorts
import ScoreDomain
import ScorePorts
import Security
import StorageCore
import Testing
import TransportCore
import UIKit
import XCTest
import os

@testable import BIT101_iOS
@testable import CommunityUI
@testable import GalleryFeature
@testable import MediaKit
@testable import ScheduleFeature
@testable import ScoreFeature
@testable import ScoreInfrastructure

@Suite("App deep links")
struct AppDeepLinkRouteTests {
    @Test("Universal links route gallery and course details")
    func universalLinks() throws {
        #expect(
            AppDeepLinkRoute(
                url: try #require(URL(string: "https://open.aihelpme.dev/gallery/123")))
                == .gallery(123))
        #expect(
            AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/course/456")))
                == .course(456))
    }

    @Test("Custom links remain supported and foreign hosts are rejected")
    func customAndForeignLinks() throws {
        #expect(
            AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/courses")))
                == .scheduleCourses)
        #expect(
            AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/ddl")))
                == .scheduleDDL)
        #expect(
            AppDeepLinkRoute(
                url: try #require(URL(string: "https://open.aihelpme.dev/schedule/ddl")))
                == .scheduleDDL)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://paper/7"))) == .paper(7))
        #expect(
            AppDeepLinkRoute(url: try #require(URL(string: "https://example.com/gallery/123")))
                == nil)
    }
}
