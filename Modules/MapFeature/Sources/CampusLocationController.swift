#if os(iOS)
import DesignSystemKit
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
nonisolated struct MapNotice: DiagnosticAlertPresentable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryAction: AppRecoveryAction?
    let allowsDiagnostics: Bool
    let showsRecoveryLinks: Bool

    init(
        title: String,
        message: String,
        recoveryAction: AppRecoveryAction? = nil,
        allowsDiagnostics: Bool = true,
        showsRecoveryLinks: Bool = true
    ) {
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
        self.allowsDiagnostics = allowsDiagnostics
        self.showsRecoveryLinks = showsRecoveryLinks
    }

    static func userInput(
        title: String,
        message: String,
        recoveryAction: AppRecoveryAction? = nil
    ) -> MapNotice {
        MapNotice(
            title: title,
            message: message,
            recoveryAction: recoveryAction,
            allowsDiagnostics: false
        )
    }
}

/// 地图页定位控制器。
///
/// 封装定位授权状态和错误提示。当前位置由地图桥接层通过 `MKMapView` 管理。
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
    }

    /// 表示当前定位权限足以直接请求位置。
    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// 根据当前授权状态请求权限；已有权限由地图桥接层启动位置更新。
    func requestAuthorizationIfNeeded() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .denied, .restricted:
            notice = MapNotice.userInput(
                title: "定位不可用",
                message: "请在系统设置中允许 BIT101 使用定位后，再尝试回到我的位置。",
                recoveryAction: .openAppSettings
            )
        @unknown default:
            notice = MapNotice.userInput(
                title: "定位不可用",
                message: "当前定位状态无法识别。"
            )
        }
    }

    func handleLocationFailure(_ error: Error) {
        notice = CampusLocationFailurePolicy.notice(for: error)
    }

    /// 更新定位授权状态；当前位置由地图桥接层继续处理。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}

nonisolated enum CampusLocationFailurePolicy {
    static func notice(for error: Error) -> MapNotice {
        if contains(error, code: .denied) {
            return .userInput(
                title: "定位不可用",
                message: "请在系统设置中允许 BIT101 使用定位服务后，再尝试回到我的位置。",
                recoveryAction: .openAppSettings
            )
        }
        return MapNotice(title: "定位失败", message: error.localizedDescription)
    }

    static func contains(_ error: Error, code: CLError.Code) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0 ..< 8 {
            guard let candidate = current else { return false }
            if candidate.domain == kCLErrorDomain,
               CLError.Code(rawValue: candidate.code) == code {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

#endif
