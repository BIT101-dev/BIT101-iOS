#if os(iOS)
import DesignSystemKit

import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 带校区信息的原生地图标记，供 delegate 选择不同颜色。
private nonisolated final class CampusPlaceAnnotation: MKPointAnnotation {
    let campus: CampusPreset
    let place: CampusMapPlace

    init(place: CampusMapPlace) {
        self.place = place
        self.campus = place.campus
        super.init()
    }
}

/// 一次地图聚焦请求。随机标识允许用户重复点击同一校区并再次触发聚焦。
struct MapFocusRequest: Equatable {
    let id = UUID()
    let preset: CampusPreset
    let animated: Bool
}

/// 每个壳层保留一份真实地图，启动时准备，随后交给地图页面继续交互。
@MainActor
public final class CampusMapPreparation {
    fileprivate let coordinator = CampusNativeMapView.Coordinator()
    var focusRequest = MapFocusRequest(preset: .liangxiang, animated: false)
    private var mapView: MKMapView?
    private var isClaimed = false
    private var isPreparing = false

    public init() {}

    func claim(_ makeView: () -> MKMapView) -> MKMapView {
        if let mapView { return mapView }
        let view = makeView()
        mapView = view
        return view
    }

    func willMount() { isClaimed = true }

    fileprivate func prepare(
        in host: UIView, preset: CampusPreset, target: UpcomingCourseMapTarget?,
        displayMode: CampusMapDisplayMode
    ) {
        guard !isClaimed, !isPreparing, host.window != nil, !host.bounds.isEmpty else { return }
        isPreparing = true
        defer { isPreparing = false }
        if focusRequest.preset != preset {
            focusRequest = MapFocusRequest(preset: preset, animated: false)
        }
        if mapView == nil {
            mapView = CampusNativeMapView.makeMapView(
                frame: host.bounds, coordinator: coordinator, focusRequest: focusRequest,
                nextCourseTarget: target, requestedLocation: nil,
                displayMode: displayMode)
        }
        guard let mapView else { return }
        if mapView.frame != host.bounds { mapView.frame = host.bounds }
        let reparented = mapView.superview !== host
        if reparented { host.addSubview(mapView) }
        if coordinator.lastMapConfigurationID != displayMode.rawValue {
            mapView.preferredConfiguration = displayMode.configuration
            coordinator.lastMapConfigurationID = displayMode.rawValue
        }
        coordinator.syncNextCourseAnnotation(target, in: mapView)
        if reparented || coordinator.lastFocusID != focusRequest.id {
            coordinator.focus(on: preset, in: mapView, animated: false)
            coordinator.lastFocusID = focusRequest.id
        }
    }
}

public struct CampusMapPreparationHost: UIViewRepresentable {
    private let preparation: CampusMapPreparation
    private let nextCourseTarget: UpcomingCourseMapTarget?
    @AppStorage(MapPreferenceKey.selectedCampus)
    private var campusID = CampusPreset.liangxiang.rawValue
    @AppStorage(MapPreferenceKey.displayMode)
    private var mode = CampusMapDisplayMode.standard.rawValue

    public init(preparation: CampusMapPreparation, nextCourseTarget: UpcomingCourseMapTarget?) {
        self.preparation = preparation
        self.nextCourseTarget = nextCourseTarget
    }

    public func makeUIView(context: Context) -> UIView {
        let view = CampusMapPreparationView()
        configure(view)
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        if let view = view as? CampusMapPreparationView { configure(view) }
    }

    private func configure(_ view: CampusMapPreparationView) {
        let preset = nextCourseTarget?.campus ?? CampusPreset(rawValue: campusID) ?? .liangxiang
        let displayMode = CampusMapDisplayMode(rawValue: mode) ?? .standard
        let preparation = preparation
        let target = nextCourseTarget
        view.prepare = { host in
            preparation.prepare(
                in: host, preset: preset, target: target, displayMode: displayMode)
        }
        view.setNeedsLayout()
    }
}

