//
//  CampusMapLocations.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-08-12.
//

import CoreLocation
import Foundation

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

    /// VoiceOver 和其它需要完整语义的界面使用的校区名。
    var displayName: String {
        switch self {
        case .liangxiang:
            return "良乡校区"
        case .zhongguancun:
            return "中关村校区"
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
struct CampusMapPlace: Equatable, Identifiable {
    let campus: CampusPreset
    let name: String
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    var id: String {
        "\(campus.rawValue):\(name):\(latitude):\(longitude)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// 从课程详情页临时带到地图页的上课地点请求。
///
/// 只存在于当前进程内，不写入设置或课表缓存；应用冷启动后自然清空。
struct CampusMapLocationRequest: Equatable, Identifiable {
    let id = UUID()
    let courseName: String
    let places: [CampusMapPlace]

    init(courseName: String, places: [CampusMapPlace]) {
        self.courseName = courseName
        self.places = places
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
