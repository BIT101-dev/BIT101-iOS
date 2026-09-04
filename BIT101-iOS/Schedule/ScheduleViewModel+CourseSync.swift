//
//  ScheduleViewModel+CourseSync.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 同步课程表、考试安排和首周日期。
    ///
    /// 传入明确学期时先更新本地选择；即使后续请求失败，也不回滚该选择。
    /// 同步成功后会立刻更新本地缓存，从而驱动课表页、小组件和灵动岛一起刷新。
    func syncCourses(term: String? = nil) async {
        guard !isSyncingCourses, !isLoadingTerms, !isSubmittingSMSCode, smsChallenge == nil else { return }
        if let term {
            selectTermForSync(term)
        }
        isSyncingCourses = true
        syncingTerm = term
        defer {
            isSyncingCourses = false
            syncingTerm = nil
        }

        do {
            let payload = try await service.syncCourses(term: term)
            applyCourseSyncPayload(payload)
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            courseSyncCoordinator.waitForCourseAuthentication(term: term)
            smsChallenge = challenge
            smsVerificationError = nil
        } catch ScheduleServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice(title: "验证已失效", message: message)
        } catch let error as ScheduleServiceError where error.isUnpublishedCourseSchedule {
            notice = ScheduleNotice(title: "课表暂未发布", message: error.localizedDescription)
        } catch {
            notice = ScheduleNotice(title: "课表同步失败", message: error.localizedDescription)
        }
    }

    /// 先落盘用户选择的学期，再独立请求课表。
    ///
    /// 已有快照会立即切换到对应内容；没有快照时只清空当前课表数据，避免把旧学期
    /// 的课程误显示在新学期下。后续请求失败只通过 `notice` 提示，不回滚学期选择。
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

    /// 重新获取当前正在显示的目标学期，而不是重新询问学校的“当前学期”标记。
    ///
    /// 用户主动切到其它学期后，普通的“获取/重新同步”必须留在该学期；只有尚未保存
    /// 任何学期编码的首次同步才传 `nil`，让学校返回当前学期。
    func syncSelectedTerm() async {
        let term = cache.currentTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        await syncCourses(term: term.isEmpty ? nil : term)
    }

    /// 课表页面展示的最近一次成功同步时间。
    var coursesLastUpdatedText: String {
        guard cache.coursesUpdatedAt != .distantPast else { return "更新时间：暂无记录" }
        return "更新时间：\(cache.coursesUpdatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    /// 加载学校接口实际返回的学期列表，不在本地补充、推算或保留接口未返回的学期。
    func loadAvailableTerms() async {
        guard !isLoadingTerms, !isSyncingCourses, smsChallenge == nil else { return }
        isLoadingTerms = true
        defer { isLoadingTerms = false }

        do {
            availableTerms = try await service.fetchAvailableTerms()
            hasLoadedAvailableTerms = true
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.secondFactorRequired(let challenge) {
            courseSyncCoordinator.waitForAvailableTermsAuthentication()
            smsChallenge = challenge
            smsVerificationError = nil
        } catch {
            hasLoadedAvailableTerms = true
            notice = ScheduleNotice(title: "学期列表加载失败", message: error.localizedDescription)
        }
    }

    /// 提交短信一次性验证码，并继续被暂停的课表同步。
    func submitSMSCode(_ code: String) async {
        guard let challenge = smsChallenge, !isSubmittingSMSCode else { return }
        let normalizedCode = code.filter(\.isNumber)
        guard (4 ... 8).contains(normalizedCode.count) else {
            smsVerificationError = "请输入短信中的 4 至 8 位验证码。"
            return
        }

        isSubmittingSMSCode = true
        smsVerificationError = nil
        defer { isSubmittingSMSCode = false }

        do {
            if courseSyncCoordinator.continuation == .classroomRefresh {
                try await service.submitSMSCodeForTeachingCenterAuthentication(
                    normalizedCode,
                    for: challenge
                )
                smsChallenge = nil
                courseSyncCoordinator.reset()
                await refreshClassroomPage()
                return
            }

            if courseSyncCoordinator.continuation == .availableTerms {
                try await service.submitSMSCodeForTeachingCenterAuthentication(
                    normalizedCode,
                    for: challenge
                )
                smsChallenge = nil
                courseSyncCoordinator.reset()
                await loadAvailableTerms()
                return
            }

            let payload = try await service.submitSMSCode(
                normalizedCode,
                for: challenge,
                term: courseSyncCoordinator.courseSyncTerm
            )
            applyCourseSyncPayload(payload)
            smsChallenge = nil
            courseSyncCoordinator.reset()
        } catch ScheduleServiceError.challengeInvalid(let message) {
            smsChallenge = nil
            smsVerificationError = nil
            courseSyncCoordinator.reset()
            notice = ScheduleNotice(title: "验证已失效", message: message)
        } catch let error as ScheduleServiceError where error.isUnpublishedCourseSchedule {
            notice = ScheduleNotice(title: "课表暂未发布", message: error.localizedDescription)
        } catch {
            smsVerificationError = error.localizedDescription
        }
    }

    func dismissSMSChallenge() {
        guard !isSubmittingSMSCode else { return }
        smsChallenge = nil
        smsVerificationError = nil
        courseSyncCoordinator.reset()
    }

    private func applyCourseSyncPayload(_ payload: CourseSyncPayload, forceReplaceReduced: Bool = false) {
        let incomingCourses = payload.courses
        let existingCourses = cache.termSchedulesByTerm[payload.term]?.courses
            ?? (cache.currentTerm == payload.term ? cache.courses : [])
        let now = Date()
        // 空响应或完全相同的响应不覆盖；已发布但课程数减少时先交给全局弹窗确认。
        switch CourseSyncReplacementPolicy.decision(existing: existingCourses, with: incomingCourses) {
        case .preserve:
            // 请求成功但课程内容未变化时也必须刷新“最近同步时间”。否则用户会误以为
            // 刷新按钮没有发出请求；只有空响应覆盖已有课程时继续保留原缓存内容。
            guard !incomingCourses.isEmpty || existingCourses.isEmpty else {
                markCourseSyncSucceeded(term: payload.term, at: now)
                return
            }
        case let .confirm(existingCount, incomingCount) where !forceReplaceReduced:
            pendingCourseReplacement = CourseSyncReplacementConfirmation(
                existingCount: existingCount,
                incomingCount: incomingCount,
                payload: payload
            )
            return
        case .replace, .confirm:
            break
        }

        let snapshot = makeTermSnapshot(from: payload, now: now)
        cache.termSchedulesByTerm[payload.term] = snapshot
        cache.cachedCoursesByTerm[payload.term] = payload.courses
        activate(snapshot)
        trimTermSnapshots(preserving: Set([payload.term]))
        selectedWeek = resolvedAutomaticWeek()
        persist()
    }

    /// 记录一次成功的学校响应，即使课表内容与本地缓存完全一致。
    private func markCourseSyncSucceeded(term: String, at date: Date) {
        guard cache.currentTerm == term else { return }
        cache.coursesUpdatedAt = date
        if let snapshot = cache.termSchedulesByTerm[term] {
            cache.termSchedulesByTerm[term] = TermScheduleSnapshot(
                term: snapshot.term,
                firstDayString: snapshot.firstDayString,
                courses: snapshot.courses,
                exams: snapshot.exams,
                updatedAt: date
            )
        }
        persist()
    }

    func resolvePendingCourseReplacement(replace: Bool) {
        guard let pending = pendingCourseReplacement else { return }
        pendingCourseReplacement = nil
        guard replace else { return }
        applyCourseSyncPayload(pending.payload, forceReplaceReduced: true)
    }

    private func makeTermSnapshot(from payload: CourseSyncPayload, now: Date = Date()) -> TermScheduleSnapshot {
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
        cache.courses = snapshot.courses
        cache.exams = snapshot.exams
    }

    /// Keep the rolling cache small while never discarding the currently visible
    /// semester during an explicit historical-term sync.
    private func trimTermSnapshots(preserving terms: Set<String>) {
        guard cache.termSchedulesByTerm.count > 2 else { return }
        let removable = cache.termSchedulesByTerm.values
            .filter { !terms.contains($0.term) && $0.term != cache.currentTerm }
            .sorted { $0.updatedAt < $1.updatedAt }
        for snapshot in removable where cache.termSchedulesByTerm.count > 2 {
            cache.termSchedulesByTerm.removeValue(forKey: snapshot.term)
        }
    }

    /// Switch from the previous term using only local data. A school-provided
    /// first-week date delays the March/September fallback boundary when needed.
    @discardableResult
    func activatePreferredCachedTermIfAvailable(on date: Date) -> Bool {
        let preferred = AcademicTermPolicy.preferredCachedTerm(cache: cache, on: date)
        guard preferred != cache.currentTerm,
              let snapshot = cache.termSchedulesByTerm[preferred],
              snapshot.hasDisplayableData
        else { return false }
        if let firstDay = snapshot.firstDay, date < firstDay { return false }
        activate(snapshot)
        selectedWeek = resolvedAutomaticWeek()
        return true
    }

}
