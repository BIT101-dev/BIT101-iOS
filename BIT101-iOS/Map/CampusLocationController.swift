//
//  CampusLocationController.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-08-12.
//

import Combine
import CoreLocation
import Foundation

/// 地图页提示弹窗模型。
struct MapNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 地图页定位控制器。
///
/// 封装定位授权状态、当前位置请求和错误提示。视图层通过控制器访问 `CLLocationManager`。
@MainActor
final class CampusLocationController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    /// 当前需要直接弹给用户的定位提示。
    @Published var notice: MapNotice?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// 表示当前定位权限足以直接请求位置。
    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// 根据当前授权状态发起定位或引导用户授权。
    func locateUser() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            notice = MapNotice(
                title: "定位不可用",
                message: "请在系统设置中允许 BIT101 使用定位后，再尝试回到我的位置。"
            )
        @unknown default:
            notice = MapNotice(
                title: "定位不可用",
                message: "当前定位状态无法识别。"
            )
        }
    }

    /// 更新定位授权状态，并在授权后继续请求当前位置。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            locateUser()
        }
    }

    /// 位置回调保留 `CLLocationManagerDelegate` 契约，地图桥接层自行读取系统位置。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // `requestLocation()` 通过此 delegate 回调返回；坐标由地图桥接层读取。
    }

    /// 过滤常见的瞬时错误，并为需要用户处理的错误显示提示。
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           let code = CLError.Code(rawValue: nsError.code),
           code == .locationUnknown {
            return
        }

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        notice = MapNotice(
            title: "定位失败",
            message: error.localizedDescription
        )
    }
}
