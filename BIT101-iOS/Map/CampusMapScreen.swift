//
//  CampusMapScreen.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 地图页用到的本地偏好键。
///
/// 当前地图模块只持久化“用户上次停留在哪个校区”，避免每次打开都回到默认校区。
private enum MapPreferenceKey {
    static let selectedCampus = "map.selectedCampus"
}

/// 地图页支持的校区预设。
///
/// 校园地图当前不是自由搜索式地图，而是围绕几个固定校区跳转，
/// 所以把中心点和默认半径都内置在预设里。
enum CampusPreset: String, CaseIterable, Identifiable {
    case liangxiang
    case zhongguancun

    /// 供切换按钮绑定的稳定标识。
    var id: String { rawValue }

    /// 右下角校区切换按钮上的短标签。
    var shortLabel: String {
        switch self {
        case .liangxiang:
            return "乡"
        case .zhongguancun:
            return "村"
        }
    }

    /// 当前校区在地图上的中心点。
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .liangxiang:
            // 预先校准到当前系统地图坐标系，避免每次进入地图都再做转换。
            return CLLocationCoordinate2D(latitude: 39.73027614839699, longitude: 116.17276949062236)
        case .zhongguancun:
            return CLLocationCoordinate2D(latitude: 39.95966806175981, longitude: 116.31597988552478)
        }
    }

    /// 当前校区默认聚焦半径。
    var distance: CLLocationDistance {
        switch self {
        case .liangxiang:
            return 4500
        case .zhongguancun:
            return 3200
        }
    }
}

