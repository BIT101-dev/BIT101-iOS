//
//  CampusMapScreen.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import MapKit
import SwiftUI

/// 地图页用到的本地偏好键。
///
/// 当前地图模块只持久化“用户上次停留在哪个校区”，避免每次打开都回到默认校区。
private enum MapPreferenceKey {
    static let selectedCampus = "map.selectedCampus"
}

/// 校园地图主页面。
///
/// 使用原生 MapKit 展示下一节课的位置，并提供校区切换和系统地图导航入口。
struct CampusMapScreen: View {
    @ObservedObject var scheduleViewModel: ScheduleViewModel
    @AppStorage(MapPreferenceKey.selectedCampus) private var selectedCampusID = CampusPreset.liangxiang.rawValue
    @StateObject private var locationController = CampusLocationController()
    /// SwiftUI 发给地图桥接层的聚焦请求。
    @State private var focusRequest = MapFocusRequest(preset: .liangxiang, animated: false)
    /// “回到我的位置”动作的请求版本号。
    @State private var centerOnUserRequestID: UUID?
    /// 如果授权弹窗尚未结束，先挂起一次回到当前位置请求。
    @State private var pendingCenterOnUserAfterAuthorization = false
    /// 防止 `onAppear` 重复覆盖用户当前选中的校区。
    @State private var hasRestoredStoredCampus = false

    /// 地图主页主体。
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CampusNativeMapView(
                focusRequest: focusRequest,
                centerOnUserRequestID: centerOnUserRequestID,
                nextCourseTarget: nextCourseTarget
            )
            .ignoresSafeArea(edges: [.top, .bottom])

            VStack(alignment: .trailing, spacing: 10) {
                if let place = nextCourseTarget?.place {
                    FloatingMapButton(
                        systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                        accessibilityLabel: "导航到下一节课"
                    ) {
                        openDirections(to: place)
                    }
                }

                FloatingMapButton(
                    systemImage: locationController.isAuthorized ? "location.fill" : "location",
                    accessibilityLabel: "定位到我的位置"
                ) {
                    centerOnUser()
                }

                ForEach(CampusPreset.allCases) { preset in
                    FloatingMapLabelButton(
                        label: preset.shortLabel,
                        accessibilityLabel: "切换到\(preset.displayName)",
                        isSelected: preset == selectedCampus
                    ) {
                        jump(to: preset, animated: false)
                    }
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !hasRestoredStoredCampus else { return }
            hasRestoredStoredCampus = true
            focusOnNextCourseIfPossible(animated: false)
        }
        .task {
            await scheduleViewModel.loadIfNeeded()
            focusOnNextCourseIfPossible(animated: false)
        }
        .onChange(of: nextCourseTarget?.id) { _, _ in
            focusOnNextCourseIfPossible(animated: false)
        }
        .onReceive(locationController.$authorizationStatus.dropFirst()) { status in
            guard pendingCenterOnUserAfterAuthorization else { return }

            if status == .authorizedAlways || status == .authorizedWhenInUse {
                pendingCenterOnUserAfterAuthorization = false
                centerOnUserRequestID = UUID()
            } else if status != .notDetermined {
                pendingCenterOnUserAfterAuthorization = false
            }
        }
        .alert(item: $locationController.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    /// 切换到指定校区并更新本地持久化。
    private func jump(to preset: CampusPreset, animated: Bool) {
        selectedCampusID = preset.rawValue
        focusRequest = MapFocusRequest(preset: preset, animated: animated)
    }

    /// 地图首次出现或课表缓存更新后，自动切换到下一节课所在校区。
    private func focusOnNextCourseIfPossible(animated: Bool) {
        guard let target = nextCourseTarget else {
            focusRequest = MapFocusRequest(preset: selectedCampus, animated: animated)
            return
        }

        if let campus = target.campus {
            selectedCampusID = campus.rawValue
            focusRequest = MapFocusRequest(preset: campus, animated: animated)
        }
    }

    /// 交给系统地图提供步行导航；App 内地图只负责校园定位，不重复实现转向播报。
    private func openDirections(to place: CampusMapPlace) {
        let placemark = MKPlacemark(coordinate: place.coordinate)
        let destination = MKMapItem(placemark: placemark)
        destination.name = place.name
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    /// 聚焦到当前位置，必要时先触发授权流程。
    private func centerOnUser() {
        if locationController.isAuthorized {
            pendingCenterOnUserAfterAuthorization = false
            locationController.locateUser()
            centerOnUserRequestID = UUID()
        } else {
            pendingCenterOnUserAfterAuthorization = true
            locationController.locateUser()
        }
    }

    /// 当前持久化选中的校区。
    private var selectedCampus: CampusPreset {
        CampusPreset(rawValue: selectedCampusID) ?? .liangxiang
    }

    /// 主课表中尚未开始的最近一节课程。
    private var nextCourseTarget: UpcomingCourseMapTarget? {
        UpcomingCourseMapResolver.nextTarget(in: scheduleViewModel.cache)
    }
}

/// 圆形悬浮按钮的统一样式。
///
/// 地图页的定位按钮和其它圆形入口都复用这一套样式，保持与话廊/日程悬浮按钮观感一致。
private struct FloatingMapButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    /// 通用圆形按钮主体。
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 校区快捷切换按钮。
///
/// 这里用极简的单字标签，是因为按钮空间很小；完整校区名由地图内容本身承担识别。
private struct FloatingMapLabelButton: View {
    let label: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    /// 校区切换按钮主体。
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 42, height: 42)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: Circle()
        )
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
