@testable import ScheduleFeature
@testable import MapFeature
import ScheduleContracts
import Foundation
import Testing
import CoreLocation
import MapKit
@testable import BIT101_iOS

private final class CampusMapFixtureBundleToken {}

private nonisolated final class MapLocationManagerFixture: CLLocationManager {
    var status: CLAuthorizationStatus = .notDetermined
    private(set) var authorizationRequests = 0
    override var authorizationStatus: CLAuthorizationStatus { status }
    override func requestWhenInUseAuthorization() { authorizationRequests += 1 }
}

private nonisolated final class MapUserLocationFixture: MKUserLocation {
    var position: CLLocation?
    override var location: CLLocation? { position }
}

private final class MapViewLocationFixture: MKMapView {
    let position = MapUserLocationFixture()
    private(set) var centered: CLLocationCoordinate2D?
    private(set) var tracking: MKUserTrackingMode = .none
    private var displayingLocation = false
    override var userLocation: MKUserLocation { position }
    override var showsUserLocation: Bool {
        get { displayingLocation }
        set { displayingLocation = newValue }
    }
    override func setCenter(_ coordinate: CLLocationCoordinate2D, animated: Bool) { centered = coordinate }
    override func setUserTrackingMode(_ mode: MKUserTrackingMode, animated: Bool) { tracking = mode }
}

private struct CampusMapLocationFixture: Decodable {
    enum Review: String, Decodable { case pending, mapped, excluded }
    let campus: String
    let classroom: String
    let expected: String?
    let review: Review
}

@Suite("Campus map location matching")
struct CampusMapLocationTests {
    @Test("Authorization changes preserve denied and revoked permission recovery")
    @MainActor func authorizationAndRevocation() throws {
        let manager = MapLocationManagerFixture()
        let controller = CampusLocationController(manager: manager)
        controller.requestAuthorizationIfNeeded()
        #expect(manager.authorizationRequests == 1)
        #expect(!controller.isAuthorized)
        for status in [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways] {
            manager.status = status
            controller.locationManagerDidChangeAuthorization(manager)
            #expect(controller.isAuthorized)
            controller.requestAuthorizationIfNeeded()
            #expect(manager.authorizationRequests == 1)
            #expect(controller.notice == nil)
        }
        for status in [CLAuthorizationStatus.denied, .restricted] {
            manager.status = status
            controller.locationManagerDidChangeAuthorization(manager)
            #expect(!controller.isAuthorized)
            controller.requestAuthorizationIfNeeded()
            let notice = try #require(controller.notice)
            #expect(notice.title == "定位不可用")
            #expect(notice.recoveryAction == .openAppSettings)
            #expect(!notice.allowsDiagnostics)
            #expect(manager.authorizationRequests == 1)
        }
    }

    @Test("Available precise and approximate positions center the native map", arguments: [0.0, 3_000.0])
    @MainActor func availablePositionCentersMap(accuracy: Double) throws {
        let map = MapViewLocationFixture()
        map.position.position = CLLocation(coordinate: .init(latitude: 39.7, longitude: 116.2), altitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 0, timestamp: Date())
        let coordinator = CampusNativeMapView.Coordinator()
        coordinator.centerOnUser(in: map, requestID: UUID())
        let center = try #require(map.centered)
        #expect(center.latitude == 39.7 && center.longitude == 116.2)
        #expect(map.showsUserLocation && map.tracking == .none)
    }

    @Test("A fresh usable position completes a request after stale or invalid fixes")
    @MainActor func staleAndInvalidPositionsWaitForANewFix() {
        for (age, accuracy) in [(-3_600.0, 20.0), (0.0, -1.0)] {
            let map = MapViewLocationFixture(), coordinator = CampusNativeMapView.Coordinator()
            let stale = CLLocation(coordinate: .init(latitude: 39.7, longitude: 116.2), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 0, timestamp: Date().addingTimeInterval(age))
            map.position.position = stale
            coordinator.centerOnUser(in: map, requestID: UUID())
            coordinator.mapView(map, didUpdate: map.position)
            #expect(map.centered == nil && map.tracking == .follow)
            map.position.position = CLLocation(latitude: 40, longitude: 117)
            coordinator.mapView(map, didUpdate: map.position)
            #expect(map.centered?.latitude == 40 && map.tracking == .none)
        }
    }