/// 课程地点匹配和“下一节课”地图标记使用的校园地点。
///
/// 显示名可在不同校区重复（如“体育馆”）；匹配时会同时检查校区，
/// 因此不会把同名建筑导航到另一个校区。
struct CampusMapPlace: Equatable {
    let campus: CampusPreset
    let name: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// 清洗后的中关村、良乡校园地点坐标。
enum CampusMapPlaceCatalog {
    static let all: [CampusMapPlace] = [
        CampusMapPlace(campus: .zhongguancun, name: "1号楼", latitude: 39.960329831, longitude: 116.321710584),
        CampusMapPlace(campus: .zhongguancun, name: "3号楼", latitude: 39.960124, longitude: 116.318328),
        CampusMapPlace(campus: .zhongguancun, name: "5号楼", latitude: 39.958916, longitude: 116.321629),
        CampusMapPlace(campus: .zhongguancun, name: "6号楼", latitude: 39.964369, longitude: 116.309974),
        CampusMapPlace(campus: .zhongguancun, name: "7号楼", latitude: 39.95852, longitude: 116.31705),
        CampusMapPlace(campus: .zhongguancun, name: "8号楼", latitude: 39.957801, longitude: 116.31672),
        CampusMapPlace(campus: .zhongguancun, name: "9号楼", latitude: 39.95728, longitude: 116.315833),
        CampusMapPlace(campus: .zhongguancun, name: "东操场", latitude: 39.959241, longitude: 116.315708),
        CampusMapPlace(campus: .zhongguancun, name: "体育馆", latitude: 39.959157, longitude: 116.314487),
        CampusMapPlace(campus: .zhongguancun, name: "中教", latitude: 39.959307, longitude: 116.317018),
        CampusMapPlace(campus: .zhongguancun, name: "主楼", latitude: 39.9597, longitude: 116.321642),
        CampusMapPlace(campus: .zhongguancun, name: "宇航楼", latitude: 39.961005, longitude: 116.319164),
        CampusMapPlace(campus: .zhongguancun, name: "求是楼", latitude: 39.959983, longitude: 116.316995),
        CampusMapPlace(campus: .zhongguancun, name: "研楼", latitude: 39.957561, longitude: 116.317914),
        CampusMapPlace(campus: .liangxiang, name: "前沿交叉大楼", latitude: 39.727868, longitude: 116.173837812),
        CampusMapPlace(campus: .liangxiang, name: "化学实验中心", latitude: 39.727976, longitude: 116.170456),
        CampusMapPlace(campus: .liangxiang, name: "南校区排球场", latitude: 39.727385, longitude: 116.169575401),
        CampusMapPlace(campus: .liangxiang, name: "南校区篮球场", latitude: 39.728212, longitude: 116.169789),
        CampusMapPlace(campus: .liangxiang, name: "南校区网球场", latitude: 39.727562760, longitude: 116.168954012),
        CampusMapPlace(campus: .liangxiang, name: "南校区足球场", latitude: 39.729583, longitude: 116.169174),
        CampusMapPlace(campus: .liangxiang, name: "工业生态楼", latitude: 39.726106, longitude: 116.170976),
        CampusMapPlace(campus: .liangxiang, name: "工训楼", latitude: 39.726286, longitude: 116.17376),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼A", latitude: 39.732606, longitude: 116.174479),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼B", latitude: 39.732217, longitude: 116.174489),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼C", latitude: 39.731655, longitude: 116.174267),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼E", latitude: 39.731671, longitude: 116.173463),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼F", latitude: 39.73206, longitude: 116.173821),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼G", latitude: 39.732216, longitude: 116.173101),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼H", latitude: 39.732995, longitude: 116.173098),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼I", latitude: 39.733083, longitude: 116.173866),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼J", latitude: 39.733518, longitude: 116.173408),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼K", latitude: 39.733464, longitude: 116.173833),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼L", latitude: 39.733525, longitude: 116.174175),
        CampusMapPlace(campus: .liangxiang, name: "文萃楼M", latitude: 39.733058, longitude: 116.174525),
        CampusMapPlace(campus: .liangxiang, name: "体育馆", latitude: 39.732023662, longitude: 116.176777618),
        CampusMapPlace(campus: .liangxiang, name: "物理实验中心", latitude: 39.729071, longitude: 116.170698),
        CampusMapPlace(campus: .liangxiang, name: "理学楼", latitude: 39.729255, longitude: 116.171807),
        CampusMapPlace(campus: .liangxiang, name: "理教楼", latitude: 39.73028, longitude: 116.171561),
        CampusMapPlace(campus: .liangxiang, name: "疏桐A地下", latitude: 39.728854, longitude: 116.168183812),
        CampusMapPlace(campus: .liangxiang, name: "综教A", latitude: 39.733193, longitude: 116.170654),
        CampusMapPlace(campus: .liangxiang, name: "综教B", latitude: 39.733184, longitude: 116.171878),
    ]

    /// 把教务课表中的“教室号”归并到建筑级地图地点。
    ///
    /// 课表会返回 `文萃楼I203`、`3号楼314` 这类带门牌号文本；地图只保存
    /// 建筑坐标。匹配时同时使用校区，允许两个校区都显示“体育馆”而不串址。
    static func place(campusName: String, classroom: String) -> CampusMapPlace? {
        let normalizedClassroom = classroom
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        let compactLocation = ScheduleDisplayNormalizer.compactLocation(for: classroom)
        guard let campus = campus(campusName: campusName, classroom: normalizedClassroom),
              let buildingName = [
                  normalizedClassroom,
                  compactLocation.lightText,
                  compactLocation.lightBuilding,
              ].lazy.compactMap({ buildingName(campus: campus, classroom: $0) }).first else {
            return nil
        }

        return all.first { $0.campus == campus && $0.name == buildingName }
    }

    /// 优先使用教务返回的校区；共享课表等旧数据缺失校区时，再按建筑前缀推断。
    static func campus(campusName: String, classroom: String) -> CampusPreset? {
        if campusName.contains("良乡") { return .liangxiang }
        if campusName.contains("中关村") { return .zhongguancun }

        let liangxiangPrefixes = [
            "文萃", "综教", "理教", "理学", "工训", "工业生态", "化学实验",
            "物理实验", "疏桐", "南校区", "前沿交叉", "交叉大楼", "良乡体育馆"
        ]
        if liangxiangPrefixes.contains(where: classroom.contains) {
            return .liangxiang
        }

        let zhongguancunPrefixes = ["研楼", "中教", "主楼", "宇航楼", "求是楼", "中关村"]
        if zhongguancunPrefixes.contains(where: classroom.contains) {
            return .zhongguancun
        }
        return nil
    }

    /// 将同一建筑的门牌号和历史异写归并为地图显示名称。
    private static func buildingName(campus: CampusPreset, classroom: String) -> String? {
        switch campus {
        case .zhongguancun:
            for number in [1, 3, 5, 6, 7, 8, 9]
            where containsNumberedBuilding(number, in: classroom) {
                return "\(number)号楼"
            }
            if classroom.contains("东操场") { return "东操场" }
            if classroom.contains("体育馆") { return "体育馆" }
            if classroom.contains("中教") || classroom.contains("中心教学楼") { return "中教" }
            if classroom.contains("主楼") { return "主楼" }
            if classroom.contains("宇航楼") { return "宇航楼" }
            if classroom.contains("求是楼") { return "求是楼" }
            if classroom.contains("研楼") || classroom.contains("研究生教学楼") { return "研楼" }

        case .liangxiang:
            if classroom.contains("前沿交叉") || classroom.contains("交叉大楼") { return "前沿交叉大楼" }
            if classroom.contains("化学实验") { return "化学实验中心" }
            if classroom.contains("体育馆") || classroom.contains("游泳馆") { return "体育馆" }
            if classroom.contains("排球场") { return "南校区排球场" }
            if classroom.contains("篮球场") { return "南校区篮球场" }
            if classroom.contains("网球场") { return "南校区网球场" }
            if classroom.contains("足球场") || classroom.contains("田径场") { return "南校区足球场" }

            if let range = classroom.range(of: #"文萃(?:楼)?([A-M])"#, options: .regularExpression) {
                let match = String(classroom[range])
                if let letter = match.last(where: { $0.isASCII && $0.isLetter }) {
                    return "文萃楼\(letter.uppercased())"
                }
            }
            if classroom.contains("工业生态楼") { return "工业生态楼" }
            if classroom.contains("工训楼") || classroom.contains("工程训练中心") { return "工训楼" }
            if classroom.contains("物理实验中心") { return "物理实验中心" }
            if classroom.contains("理学") { return "理学楼" }
            if classroom.contains("理教楼") { return "理教楼" }
            if classroom.contains("疏桐") { return "疏桐A地下" }
            if classroom.contains("综教A") { return "综教A" }
            if classroom.contains("综教B") { return "综教B" }
        }
        return nil
    }

    /// 避免把 `11号楼` 误识别成 `1号楼`。
    private static func containsNumberedBuilding(_ number: Int, in classroom: String) -> Bool {
        classroom.range(
            of: #"(?:^|[^0-9])\#(number)号(?:教学)?楼"#,
            options: .regularExpression
        ) != nil
    }
}

