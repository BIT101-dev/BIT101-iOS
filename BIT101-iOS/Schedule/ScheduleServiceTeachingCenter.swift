//
//  ScheduleServiceTeachingCenter.swift
//  BIT101-iOS
//
//  Teaching-center session recovery and academic API endpoints.
//

import Foundation

extension ScheduleService {
    /// 查询空教室页可选校区列表。
    ///
    /// 这一步相当于空教室查询的元数据预热，不涉及具体教室占用。
    func fetchCampuses() async throws -> [CampusRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchCampusesDirect()
        }
    }

    /// 查询某个校区下的教学楼列表。
    ///
    /// 教学楼会在进入空教室页时结合“最近下一节课的楼宇”做自动匹配。
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchBuildingsDirect(campusCode: campusCode)
        }
    }

    /// 查询某个教学楼当天的教室占用情况。
    ///
    /// 空教室接口以“当天 + 教学楼”为粒度返回占用节次，后续再在 ViewModel 层按选中的时段块格式化。
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        try await withTeachingCenterSessionRetry {
            try await prepareJXZX()
            return try await fetchClassroomsDirect(buildingID: buildingID, term: term)
        }
    }

    /// 所有教学中心业务请求共用的会话入口。
    ///
    /// 首次请求前确保存在与当前账号绑定的 WebVPN Cookie；如果业务请求明确返回登录页、
    /// 401/403 或其他会话失效信号，只清理教学中心状态并重新走 bit-login。当前最多执行
    /// 两轮恢复（共三次业务尝试），之后直接向上抛出，避免无限认证循环。
    func withTeachingCenterSessionRetry<T>(
        operation: () async throws -> T
    ) async throws -> T {
        try await ensureTeachingCenterAuthentication()

        // 学校 WebVPN 偶尔会接受新 Cookie，却在紧接着的第一笔业务请求中仍返回登录页。
        // 全程自动恢复，最多做两轮重新认证；用户只在确实需要短信验证码时参与。
        for recoveryAttempt in 0 ... 2 {
            do {
                return try await operation()
            } catch ScheduleServiceError.teachingCenterSessionExpired {
                teachingCenterState.invalidate()
                guard recoveryAttempt < 2 else {
                    throw ScheduleServiceError.teachingCenterSessionExpired
                }
                if recoveryAttempt > 0 {
                    try await Task.sleep(for: .seconds(1))
                }
                try await ensureTeachingCenterAuthentication(force: true)
            } catch {
                if isCancellationError(error) {
                    throw error
                }
                throw error
            }
        }

        throw ScheduleServiceError.teachingCenterSessionExpired
    }

    /// 确保学校侧登录态仍然有效。
    ///
    /// 日程模块大量依赖学校接口，但登录状态检查本身只是前置探测，不应该成为课表 / DDL / 空教室
    /// 真实业务请求之前的额外失败弹窗来源。
    ///
    /// 因此这里仅在远端明确判断当前会话无效时阻断；网络抖动、学校登录页异常等“检查失败”
    /// 会静默放行，让后续业务请求给出更贴近场景的错误。
    func ensureSchoolSession() async throws {
        do {
            guard try await LoginService().checkLogin() != nil else {
                throw ScheduleServiceError.notLoggedIn
            }
        } catch let error as ScheduleServiceError {
            throw error
        } catch {
            return
        }
    }

    /// 直连学校接口获取校区列表。
    private func fetchCampusesDirect() async throws -> [CampusRecord] {
        let response: CampusListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do?dicCode=48682&SFSY=1&order=%2BDM"
        )

        return response.datas.ggzdpx.rows.map {
            CampusRecord(id: $0.code, name: $0.displayName, code: $0.code)
        }
    }

    /// 直连学校接口获取教学楼列表。
    private func fetchBuildingsDirect(campusCode: String?) async throws -> [BuildingRecord] {
        let query: String
        if let campusCode, !campusCode.isEmpty {
            query = "?XXXQDM=\(urlEncode(campusCode))"
        } else {
            query = ""
        }

        let response: BuildingListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do\(query)"
        )

        return response.datas.cxjxl.rows.map {
            BuildingRecord(
                id: $0.buildingCode,
                name: $0.buildingName,
                buildingCode: $0.buildingCode,
                campusName: $0.campusName,
                campusCode: $0.campusCode
            )
        }
    }

    /// 直连学校接口获取教室占用情况。
    private func fetchClassroomsDirect(buildingID: String, term: String) async throws -> [ClassroomRecord] {
        let termParts = term.split(separator: "-")
        let termID = termParts.last.map(String.init) ?? ""
        let termYearCode = termParts.dropLast().joined(separator: "-")
        let dateString = ScheduleDateCodec.formatDate(Date())

        let response: ClassroomListResponse = try await sendJSONRequest(
            path: "/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do",
            method: "POST",
            body: [
                ("XQDM", String(termID)),
                ("JXLDM", buildingID),
                ("RQ", dateString),
                ("XNXQDM", term),
                ("XNDM", String(termYearCode)),
            ]
        )

        return response.datas.cxkxjasqk.rows.map {
            ClassroomRecord(
                id: $0.classroomName,
                name: $0.classroomName,
                busyTimeCodes: $0.busyTimeString?
                    .split(separator: ",")
                    .compactMap { Int($0) }
                    .sorted() ?? []
            )
        }
    }

    /// 教务系统接口请求前的预热步骤。
    ///
    /// 学校教务接口存在“未预热直接请求会失败”的历史行为，因此这里保留一组轻量预热访问。
    func prepareJXZX() async throws {
        let studentID = storage.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !studentID.isEmpty else { throw ScheduleServiceError.notLoggedIn }
        guard !teachingCenterState.isPrepared(for: studentID) else { return }

        // 学校教务接口依赖若干预热请求，否则后续接口会直接返回未初始化状态。
        _ = try await sendStringRequest(path: "/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do")
        _ = try await sendStringRequest(path: "/jwapp/i18n.do?appName=wdkbby&EMAP_LANG=zh")
        teachingCenterState.markPrepared(for: studentID)
    }

    /// 获取学校标记的当前学期编码。
    func fetchCurrentTerm() async throws -> String {
        let response: CurrentTermResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do"
        )

        guard let term = response.datas.dqxnxq.rows.first?.code, !term.isEmpty else {
            throw ScheduleServiceError.invalidResponse
        }

        return term
    }

    /// 拉取指定目标学期的课程表。
    ///
    /// 这里会把学校接口里稀疏且命名古老的字段，统一规整成 iOS 端自己的 `CourseRecord`。
    func fetchCourses(term: String) async throws -> [CourseRecord] {
        let response: CourseResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do",
            method: "POST",
            body: [("XNXQDM", term)]
        )

        return response.datas.cxxszhxqkb.rows.map { row in
            let weeks = (row.rawWeeks ?? "").enumerated().compactMap { index, flag in
                flag == "1" ? index + 1 : nil
            }

            return CourseRecord(
                id: "\(row.term ?? "")-\(row.courseNumber ?? "")-\(row.weekday ?? 0)-\(row.startSection ?? 0)-\(row.endSection ?? 0)-\(row.classroom ?? "")",
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
        }
    }

    /// 拉取指定目标学期的考试安排。
    func fetchExams(term: String) async throws -> [ExamRecord] {
        let response: ExamResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do",
            method: "POST",
            body: [("XNXQDM", term), ("*order", "-KSRQ")]
        )

        return response.datas.cxxsksap.rows.map { row in
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

            return ExamRecord(
                id: "\(row.termCode ?? "")-\(row.courseID ?? "")-\(row.dateString ?? "")-\(row.timeDescription)",
                term: row.termCode ?? "",
                name: name,
                courseID: row.courseID ?? "",
                teacher: row.teacherName ?? "",
                classroom: row.location ?? "",
                dateString: (row.dateString ?? "").split(separator: " ").first.map(String.init) ?? (row.dateString ?? ""),
                beginTime: beginTime,
                endTime: endTime,
                examMode: row.examMode ?? "",
                seatID: row.seatID ?? ""
            )
        }
    }

    /// 获取指定目标学期的第一周起始日期。
    ///
    /// 课表当前周数、小组件时间线和灵动岛课程推导都依赖这个日期基准。
    func fetchFirstDayString(term: String) async throws -> String {
        let requestParam = #"{"XNXQDM":"\#(term)","ZC":"1"}"#
        let response: WeekDateResponse = try await sendJSONRequest(
            path: "/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do",
            method: "POST",
            body: [("requestParamStr", requestParam)]
        )

        guard let firstDay = response.data.first(where: { $0.week == 1 })?.date else {
            throw ScheduleServiceError.invalidResponse
        }

        return firstDay
    }
}
