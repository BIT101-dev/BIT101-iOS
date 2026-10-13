import ScheduleDomain
import ScheduleContracts
import SchedulePorts
//
//  ScheduleServiceDTOs.swift
//  BIT101-iOS
//

import Foundation

/// 当前学期接口响应体。
nonisolated struct CurrentTermResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [TermRow]
        }

        let dqxnxq: Rows
    }

    nonisolated struct TermRow: Decodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case code = "DM"
        }

        let code: String
    }

    let datas: Datas
}

/// 可选学期列表接口响应体。
nonisolated struct TermsResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [TermRow]
        }

        let xnxqcx: Rows
    }

    nonisolated struct TermRow: Decodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case code = "DM"
        }

        let code: String
    }

    let datas: Datas
}

/// 课程表接口响应体。
nonisolated struct CourseResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [CourseRow]
            let extParams: ExtParams?
        }

        nonisolated struct ExtParams: Decodable, Sendable {
            let code: Int?
            let msg: String?
        }

        let cxxszhxqkb: Rows
    }

    nonisolated struct CourseRow: Decodable, Sendable {
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
        let credit: Double?
        let hour: Int?
        let type: String?
        let category: String?
        let department: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            term = try container.decodeIfPresent(String.self, forKey: .term)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            teacher = try container.decodeIfPresent(String.self, forKey: .teacher)
            classroom = try container.decodeIfPresent(String.self, forKey: .classroom)
            scheduleDescription = try container.decodeIfPresent(String.self, forKey: .scheduleDescription)
            rawWeeks = try container.decodeIfPresent(String.self, forKey: .rawWeeks)
            displayWeeks = try container.decodeIfPresent(String.self, forKey: .displayWeeks)
            weekday = try container.decodeIfPresent(Int.self, forKey: .weekday)
            startSection = try container.decodeIfPresent(Int.self, forKey: .startSection)
            endSection = try container.decodeIfPresent(Int.self, forKey: .endSection)
            campus = try container.decodeIfPresent(String.self, forKey: .campus)
            courseNumber = try container.decodeIfPresent(String.self, forKey: .courseNumber)
            credit = container.decodeFlexibleDoubleIfPresent(forKey: .credit)
            hour = try container.decodeIfPresent(Int.self, forKey: .hour)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            department = try container.decodeIfPresent(String.self, forKey: .department)
        }
    }

    let datas: Datas
}

private nonisolated extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
            return number
        }
        return nil
    }
}

nonisolated extension CourseResponse {
    nonisolated struct ParsedCourse: Sendable {
        let course: CourseRecord
        let rawWeeks: [Int]
        let sourceDisplayWeeks: String?
    }

    /// 将课表接口的每一行转换成独立课程记录。
    ///
    /// `ZCMC` 是学校为当前行返回的周次字段。`YPSJDD` 汇总了同一课程的全部安排，
    /// 作为描述文本保存，当前行周次沿用 `ZCMC`。
    var parsedCourses: [ParsedCourse] {
        datas.cxxszhxqkb.rows.map(Self.parseCourse)
    }

    func parsedCoursesCancellable() throws -> [ParsedCourse] {
        let rows = datas.cxxszhxqkb.rows
        var courses: [ParsedCourse] = []
        courses.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            courses.append(Self.parseCourse(row))
        }
        return courses
    }

    private static func parseCourse(_ row: CourseRow) -> ParsedCourse {
        let name = (row.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (row.courseNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWeeks = (row.rawWeeks ?? "").enumerated().compactMap { index, flag in
            flag == "1" ? index + 1 : nil
        }
        let displayWeeks = SmallTermWeekNormalizer.weeksDescribed(in: row.displayWeeks ?? "")
        let weeks = displayWeeks.isEmpty || (!rawWeeks.isEmpty && Set(rawWeeks).isSubset(of: displayWeeks))
            ? rawWeeks : displayWeeks.sorted()
        let scheduleIdentity = [
            row.term ?? "",
            number.isEmpty ? scheduleCourseIdentity(number: number, name: name, teacher: row.teacher ?? "") : number,
            String(row.weekday ?? 0),
            String(row.startSection ?? 0),
            String(row.endSection ?? 0),
            row.classroom ?? "",
            weeks.map(String.init).joined(separator: ",")
        ].joined(separator: "-")

        let course = CourseRecord(
            id: scheduleIdentity,
            term: row.term ?? "",
            name: name.isEmpty ? number : name,
            teacher: row.teacher ?? "",
            classroom: row.classroom ?? "",
            description: row.scheduleDescription ?? "",
            weeks: weeks,
            weekday: row.weekday ?? 0,
            startSection: row.startSection ?? 0,
            endSection: row.endSection ?? 0,
            campus: row.campus ?? "",
            number: number,
            credit: row.credit ?? 0,
            hour: row.hour ?? 0,
            type: row.type ?? "",
            category: row.category ?? "",
            department: row.department ?? ""
        )
        return ParsedCourse(course: course, rawWeeks: rawWeeks, sourceDisplayWeeks: row.displayWeeks)
    }

    var courseRecords: [CourseRecord] {
        parsedCourses.map(\.course)
    }
}

/// 考试安排接口响应体。
nonisolated struct ExamResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [ExamRow]
        }

        let cxxsksap: Rows
    }

    nonisolated struct ExamRow: Decodable, Sendable {
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
nonisolated struct WeekDateResponse: Decodable, Sendable {
    nonisolated struct WeekDateRow: Decodable, Sendable {
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
nonisolated struct CampusListResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [CampusRow]
        }

        let ggzdpx: Rows
    }

    nonisolated struct CampusRow: Decodable, Sendable {
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
nonisolated struct BuildingListResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [BuildingRow]
        }

        let cxjxl: Rows
    }

    nonisolated struct BuildingRow: Decodable, Sendable {
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
nonisolated struct ClassroomListResponse: Decodable, Sendable {
    nonisolated struct Datas: Decodable, Sendable {
        nonisolated struct Rows: Decodable, Sendable {
            let rows: [ClassroomRow]
        }

        let cxkxjasqk: Rows
    }

    nonisolated struct ClassroomRow: Decodable, Sendable {
        enum CodingKeys: String, CodingKey {
            case classroomName = "JASMC"
            case busyTimeString = "ZYJC"
        }

        let classroomName: String
        let busyTimeString: String?
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            classroomName = try container.decode(String.self, forKey: .classroomName)
            guard container.contains(.busyTimeString) else {
                throw DecodingError.keyNotFound(CodingKeys.busyTimeString,
                    .init(codingPath: decoder.codingPath, debugDescription: "教室占用字段需要存在。"))
            }
            busyTimeString = try container.decodeIfPresent(String.self, forKey: .busyTimeString)
        }
    }

    let datas: Datas
}