/// 地图页从主课表中解析出的下一节课程。
struct UpcomingCourseMapTarget: Equatable {
    let id: String
    let courseName: String
    let classroom: String
    let startDate: Date
    let campus: CampusPreset?
    let place: CampusMapPlace?
}

/// 从本地课表缓存中解析“下一节课 + 校区 + 建筑”。
enum UpcomingCourseMapResolver {
    static func nextTarget(in cache: ScheduleCache, now: Date = Date()) -> UpcomingCourseMapTarget? {
        guard let firstDay = cache.firstDay else { return nil }
        let slots = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })

        return cache.courses.flatMap { course -> [UpcomingCourseMapTarget] in
            guard let startSlot = slots[course.startSection] else { return [] }
            let campus = CampusMapPlaceCatalog.campus(
                campusName: course.campus,
                classroom: course.classroom
            )
            let place = CampusMapPlaceCatalog.place(
                campusName: course.campus,
                classroom: course.classroom
            )

            return course.weeks.compactMap { week in
                guard let startDate = ScheduleSharedDateCodec.combine(
                    firstDay: firstDay,
                    week: week,
                    weekday: course.weekday,
                    time: startSlot.start
                ), startDate > now else {
                    return nil
                }

                return UpcomingCourseMapTarget(
                    id: "\(course.id)-\(startDate.timeIntervalSinceReferenceDate)",
                    courseName: course.name,
                    classroom: course.classroom,
                    startDate: startDate,
                    campus: campus,
                    place: place
                )
            }
        }
        .min { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.courseName < rhs.courseName
        }
    }
}