    @Test("A pending position tolerates transient failure and waits for valid coordinates")
    @MainActor func pendingPositionWaitsForValidCoordinates() throws {
        let map = MapViewLocationFixture()
        let coordinator = CampusNativeMapView.Coordinator()
        var failures = 0
        coordinator.onLocationFailure = { _ in failures += 1 }
        let request = UUID()
        coordinator.centerOnUser(in: map, requestID: request)
        #expect(map.tracking == .follow && map.centered == nil)
        coordinator.mapView(map, didFailToLocateUserWithError: CLError(.locationUnknown))
        map.position.position = CLLocation(latitude: 100, longitude: 116)
        coordinator.mapView(map, didUpdate: map.position)
        #expect(map.tracking == .follow && map.centered == nil && failures == 0)
        map.position.position = CLLocation(latitude: 39.9, longitude: 116.3)
        coordinator.mapView(map, didUpdate: map.position)
        let center = try #require(map.centered)
        #expect(center.latitude == 39.9 && center.longitude == 116.3)
        #expect(map.tracking == .none && coordinator.lastCenterOnUserRequestID == request)
        map.position.position = CLLocation(latitude: 40, longitude: 117)
        coordinator.mapView(map, didUpdate: map.position)
        #expect(map.centered?.latitude == 39.9)
    }

    @Test("Denied location stops tracking and keeps later updates from moving the map")
    @MainActor func deniedLocationStopsPendingCenter() throws {
        let map = MapViewLocationFixture()
        let controller = CampusLocationController(manager: MapLocationManagerFixture())
        let coordinator = CampusNativeMapView.Coordinator()
        coordinator.onLocationFailure = controller.handleLocationFailure
        coordinator.centerOnUser(in: map, requestID: UUID())
        coordinator.mapView(map, didFailToLocateUserWithError: CLError(.denied))
        #expect(map.tracking == .none)
        let notice = try #require(controller.notice)
        #expect(notice.recoveryAction == .openAppSettings && !notice.allowsDiagnostics)
        map.position.position = CLLocation(latitude: 40, longitude: 117)
        coordinator.mapView(map, didUpdate: map.position)
        #expect(map.centered == nil)
        controller.handleLocationFailure(CLError(.network))
        #expect(controller.notice?.title == "定位失败")
        #expect(controller.notice?.allowsDiagnostics == true)
    }

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

        #expect(!fixtures.isEmpty)
        #expect(Set(fixtures.map { [$0.campus, $0.classroom] }).count == fixtures.count)
        for fixture in fixtures {
            try #require(fixture.review != .pending, "Awaiting location review: \(fixture.campus) / \(fixture.classroom)")
            let parsed = ScheduleDisplayNormalizer.compactLocation(for: fixture.classroom)
            #expect(
                !parsed.lightText.isEmpty,
                "Parser rejected: \(fixture.campus) / \(fixture.classroom)"
            )

            let place = CampusMapPlaceCatalog.place(
                campusName: fixture.campus,
                classroom: fixture.classroom
            )
            if fixture.review == .mapped {
                let expected = try #require(fixture.expected)
                #expect(
                    place?.name == expected,
                    "Location mismatch: \(fixture.campus) / \(fixture.classroom)"
                )
            } else {
                #expect(fixture.expected == nil)
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
        #expect(zhongguancun.coordinate.longitude != liangxiang.coordinate.longitude)
    }

    @Test("Teaching aliases share timetable normalization and campus inference")
    func normalizedTeachingAliases() throws {
        for (classroom, expected) in [
            ("理科教学楼201", "理教楼"), ("理教201", "理教楼"),
            ("工科实训楼101", "工训楼"), ("良乡实训楼101", "工训楼"),
            ("实训楼101", "工训楼"), ("工程训练中心101", "工训楼"), ("工训101", "工训楼")
        ] {
            for campusName in ["良乡校区", ""] {
                let place = try #require(CampusMapPlaceCatalog.place(campusName: campusName, classroom: classroom))
                #expect(place.campus == .liangxiang && place.name == expected)
            }
            #expect(CampusMapPlaceCatalog.place(campusName: "中关村校区", classroom: classroom) == nil)
            #expect(CampusMapPlaceCatalog.place(campusName: "珠海校区", classroom: classroom) == nil)
        }
    }
}