extension ClassroomListResponse {
    @concurrent
    func classroomRecords() async throws -> [ClassroomRecord] {
        let rows = datas.cxkxjasqk.rows
        try Task.checkCancellation()
        var classrooms: [ClassroomRecord] = []
        classrooms.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let value = row.busyTimeString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let busy: [Int] = try value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false).map { token in
                guard let section = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)),
                      section > 0, section <= ScheduleCourseConstraints.maximumSection
                else { throw ScheduleServiceError.invalidResponse }
                return section
            }
            let classroom = ClassroomRecord(id: row.classroomName, name: row.classroomName, busyTimeCodes: busy.sorted())
            guard classroom.hasValidOccupancy else { throw ScheduleServiceError.invalidResponse }
            classrooms.append(classroom)
        }
        try Task.checkCancellation()
        return classrooms
    }
}

extension CourseResponse {
    @concurrent
    func parsedCoursesInBackground() async throws -> [CourseResponse.ParsedCourse] {
        try Task.checkCancellation()
        let courses = try parsedCoursesCancellable()
        try Task.checkCancellation()
        return courses
    }
}

extension ExamResponse {
    @concurrent
    func examRecords() async throws -> [ExamRecord] {
        var exams: [ExamRecord] = []
        exams.reserveCapacity(datas.cxxsksap.rows.count)
        for (index, row) in datas.cxxsksap.rows.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let rawCourseName = row.courseName ?? ""
            let name = rawCourseName
                .split(separator: "]")
                .first?
                .split(separator: "[")
                .last
                .map(String.init) ?? rawCourseName

            let times = row.timeDescription.captureGroups(pattern: #"(\d{2}:\d{2})-(\d{2}:\d{2})"#)
            let beginTime = times.first ?? ""
            let endTime = times.dropFirst().first ?? ""
            let timeDescription = row.timeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard times.count == 2 || timeDescription.isEmpty || timeDescription == "待定"
            else { throw ScheduleServiceError.invalidResponse }
            let courseID = (row.courseID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let exam = ExamRecord(
                id: "\(row.termCode ?? "")-\(courseID.isEmpty ? name : courseID)-\(row.dateString ?? "")-\(row.timeDescription)",
                term: row.termCode ?? "",
                name: name,
                courseID: courseID,
                teacher: row.teacherName ?? "",
                classroom: row.location ?? "",
                dateString: (row.dateString ?? "").split(separator: " ").first.map(String.init) ?? (row.dateString ?? ""),
                beginTime: beginTime,
                endTime: endTime,
                examMode: row.examMode ?? "",
                seatID: row.seatID ?? ""
            )
            guard exam.hasValidPlacement else { throw ScheduleServiceError.invalidResponse }
            exams.append(exam)
        }
        try Task.checkCancellation()
        return exams
    }
}