/// 带校区信息的原生地图标记，供 delegate 选择不同颜色。
private final class CampusPlaceAnnotation: MKPointAnnotation {
    let campus: CampusPreset

    init(campus: CampusPreset) {
        self.campus = campus
        super.init()
    }
}

/// SwiftUI 发给 `MKMapView` 的“聚焦请求”。
///
/// 额外带一个随机 `id`，用于强制区分两次落点相同但需要重新动画聚焦的操作。
private enum MapFocusDestination: Equatable {
    case preset(CampusPreset)

    /// 目标落点坐标。
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case let .preset(preset):
            return preset.coordinate
        }
    }

    /// 目标落点聚焦半径。
    var distance: CLLocationDistance {
        switch self {
        case let .preset(preset):
            return preset.distance
        }
    }
}

/// 一次地图聚焦请求的包装结构。
///
/// 如果只传 destination，本次请求和上一次完全相同时 SwiftUI 可能不会认为有变化。
/// 加一层带 `UUID` 的包装后，即使目标相同，也能强制触发一次新的聚焦动作。
private struct MapFocusRequest: Equatable {
    let id = UUID()
    let destination: MapFocusDestination
    let animated: Bool
}

/// 地图页提示弹窗模型。
private struct MapNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 地图页定位控制器。
///
/// 统一封装定位授权状态、请求当前位置和错误提示，避免视图层直接跟 `CLLocationManager` 打交道。
@MainActor
private final class CampusLocationController: NSObject, ObservableObject, CLLocationManagerDelegate {
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

    /// 当前定位权限是否足够直接请求位置。
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

    /// 当定位权限变化时，必要时自动继续完成一次挂起的定位请求。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            locateUser()
        }
    }

    /// 位置回调当前只作为契约保留，聚焦动作交给地图桥接层自己读取系统位置。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // `requestLocation()` 依赖这个 delegate 回调存在；这里不再向外发布坐标，只保留契约。
    }

    /// 过滤掉常见的瞬时错误，只把真正需要用户感知的问题弹出来。
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

/// 校园地图主页面。
///
/// 使用 MapKit 承载自定义瓦片图层，并提供与 Android 版本一致的校区跳转入口。
struct CampusMapScreen: View {
    @ObservedObject var scheduleViewModel: ScheduleViewModel
    @AppStorage(MapPreferenceKey.selectedCampus) private var selectedCampusID = CampusPreset.liangxiang.rawValue
    @StateObject private var locationController = CampusLocationController()
    /// SwiftUI 发给地图桥接层的聚焦请求。
    @State private var focusRequest = MapFocusRequest(destination: .preset(.liangxiang), animated: false)
    /// “回到我的位置”动作的请求版本号。
    @State private var centerOnUserRequestID: UUID?
    /// 如果授权弹窗尚未结束，先挂起一次回到当前位置请求。
    @State private var pendingCenterOnUserAfterAuthorization = false
    /// 防止 `onAppear` 重复覆盖用户当前选中的校区。
    @State private var hasRestoredStoredCampus = false

    /// 地图主页主体。
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CampusTileMapView(
                focusRequest: focusRequest,
                centerOnUserRequestID: centerOnUserRequestID,
                nextCourseTarget: nextCourseTarget,
                scale: 1
            )
            .ignoresSafeArea(edges: [.top, .bottom])