private final class CampusMapPreparationView: UIView {
    var prepare: ((UIView) -> Void)?
    override var accessibilityElements: [Any]? {
        get { [] }
        set {}
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        prepare?(self)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        prepare?(self)
    }
}

/// MapKit 与 SwiftUI 之间的桥接层。
///
/// 原生地图、相机定位和下一节课标记由该桥接层负责。
struct CampusNativeMapView: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let focusRequest: MapFocusRequest
    let centerOnUserRequestID: UUID?
    let isActive: Bool
    let nextCourseTarget: UpcomingCourseMapTarget?
    let requestedLocation: CampusMapLocationRequest?
    let displayMode: CampusMapDisplayMode
    let onLocationFailure: (Error) -> Void
    var preparation: CampusMapPreparation? = nil

    func makeCoordinator() -> Coordinator {
        let coordinator = preparation?.coordinator ?? Coordinator()
        coordinator.onLocationFailure = onLocationFailure
        coordinator.reduceMotion = reduceMotion
        return coordinator
    }

    static func dismantleUIView(_ host: AppPreparedViewHost<MKMapView>, coordinator: Coordinator) {
        let mapView = host.content
        guard mapView.superview === host else { return }
        coordinator.updateLocation(in: mapView, active: false, requestID: nil)
        mapView.delegate = nil
    }

    /// 创建并初始化原生 `MKMapView`。
    ///
    /// 通过原生 `MapKit` 控制相机和定位回调。
    func makeUIView(context: Context) -> AppPreparedViewHost<MKMapView> {
        let makeView = {
            Self.makeMapView(
                frame: .zero, coordinator: context.coordinator, focusRequest: focusRequest,
                nextCourseTarget: nextCourseTarget, requestedLocation: requestedLocation,
                displayMode: displayMode)
        }
        let mapView = preparation?.claim(makeView) ?? makeView()
        let host = AppPreparedViewHost(content: mapView)
        host.onWillMount = { preparation?.willMount() }
        host.onFirstMount = { updateMapView(mapView, coordinator: context.coordinator) }
        return host
    }

    static func makeMapView(
        frame: CGRect, coordinator: Coordinator, focusRequest: MapFocusRequest,
        nextCourseTarget: UpcomingCourseMapTarget?, requestedLocation: CampusMapLocationRequest?,
        displayMode: CampusMapDisplayMode
    ) -> MKMapView {
        let mapView = MKMapView(frame: frame)
        mapView.delegate = coordinator
        mapView.preferredConfiguration = displayMode.configuration
        coordinator.lastMapConfigurationID = displayMode.rawValue
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = false
        mapView.accessibilityLabel = "校园地图"
        mapView.accessibilityHint = "拖动或双指缩放查看校区和上课地点"

        coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)
        coordinator.syncRequestedLocation(requestedLocation, in: mapView)

        coordinator.focus(on: focusRequest.preset, in: mapView, animated: false)
        coordinator.focus(
            on: requestedLocation?.places.first, in: mapView, animated: false)
        coordinator.lastFocusID = focusRequest.id

        return mapView
    }

    /// 根据最新的 SwiftUI 状态同步地图相机和“回到我的位置”动作。
    func updateUIView(_ host: AppPreparedViewHost<MKMapView>, context: Context) {
        if host.isContentMounted {
            updateMapView(host.content, coordinator: context.coordinator)
        } else {
            host.onFirstMount = { updateMapView(host.content, coordinator: context.coordinator) }
        }
    }

    private func updateMapView(_ mapView: MKMapView, coordinator: Coordinator) {
        if mapView.delegate !== coordinator { mapView.delegate = coordinator }
        coordinator.onLocationFailure = onLocationFailure
        coordinator.reduceMotion = reduceMotion
        if coordinator.lastMapConfigurationID != displayMode.rawValue {
            mapView.preferredConfiguration = displayMode.configuration
            coordinator.lastMapConfigurationID = displayMode.rawValue
        }
        coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)
        let requestedLocationChanged = coordinator.syncRequestedLocation(
            requestedLocation, in: mapView)

        if coordinator.lastFocusID != focusRequest.id {
            coordinator.focus(
                on: focusRequest.preset, in: mapView, animated: focusRequest.animated)
            coordinator.lastFocusID = focusRequest.id
            preparation?.focusRequest = focusRequest
        }

        if requestedLocationChanged {
            coordinator.focus(
                on: requestedLocation?.places.first, in: mapView, animated: true)
        }
        coordinator.updateLocation(
            in: mapView, active: isActive, requestID: centerOnUserRequestID)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let annotationReuseIdentifier = "campus-place"
        private(set) var renderedMapSize: CGSize?
        private(set) var renderedMapRect: MKMapRect?
        private(set) var renderedConfigurationID: String?
        private var renderedPerspective: (altitude: Double, pitch: Double, heading: Double)?

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered else { return }
            renderedMapSize = mapView.bounds.size
            renderedMapRect = mapView.visibleMapRect
            renderedConfigurationID = lastMapConfigurationID
            let camera = mapView.camera
            renderedPerspective = (camera.altitude, camera.pitch, camera.heading)
        }

        func hasRenderedContent(in mapView: MKMapView) -> Bool {
            guard let renderedMapRect, let renderedPerspective else { return false }
            let camera = mapView.camera
            return renderedMapSize == mapView.bounds.size
                && renderedMapRect.contains(mapView.visibleMapRect)
                && renderedPerspective == (camera.altitude, camera.pitch, camera.heading)
                && renderedConfigurationID == lastMapConfigurationID
        }

        var lastFocusID: UUID?
        var lastCenterOnUserRequestID: UUID?
        var lastMapConfigurationID: String?
        private var pendingCenterOnUserRequestID: UUID?
        private var lastCourseTarget: UpcomingCourseMapTarget?
        private var lastRequestedLocationID: UUID?
        var onLocationFailure: ((Error) -> Void)?
        var reduceMotion = false
        private weak var nextCourseAnnotation: CampusPlaceAnnotation?
        private var requestedLocationAnnotations: [CampusPlaceAnnotation] = []

        /// 地图展示下一节课的标记；课程变化时原位更新标记。
        func syncNextCourseAnnotation(_ target: UpcomingCourseMapTarget?, in mapView: MKMapView) {
            guard lastCourseTarget != target else { return }

            if let nextCourseAnnotation {
                mapView.removeAnnotation(nextCourseAnnotation)
            }
            nextCourseAnnotation = nil
            lastCourseTarget = target

            guard let target, let place = target.place else { return }
            let annotation = CampusPlaceAnnotation(place: place)
            annotation.coordinate = place.coordinate
            annotation.title = "下一节课在\(place.name)"
            annotation.subtitle = "\(target.courseName) · \(target.startDateText)"
            mapView.addAnnotation(annotation)
            nextCourseAnnotation = annotation
        }

        /// 同步课程详情临时传入的上课地点标记；请求只在当前进程内保留。
        @discardableResult
        func syncRequestedLocation(_ request: CampusMapLocationRequest?, in mapView: MKMapView)
            -> Bool
        {
            guard lastRequestedLocationID != request?.id else { return false }

            for annotation in requestedLocationAnnotations {
                mapView.removeAnnotation(annotation)
            }
            requestedLocationAnnotations = []
            lastRequestedLocationID = request?.id

            guard let request else { return true }
            let annotations = request.places.map { place -> CampusPlaceAnnotation in
                let annotation = CampusPlaceAnnotation(place: place)
                annotation.coordinate = place.coordinate
                annotation.title = request.courseName
                annotation.subtitle = place.name
                return annotation
            }
            mapView.addAnnotations(annotations)
            requestedLocationAnnotations = annotations
            return true
        }

        /// 聚焦到课程详情传入的第一个上课地点；没有地点时保持当前相机。
        func focus(on place: CampusMapPlace?, in mapView: MKMapView, animated: Bool) {
            guard let place else { return }
            pendingCenterOnUserRequestID = nil
            mapView.setUserTrackingMode(.none, animated: false)
            let camera = MKMapCamera(
                lookingAtCenter: place.coordinate,
                fromDistance: 1_200,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: animated && !reduceMotion)
        }

        func focus(on preset: CampusPreset, in mapView: MKMapView, animated: Bool) {
            pendingCenterOnUserRequestID = nil
            mapView.setUserTrackingMode(.none, animated: false)
            mapView.setCamera(
                MKMapCamera(
                    lookingAtCenter: preset.coordinate,
                    fromDistance: preset.distance, pitch: 0, heading: 0),
                animated: animated && !reduceMotion)
        }

        /// 为下一节课和课程详情地点提供原生地图标记。
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation)
            -> MKAnnotationView?
        {
            guard let placeAnnotation = annotation as? CampusPlaceAnnotation else {
                return nil
            }

            let marker: MKMarkerAnnotationView
            if let reused = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.annotationReuseIdentifier
            ) as? MKMarkerAnnotationView {
                marker = reused
                marker.annotation = placeAnnotation
            } else {
                marker = MKMarkerAnnotationView(
                    annotation: placeAnnotation,
                    reuseIdentifier: Self.annotationReuseIdentifier
                )
            }

            marker.canShowCallout = true
            marker.titleVisibility = .visible
            marker.displayPriority = .required
            marker.glyphImage = UIImage(systemName: "building.2.fill")
            marker.markerTintColor = UIColor(
                placeAnnotation.campus == .liangxiang
                    ? AppDesignSystem.Palette.Status.info
                    : AppDesignSystem.Palette.Status.danger
            )
            marker.accessibilityLabel = placeAnnotation.title ?? placeAnnotation.place.name
            marker.accessibilityValue = placeAnnotation.subtitle
            return marker
        }

        /// 页面可见且场景活跃时处理定位请求，结束时释放地图定位资源。
        func updateLocation(in mapView: MKMapView, active: Bool, requestID: UUID?) {
            guard active, let requestID else {
                if mapView.userTrackingMode != .none {
                    mapView.setUserTrackingMode(.none, animated: false)
                }
                if mapView.showsUserLocation { mapView.showsUserLocation = false }
                pendingCenterOnUserRequestID = nil
                lastCenterOnUserRequestID = nil
                return
            }
            if lastCenterOnUserRequestID != requestID {
                centerOnUser(in: mapView, requestID: requestID)
            }
        }

        /// 已有位置立即居中，其余请求等待下一次定位回调。
        func centerOnUser(in mapView: MKMapView, requestID: UUID) {
            lastCenterOnUserRequestID = requestID
            mapView.showsUserLocation = true
            if let coordinate = validUserCoordinate(mapView.userLocation.location) {
                mapView.setUserTrackingMode(.none, animated: false)
                mapView.setCenter(coordinate, animated: false)
                pendingCenterOnUserRequestID = nil
                return
            }

            pendingCenterOnUserRequestID = requestID
            mapView.setUserTrackingMode(.follow, animated: false)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let requestID = pendingCenterOnUserRequestID,
                let coordinate = validUserCoordinate(userLocation.location)
            else {
                return
            }

            mapView.setCenter(coordinate, animated: false)
            mapView.setUserTrackingMode(.none, animated: false)
            lastCenterOnUserRequestID = requestID
            pendingCenterOnUserRequestID = nil
        }

        /// 过滤 `locationUnknown` 瞬时回调，将需要用户处理的定位错误交给页面提示。
        func mapView(_ mapView: MKMapView, didFailToLocateUserWithError error: Error) {
            guard pendingCenterOnUserRequestID != nil else { return }
            if CampusLocationFailurePolicy.contains(error, code: .locationUnknown) {
                return
            }

            pendingCenterOnUserRequestID = nil
            mapView.setUserTrackingMode(.none, animated: false)
            onLocationFailure?(error)
        }

        /// 过滤掉无效或缺失的用户坐标。
        private func validUserCoordinate(_ location: CLLocation?) -> CLLocationCoordinate2D? {
            guard let location, location.horizontalAccuracy >= 0,
                abs(location.timestamp.timeIntervalSinceNow) <= 60
            else {
                return nil
            }

            let coordinate = location.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                return nil
            }

            return coordinate
        }
    }
}

#endif
