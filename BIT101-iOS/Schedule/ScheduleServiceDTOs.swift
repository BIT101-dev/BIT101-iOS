//
//  ScheduleServiceDTOs.swift
//  BIT101-iOS
//

import Foundation

/// 当前学期接口响应体。
struct CurrentTermResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [TermRow]
        }

        let dqxnxq: Rows
    }

    struct TermRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case code = "DM"
        }

        let code: String
    }

    let datas: Datas
}

/// 可选学期列表接口响应体。
nonisolated struct TermsResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [TermRow]
        }

        let xnxqcx: Rows
    }

    struct TermRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case code = "DM"
        }

        let code: String
    }

    let datas: Datas
}

/// 课程表接口响应体。
struct CourseResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [CourseRow]
        }

        let cxxszhxqkb: Rows
    }

    struct CourseRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case term = "XNXQDM"
            case name = "KCM"
            case teacher = "SKJS"
            case classroom = "JASMC"
            case scheduleDescription = "YPSJDD"
            case rawWeeks = "SKZC"
            case weekday = "SKXQ"
            case startSection = "KSJC"
            case endSection = "JSJC"
            case campus = "XXXQMC"
            case courseNumber = "KCH"
            case credit = "XF"
            case hour = "XS"
            case type = "KCXZDM_DISPLAY"
            case category = "KCLBDM_DISPLAY"
            case department = "KKDWDM_DISPLAY"
        }

        let term: String?
        let name: String?
        let teacher: String?
        let classroom: String?
        let scheduleDescription: String?
        let rawWeeks: String?
        let weekday: Int?
        let startSection: Int?
        let endSection: Int?
        let campus: String?
        let courseNumber: String?
        let credit: Int?
        let hour: Int?
        let type: String?
        let category: String?
        let department: String?
    }

    let datas: Datas
}

/// 考试安排接口响应体。
struct ExamResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [ExamRow]
        }

        let cxxsksap: Rows
    }

    struct ExamRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case location = "JASMC"
            case timeDescription = "KSSJMS"
            case dateString = "KSRQ"
            case seatID = "ZWH"
            case examMode = "KSMC"
            case termCode = "XNXQDM_DISPLAY"
            case courseName = "KCM"
            case teacherName = "ZJJSXM"
            case courseID = "KCH"
        }

        let location: String?
        let timeDescription: String
        let dateString: String?
        let seatID: String?
        let examMode: String?
        let termCode: String?
        let courseName: String?
        let teacherName: String?
        let courseID: String?
    }

    let datas: Datas
}

/// 周起始日期接口响应体。
struct WeekDateResponse: Decodable {
    struct WeekDateRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case week = "XQ"
            case date = "RQ"
        }

        let week: Int
        let date: String
    }

    let data: [WeekDateRow]
}

/// 校区列表接口响应体。
struct CampusListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [CampusRow]
        }

        let ggzdpx: Rows
    }

    struct CampusRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case displayName = "MC"
            case code = "DM"
        }

        let displayName: String
        let code: String
    }

    let datas: Datas
}

/// 教学楼列表接口响应体。
struct BuildingListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [BuildingRow]
        }

        let cxjxl: Rows
    }

    struct BuildingRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case buildingName = "JXLMC"
            case buildingCode = "JXLDM"
            case campusName = "XXXQDM_DISPLAY"
            case campusCode = "XXXQDM"
        }

        let buildingName: String
        let buildingCode: String
        let campusName: String
        let campusCode: String
    }

    let datas: Datas
}

/// 空教室接口响应体。
struct ClassroomListResponse: Decodable {
    struct Datas: Decodable {
        struct Rows: Decodable {
            let rows: [ClassroomRow]
        }

        let cxkxjasqk: Rows
    }

    struct ClassroomRow: Decodable {
        enum CodingKeys: String, CodingKey {
            case classroomName = "JASMC"
            case busyTimeString = "ZYJC"
        }

        let classroomName: String
        let busyTimeString: String?
    }

    let datas: Datas
}