            VStack(alignment: .trailing, spacing: 10) {
                if let place = nextCourseTarget?.place {
                    FloatingMapButton(systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        openDirections(to: place)
                    }
                }

                FloatingMapButton(systemImage: locationController.isAuthorized ? "location.fill" : "location") {
                    centerOnUser()
                }

                ForEach(CampusPreset.allCases) { preset in
                    FloatingMapLabelButton(
                        label: preset.shortLabel,
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
        focusRequest = MapFocusRequest(destination: .preset(preset), animated: animated)
    }

    /// 地图首次出现或课表缓存更新后，自动切换到下一节课所在校区。
    private func focusOnNextCourseIfPossible(animated: Bool) {
        guard let target = nextCourseTarget else {
            focusRequest = MapFocusRequest(destination: .preset(selectedCampus), animated: animated)
            return
        }

        if let campus = target.campus {
            selectedCampusID = campus.rawValue
        }
        if let campus = target.campus {
            focusRequest = MapFocusRequest(destination: .preset(campus), animated: animated)
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
    }
}

/// 校区快捷切换按钮。
///
/// 这里用极简的单字标签，是因为按钮空间很小；完整校区名由地图内容本身承担识别。
private struct FloatingMapLabelButton: View {
    let label: String
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
    }
}

/// MapKit 与 SwiftUI 之间的桥接层。
///
/// 瓦片地图、相机定位和 overlay renderer 都在这里落地。
private struct CampusTileMapView: UIViewRepresentable {
    let focusRequest: MapFocusRequest
    let centerOnUserRequestID: UUID?
    let nextCourseTarget: UpcomingCourseMapTarget?
    let scale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 创建并初始化原生 `MKMapView`。
    ///
    /// 之所以不使用纯 SwiftUI `Map`，是因为这里需要更细粒度地控制瓦片、相机和定位回调。
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = true

        context.coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)

        applyFocus(to: mapView, animated: false, scale: scale)
        context.coordinator.lastFocusID = focusRequest.id
        context.coordinator.lastScale = scale

        return mapView
    }

    /// 根据最新的 SwiftUI 状态同步地图相机、缩放和“回到我的位置”动作。
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.syncNextCourseAnnotation(nextCourseTarget, in: mapView)

        if context.coordinator.lastCenterOnUserRequestID != centerOnUserRequestID,
           let centerOnUserRequestID {
            context.coordinator.centerOnUser(in: mapView, requestID: centerOnUserRequestID)
        }

        if context.coordinator.lastFocusID != focusRequest.id {
            applyFocus(to: mapView, animated: focusRequest.animated, scale: scale)
            context.coordinator.lastFocusID = focusRequest.id
            context.coordinator.lastScale = scale
            return
        }

        guard context.coordinator.lastScale != scale else { return }

        applyScale(to: mapView, from: context.coordinator.lastScale ?? scale, to: scale)
        context.coordinator.lastScale = scale
    }

    private func applyFocus(to mapView: MKMapView, animated: Bool, scale: Double) {
        mapView.setUserTrackingMode(.none, animated: false)
        let camera = MKMapCamera(
            lookingAtCenter: focusRequest.destination.coordinate,
            fromDistance: focusRequest.destination.distance / scale,
            pitch: 0,
            heading: 0
        )
        mapView.setCamera(camera, animated: animated)
    }

    /// 在不改变当前中心点的前提下，仅调整缩放比例。
    private func applyScale(to mapView: MKMapView, from oldScale: Double, to newScale: Double) {
        let currentDistance = max(mapView.camera.centerCoordinateDistance, 1)
        let newDistance = currentDistance * oldScale / newScale
        let camera = MKMapCamera(
            lookingAtCenter: mapView.centerCoordinate,
            fromDistance: newDistance,
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private static let annotationReuseIdentifier = "campus-place"

        var lastFocusID: UUID?
        var lastScale: Double?
        var lastCenterOnUserRequestID: UUID?
        private var pendingCenterOnUserRequestID: UUID?
        private var lastCourseTargetID: String?
        private weak var nextCourseAnnotation: CampusPlaceAnnotation?

        /// 地图只保留下一节课的一个 pin；课程变化时原地替换，不残留校对标记。
        func syncNextCourseAnnotation(_ target: UpcomingCourseMapTarget?, in mapView: MKMapView) {
            guard lastCourseTargetID != target?.id else { return }

            if let nextCourseAnnotation {
                mapView.removeAnnotation(nextCourseAnnotation)
            }
            nextCourseAnnotation = nil
            lastCourseTargetID = target?.id

            guard let target, let place = target.place else { return }
            let annotation = CampusPlaceAnnotation(campus: place.campus)
            annotation.coordinate = place.coordinate
            annotation.title = place.name
            annotation.subtitle = "\(target.courseName) · \(ScheduleDateCodec.formatRelativeDateTime(target.startDate))"
            mapView.addAnnotation(annotation)
            nextCourseAnnotation = annotation
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

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }

            return MKTileOverlayRenderer(tileOverlay: tileOverlay)
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
