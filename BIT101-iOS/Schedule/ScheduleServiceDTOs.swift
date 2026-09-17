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
            let extParams: ExtParams?
        }

        struct ExtParams: Decodable {
            let code: Int?
            let msg: String?
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
            case displayWeeks = "ZCMC"
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
        let displayWeeks: String?
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

extension CourseResponse {
    struct ParsedCourse {
        let course: CourseRecord
        let rawWeeks: [Int]
    }

    /// 将课表接口的每一行转换成独立课程记录。
    ///
    /// `ZCMC` 是学校为当前行返回的周次字段。`YPSJDD` 汇总了同一课程的全部安排，
    /// 作为描述文本保存，当前行周次沿用 `ZCMC`。
    var parsedCourses: [ParsedCourse] {
        datas.cxxszhxqkb.rows.map { row in
            let rawWeeks = (row.rawWeeks ?? "").enumerated().compactMap { index, flag in
                flag == "1" ? index + 1 : nil
            }
            let displayWeeks = SmallTermWeekNormalizer.weeksDescribed(in: row.displayWeeks ?? "")
            let weeks = displayWeeks.isEmpty ? rawWeeks : displayWeeks.sorted()
            let scheduleIdentity = [
                row.term ?? "",
                row.courseNumber ?? "",
                String(row.weekday ?? 0),
                String(row.startSection ?? 0),
                String(row.endSection ?? 0),
                row.classroom ?? "",
                weeks.map(String.init).joined(separator: ",")
            ].joined(separator: "-")

            let course = CourseRecord(
                id: scheduleIdentity,
                term: row.term ?? "",
                name: row.name ?? "",
                teacher: row.teacher ?? "",
                classroom: row.classroom ?? "",
                description: row.scheduleDescription ?? "",
                weeks: weeks,
                weekday: row.weekday ?? 0,
                startSection: row.startSection ?? 0,
                endSection: row.endSection ?? 0,
                campus: row.campus ?? "",
                number: row.courseNumber ?? "",
                credit: row.credit ?? 0,
                hour: row.hour ?? 0,
                type: row.type ?? "",
                category: row.category ?? "",
                department: row.department ?? ""
            )
            return ParsedCourse(course: course, rawWeeks: rawWeeks)
        }
    }

    var courseRecords: [CourseRecord] {
        parsedCourses.map(\.course)
    }
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
        let campusName: String?
        let campusCode: String?
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
