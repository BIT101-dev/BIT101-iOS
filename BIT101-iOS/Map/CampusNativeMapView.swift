//
//  CampusNativeMapView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-08-12.
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 带校区信息的原生地图标记，供 delegate 选择不同颜色。
private final class CampusPlaceAnnotation: MKPointAnnotation {
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

/// MapKit 与 SwiftUI 之间的桥接层。
///
/// 原生地图、相机定位和下一节课标记都在这里落地。
struct CampusNativeMapView: UIViewRepresentable {
    let focusRequest: MapFocusRequest
    let centerOnUserRequestID: UUID?
    let nextCourseTarget: UpcomingCourseMapTarget?
    let requestedLocation: CampusMapLocationRequest?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 创建并初始化原生 `MKMapView`。
    ///
    /// 之所以不使用纯 SwiftUI `Map`，是因为这里需要更细粒度地控制相机和定位回调。
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false

        context.coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)
        context.coordinator.syncRequestedLocation(requestedLocation, in: mapView)

        applyFocus(to: mapView, animated: false)
        context.coordinator.focus(on: requestedLocation?.places.first, in: mapView, animated: false)
        context.coordinator.lastFocusID = focusRequest.id

        return mapView
    }

    /// 根据最新的 SwiftUI 状态同步地图相机和“回到我的位置”动作。
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)
        let requestedLocationChanged = context.coordinator.syncRequestedLocation(requestedLocation, in: mapView)

        if context.coordinator.lastCenterOnUserRequestID != centerOnUserRequestID,
           let centerOnUserRequestID {
            context.coordinator.centerOnUser(in: mapView, requestID: centerOnUserRequestID)
        }

        if context.coordinator.lastFocusID != focusRequest.id {
            applyFocus(to: mapView, animated: focusRequest.animated)
            context.coordinator.lastFocusID = focusRequest.id
        }

        if requestedLocationChanged {
            context.coordinator.focus(on: requestedLocation?.places.first, in: mapView, animated: true)
        }
    }

    private func applyFocus(to mapView: MKMapView, animated: Bool) {
        mapView.setUserTrackingMode(.none, animated: false)
        let camera = MKMapCamera(
            lookingAtCenter: focusRequest.preset.coordinate,
            fromDistance: focusRequest.preset.distance,
            pitch: 0,
            heading: 0
        )
        mapView.setCamera(camera, animated: animated)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let annotationReuseIdentifier = "campus-place"

        var lastFocusID: UUID?
        var lastCenterOnUserRequestID: UUID?
        private var pendingCenterOnUserRequestID: UUID?
        private var lastCourseTargetID: String?
        private var lastRequestedLocationID: UUID?
        private weak var nextCourseAnnotation: CampusPlaceAnnotation?
        private var requestedLocationAnnotations: [CampusPlaceAnnotation] = []

        /// 地图只保留下一节课的一个 pin；课程变化时原地替换，不残留校对标记。
        func syncNextCourseAnnotation(_ target: UpcomingCourseMapTarget?, in mapView: MKMapView) {
            guard lastCourseTargetID != target?.id else { return }

            if let nextCourseAnnotation {
                mapView.removeAnnotation(nextCourseAnnotation)
            }
            nextCourseAnnotation = nil
            lastCourseTargetID = target?.id

            guard let target, let place = target.place else { return }
            let annotation = CampusPlaceAnnotation(place: place)
            annotation.coordinate = place.coordinate
            annotation.title = "下一节课在\(place.name)"
            annotation.subtitle = "\(target.courseName) · \(ScheduleDateCodec.formatRelativeDateTime(target.startDate))"
            mapView.addAnnotation(annotation)
            nextCourseAnnotation = annotation
        }

        /// 同步课程详情临时传入的上课地点 pin；请求只在当前进程内保留。
        @discardableResult
        func syncRequestedLocation(_ request: CampusMapLocationRequest?, in mapView: MKMapView) -> Bool {
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

        /// 聚焦到课程详情传入的第一个上课地点；清空请求时恢复到校区视角。
        func focus(on place: CampusMapPlace?, in mapView: MKMapView, animated: Bool) {
            guard let place else { return }
            mapView.setUserTrackingMode(.none, animated: false)
            let camera = MKMapCamera(
                lookingAtCenter: place.coordinate,
                fromDistance: 1_200,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: animated)
        }

        /// 为下一节课地点提供可点开课程信息的原生 marker。
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
            marker.markerTintColor = placeAnnotation.campus == .liangxiang ? .systemBlue : .systemRed
            return marker
        }

        /// 如果当前位置已经可用，就直接居中；否则切到 follow 等待下一次定位回调。
        func centerOnUser(in mapView: MKMapView, requestID: UUID) {
            if let coordinate = validUserCoordinate(from: mapView) {
                mapView.setUserTrackingMode(.none, animated: false)
                mapView.setCenter(coordinate, animated: false)
                lastCenterOnUserRequestID = requestID
                pendingCenterOnUserRequestID = nil
                return
            }

            pendingCenterOnUserRequestID = requestID
            mapView.setUserTrackingMode(.follow, animated: false)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let requestID = pendingCenterOnUserRequestID,
                  let coordinate = userLocation.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else {
                return
            }

            mapView.setCenter(coordinate, animated: false)
            mapView.setUserTrackingMode(.none, animated: false)
            lastCenterOnUserRequestID = requestID
            pendingCenterOnUserRequestID = nil
        }

        /// 过滤掉无效或缺失的用户坐标。
        private func validUserCoordinate(from mapView: MKMapView) -> CLLocationCoordinate2D? {
            guard let location = mapView.userLocation.location else {
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
