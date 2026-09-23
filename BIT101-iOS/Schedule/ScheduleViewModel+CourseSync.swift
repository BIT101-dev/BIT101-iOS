//
//  ScheduleViewModel+CourseSync.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 同步课程表、考试安排和首周日期。
    ///
    /// 传入明确学期时先更新本地选择；后续请求失败时保留该选择。
    /// 同步成功后会立刻更新本地缓存，从而驱动课表页、小组件和灵动岛一起刷新。
    func syncCourses(term: String? = nil) async {
        guard !isSyncingCourses, !isLoadingTerms, !isSubmittingSMSCode,
              smsChallenge == nil
        else { return }
        let requestedTerm = term?.trimmingCharacters(in: .whitespacesAndNewlines)
        let syncTerm = requestedTerm?.isEmpty == true ? nil : requestedTerm
        let generation = accountGeneration
        if let syncTerm {
            selectTermForSync(syncTerm)
        }
        isSyncingCourses = true
        syncingTerm = syncTerm
        defer {
            if accountGeneration == generation {
                isSyncingCourses = false
                syncingTerm = nil
            }
        }

        do {
            let payload = try await service.syncCourses(term: syncTerm)
            guard accountGeneration == generation, !Task.isCancelled else { return }
            applyCourseSyncPayload(payload)
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            courseSyncCoordinator.waitForCourseAuthentication(term: syncTerm)
            smsChallenge = challenge
            smsVerificationError = nil
        } catch let error as ScheduleServiceError where error.isSchoolTransportFailure {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            courseSyncCoordinator.reset()
            notice = schoolFailureNotice(
                title: "学校服务连接失败",
                message: error.schoolTransportFailureMessage,
                networkFailure: true
            )
        } catch ScheduleServiceError.challengeInvalid(let message) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice.userInput(title: "验证已失效", message: message)
        } catch let error as ScheduleServiceError where error.isUnpublishedCourseSchedule {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            notice = ScheduleNotice.userInput(title: "课表暂未发布", message: error.localizedDescription)
        } catch {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            if isCancellation(error) { return }
            notice = schoolFailureNotice(
                title: "课表同步失败",
                message: error.localizedDescription,
                networkFailure: Self.isLikelySchoolTransportError(error)
            )
        }
    }

    /// 先保存用户选择的学期，再独立请求课表。
    ///
    /// 已有快照会立即切换到对应内容；没有快照时清空当前课表数据，当前学期页面从空课表开始。
    /// 后续请求失败时通过 `notice` 提示并保留学期选择。
    private func selectTermForSync(_ term: String) {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty, cache.currentTerm != normalizedTerm else { return }

        if let snapshot = cache.termSchedulesByTerm[normalizedTerm] {
            activate(snapshot)
        } else {
            cache.currentTerm = normalizedTerm
            cache.firstDayString = ""
            cache.coursesUpdatedAt = .distantPast
            cache.courses = []
            cache.exams = []
        }
        selectedWeek = resolvedAutomaticWeek()
        persist()
    }

    /// 重新获取当前正在显示的目标学期，首次同步使用学校的“当前学期”标记。
    ///
    /// 用户主动切到其它学期后，普通的“获取/重新同步”继续请求该学期；本地尚未保存
    /// 学期编码时传 `nil`，让学校返回当前学期。
    func syncSelectedTerm() async {
        let term = cache.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        await syncCourses(term: term.isEmpty ? nil : term)
    }

    /// 课表页面展示的最近一次成功同步时间。
    var coursesLastUpdatedText: String {
        guard cache.coursesUpdatedAt != .distantPast else { return "更新时间：暂无记录" }
        return "更新时间：\(cache.coursesUpdatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    /// 加载学校接口实际返回的学期列表，列表内容与接口结果保持一致。
    func loadAvailableTerms() async {
        guard !isLoadingTerms, !isSyncingCourses, smsChallenge == nil
        else { return }
        let generation = accountGeneration
        isLoadingTerms = true
        defer {
            if accountGeneration == generation {
                isLoadingTerms = false
            }
        }

        do {
            let terms = try await service.fetchAvailableTerms()
            guard accountGeneration == generation, !Task.isCancelled else { return }
            availableTerms = terms
            hasLoadedAvailableTerms = true
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            courseSyncCoordinator.waitForAvailableTermsAuthentication()
            smsChallenge = challenge
            smsVerificationError = nil
        } catch let error as ScheduleServiceError where error.isSchoolTransportFailure {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            courseSyncCoordinator.reset()
            notice = schoolFailureNotice(
                title: "学校服务连接失败",
                message: error.schoolTransportFailureMessage,
                networkFailure: true
            )
        } catch ScheduleServiceError.challengeInvalid(let message) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            courseSyncCoordinator.reset()
            notice = ScheduleNotice.userInput(title: "验证已失效", message: message)
        } catch {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            if isCancellation(error) { return }
            notice = schoolFailureNotice(
                title: "学期列表加载失败",
                message: error.localizedDescription,
                networkFailure: Self.isLikelySchoolTransportError(error)
            )
        }
    }

    /// 提交短信一次性验证码，并继续已暂停的教学中心认证、课表同步或学期列表加载。
    func submitSMSCode(_ code: String) async {
        guard let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalizedCode = code.filter(\.isNumber)
        guard (4 ... 8).contains(normalizedCode.count) else {
            smsVerificationError = "请输入短信中的 4 至 8 位验证码。"
            return
        }

        isSubmittingSMSCode = true
        smsVerificationError = nil
        let generation = accountGeneration
        defer {
            if accountGeneration == generation {
                isSubmittingSMSCode = false
            }
        }

        do {
            guard let continuation = courseSyncCoordinator.continuation else {
                smsChallenge = nil
                smsVerificationError = nil
                return
            }

            switch continuation {
            case .classroomRefresh, .availableTerms:
                try await service.submitSMSCodeForTeachingCenterAuthentication(
                    normalizedCode,
                    for: challenge
                )
                guard accountGeneration == generation, !Task.isCancelled else { return }
                smsChallenge = nil
                courseSyncCoordinator.reset()
                if continuation == .classroomRefresh {
                    await refreshClassroomPage()
                } else {
                    await loadAvailableTerms()
                }
            case let .courseSync(term):
                let payload = try await service.submitSMSCode(
                    normalizedCode,
                    for: challenge,
                    term: term
                )
                guard accountGeneration == generation, !Task.isCancelled else { return }
                applyCourseSyncPayload(payload)
                smsChallenge = nil
                courseSyncCoordinator.reset()
            }
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            smsChallenge = challenge
            smsVerificationError = "请输入最新收到的短信验证码。"
        } catch let error as ScheduleServiceError where error.isSchoolTransportFailure {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = schoolFailureNotice(
                title: "学校服务连接失败",
                message: error.schoolTransportFailureMessage,
                networkFailure: true
            )
        } catch ScheduleServiceError.challengeInvalid(let message) {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice.userInput(title: "验证已失效", message: message)
        } catch let error as ScheduleServiceError where error.isUnpublishedCourseSchedule {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            notice = ScheduleNotice.userInput(title: "课表暂未发布", message: error.localizedDescription)
        } catch {
            guard accountGeneration == generation, !Task.isCancelled else { return }
            if isCancellation(error) { return }
            smsVerificationError = error.localizedDescription
        }
    }

    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        courseSyncCoordinator.reset()
    }

    private func applyCourseSyncPayload(_ payload: CourseSyncPayload) {
        let incomingCourses = payload.courses
        let now = Date()
        let existingBaseline = cache.schoolCoursesByTerm[payload.term]
            ?? cache.termSchedulesByTerm[payload.term]?.courses
            ?? (cache.currentTerm == payload.term ? cache.courses : [])
        let rules = cache.manualCourseRulesByTerm[payload.term] ?? []
        let reconciliation = ScheduleCourseEditor.reconcile(
            rules: rules,
            with: incomingCourses
        )
        let coursesAreIdentical = scheduleCourseSourceRecordsEqual(existingBaseline, incomingCourses)

        cache.schoolCoursesByTerm[payload.term] = incomingCourses
        cache.manualCourseRulesByTerm[payload.term] = reconciliation.validRules
        let snapshot = makeTermSnapshot(from: payload, now: now)
        cache.termSchedulesByTerm[payload.term] = snapshot
        cache.cachedCoursesByTerm[payload.term] = reconciliation.courses

        if cache.currentTerm == payload.term {
            activate(snapshot)
            selectedWeek = resolvedAutomaticWeek()
        }
        trimTermSnapshots(preserving: Set([payload.term]))
        persist()

        if !reconciliation.invalidRules.isEmpty {
            let names = uniqueCourseNames(from: reconciliation.invalidRules)
            let courseText = names.isEmpty ? "相关课程" : names.joined(separator: "、")
            notice = ScheduleNotice.userInput(
                title: "手动调课已失效",
                message: "学校课表中的 \(courseText) 发生了变化，相关手动调课已移除，当前显示最新课程安排。"
            )
        } else if coursesAreIdentical {
            notice = ScheduleNotice.informational(
                title: "课表已是最新",
                message: "本次获取结果与学校原始课表完全一致。"
            )
        }
    }

    /// 记录一次成功的学校响应，即使课表内容与本地缓存完全一致。
    private func markCourseSyncSucceeded(term: String, at date: Date) {
        var didUpdate = false
        if cache.currentTerm == term {
            cache.coursesUpdatedAt = date
            didUpdate = true
        }
        if let snapshot = cache.termSchedulesByTerm[term] {
            cache.termSchedulesByTerm[term] = TermScheduleSnapshot(
                term: snapshot.term,
                firstDayString: snapshot.firstDayString,
                courses: snapshot.courses,
                exams: snapshot.exams,
                updatedAt: date
            )
            didUpdate = true
        }
        if didUpdate {
            persist()
        }
    }

    private func makeTermSnapshot(from payload: CourseSyncPayload, now: Date) -> TermScheduleSnapshot {
        TermScheduleSnapshot(
            term: payload.term,
            firstDayString: payload.firstDayString,
            courses: payload.courses,
            exams: payload.exams,
            updatedAt: now
        )
    }

    private func activate(_ snapshot: TermScheduleSnapshot) {
        cache.currentTerm = snapshot.term
        cache.firstDayString = snapshot.firstDayString
        cache.coursesUpdatedAt = snapshot.updatedAt
        let baseline = cache.schoolCoursesByTerm[snapshot.term] ?? snapshot.courses
        cache.schoolCoursesByTerm[snapshot.term] = baseline
        cache.courses = ScheduleCourseEditor.reconcile(
            rules: cache.manualCourseRulesByTerm[snapshot.term] ?? [],
            with: baseline
        ).courses
        cache.exams = snapshot.exams
        cache.cachedCoursesByTerm[snapshot.term] = cache.courses
    }

    /// 将学期快照数量限制为最多两个，并保留当前显示学期与显式同步的目标学期。
    private func trimTermSnapshots(preserving terms: Set<String>) {
        guard cache.termSchedulesByTerm.count > 2 else { return }
        let removable = cache.termSchedulesByTerm.values
            .filter { !terms.contains($0.term) && $0.term != cache.currentTerm }
            .sorted { $0.updatedAt < $1.updatedAt }
        for snapshot in removable where cache.termSchedulesByTerm.count > 2 {
            cache.termSchedulesByTerm.removeValue(forKey: snapshot.term)
            cache.schoolCoursesByTerm.removeValue(forKey: snapshot.term)
            cache.manualCourseRulesByTerm.removeValue(forKey: snapshot.term)
        }
    }

    private func uniqueCourseNames(from rules: [ScheduleCourseRule]) -> [String] {
        var names: [String] = []
        for rule in rules {
            for name in rule.sourceCourses.map(\.name) where !name.isEmpty {
                guard !names.contains(name) else { continue }
                names.append(name)
            }
        }
        return Array(names.prefix(3))
    }

}
