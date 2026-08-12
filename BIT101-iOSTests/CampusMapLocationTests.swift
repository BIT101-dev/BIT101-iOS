import Foundation
import Testing
@testable import BIT101_iOS

private final class CampusMapFixtureBundleToken {}

private struct CampusMapLocationFixture: Decodable {
    let campus: String
    let classroom: String
    let expected: String?
}

@Suite("Campus map location matching")
struct CampusMapLocationTests {
    @Test("All retained timetable locations match their calibrated map place")
    func matchesRealTimetableLocations() throws {
        let bundle = Bundle(for: CampusMapFixtureBundleToken.self)
        let fixtureURL = bundle.url(
            forResource: "campus-map-locations",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "campus-map-locations", withExtension: "json")
        let url = try #require(fixtureURL)
        let fixtures = try JSONDecoder().decode(
            [CampusMapLocationFixture].self,
            from: Data(contentsOf: url)
        )

        #expect(fixtures.count == 557)
        for fixture in fixtures {
            let parsed = ScheduleDisplayNormalizer.compactLocation(for: fixture.classroom)
            #expect(
                !parsed.lightText.isEmpty,
                "Parser rejected: \(fixture.campus) / \(fixture.classroom)"
            )

            let place = CampusMapPlaceCatalog.place(
                campusName: fixture.campus,
                classroom: fixture.classroom
            )
            if let expected = fixture.expected {
                #expect(
                    place?.name == expected,
                    "Location mismatch: \(fixture.campus) / \(fixture.classroom)"
                )
            } else {
                #expect(
                    place == nil,
                    "Excluded location unexpectedly created a pin: \(fixture.campus) / \(fixture.classroom)"
                )
            }
        }
    }

    @Test("Same display name remains isolated by campus")
    func separatesSameNamedPlacesByCampus() throws {
        let zhongguancun = try #require(CampusMapPlaceCatalog.place(
            campusName: "中关村校区",
            classroom: "中关村体育馆北厅140"
        ))
        let liangxiang = try #require(CampusMapPlaceCatalog.place(
            campusName: "良乡校区",
            classroom: "良乡体育馆篮球场"
        ))

        #expect(zhongguancun.name == "体育馆")
        #expect(liangxiang.name == "体育馆")
        #expect(zhongguancun.campus == .zhongguancun)
        #expect(liangxiang.campus == .liangxiang)
        #expect(zhongguancun.coordinate.latitude != liangxiang.coordinate.latitude)
    }
}
