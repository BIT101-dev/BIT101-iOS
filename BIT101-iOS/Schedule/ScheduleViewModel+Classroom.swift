//
//  ScheduleViewModel+Classroom.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 进入空教室页前的统一预热入口。
    ///
    /// 这里会做三件事：
    /// 1. 按当前时间块重设节次筛选。
    /// 2. 加载校区/教学楼元数据。
    /// 3. 必要时刷新当前楼栋的空教室结果。
    func prepareClassroomIfNeeded(showErrors: Bool = true) async {
        guard classroomCoordinator.claimAutomaticPreparation() else { return }

        applyCurrentClassroomSectionBlock()
        let hasCachedMeta = applyCachedClassroomMetaIfAvailable()
        if hasCachedMeta {
            refreshClassroomMetaInBackgroundIfNeeded()
        }

        let requestID = beginClassroomRequest(clearsLoadingState: false)
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        do {
            if campuses.isEmpty || buildings.isEmpty {
                try await loadClassroomMeta(requestID: requestID)
            }

            guard isCurrentClassroomRequest(requestID) else { return }

            if selectedBuildingID.isEmpty {
                selectedBuildingID = cache.selectedBuildingID
            }

            if classroomRecords.isEmpty, !selectedBuildingID.isEmpty {
                try await refreshClassrooms(requestID: requestID)
            }
        } catch {
            if showErrors {
                handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
            } else {
                finishClassroomRequestIfCurrent(requestID)
            }
        }
    }

    /// 切换空教室查询校区。
    func selectCampus(code: String) async {
        guard code != cache.selectedCampusCode else { return }

        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        cache.selectedCampusCode = code
        cache.selectedCampusName = campuses.first(where: { $0.code == code })?.name ?? ""
        selectedBuildingID = ""
        cache.selectedBuildingID = ""
        buildings = cache.cachedClassroomBuildingsByCampusCode[code] ?? []
        if !buildings.isEmpty {
            resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: true)
        }
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        do {
            try await loadBuildings(requestID: requestID)
            guard isCurrentClassroomRequest(requestID) else { return }
            if !selectedBuildingID.isEmpty {
                try await refreshClassrooms(requestID: requestID)
            }
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 切换当前教学楼并刷新空教室结果。
    func selectBuilding(id: String) async {
        guard id != selectedBuildingID else { return }

        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        selectedBuildingID = id
        cache.selectedBuildingID = id
        isLoadingClassrooms = true
        classroomRecords = []
        classroomAvailabilities = []
        persist()

        do {
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 更新空教室节次筛选结果。
    func setSelectedClassroomSectionIDs(_ values: [Int]) {
        cache.selectedClassroomSectionIDs = ClassroomAvailabilityCalculator.normalizedSections(values, in: cache.timeTable)
        persist()
        refreshClassroomAvailabilities()
    }

    /// 刷新当前教学楼的空教室状态。
    ///
    /// 如果当前学期编码还未知，会先补查学期，再请求教室占用。
    func refreshClassrooms() async {
        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }
        do {
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 当前教学楼的空教室状态刷新实现。
    ///
    /// 所有公开入口都会先分配 `requestID`，旧请求返回时不允许再回写 loading、结果或错误弹窗。
    private func refreshClassrooms(requestID: Int) async throws {
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        if cache.currentTerm.isEmpty {
            let term = try await withClassroomRequestTimeout { [self] in
                try await service.fetchCurrentTermOnly()
            }
            guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }
            cache.currentTerm = term
            persist()
        }

        guard isCurrentClassroomRequest(requestID), !selectedBuildingID.isEmpty else { return }

        isLoadingClassrooms = true
        defer {
            if isCurrentClassroomRequest(requestID) {
                isLoadingClassrooms = false
            }
        }

        let records = try await withClassroomRequestTimeout { [self] in
            try await service.fetchClassrooms(buildingID: selectedBuildingID, term: cache.currentTerm)
        }
        guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }

        classroomRecords = records
        refreshClassroomAvailabilities()
    }

    /// 供页面下拉刷新使用的统一入口。
    ///
    /// 会先补齐校区/教学楼元数据，再刷新当前楼栋的空教室数据。
    func refreshClassroomPage() async {
        let requestID = beginClassroomRequest()
        defer {
            finishClassroomRequestIfCurrent(requestID)
        }

        do {
            if campuses.isEmpty || buildings.isEmpty {
                try await loadClassroomMeta(requestID: requestID)
            }

            guard isCurrentClassroomRequest(requestID), !selectedBuildingID.isEmpty else { return }
            try await refreshClassrooms(requestID: requestID)
        } catch {
            handleClassroomRequestError(error, requestID: requestID, title: "空教室同步失败")
        }
    }

    /// 加载空教室所需的校区和教学楼元数据。
    private func loadClassroomMeta(requestID: Int) async throws {
        isLoadingClassroomMeta = true
        defer {
            if isCurrentClassroomRequest(requestID) {
                isLoadingClassroomMeta = false
            }
        }

        try await loadBuildings(requestID: requestID)

        if campuses.isEmpty {
            refreshClassroomMetaInBackgroundIfNeeded()
        }
    }

    /// 根据当前校区加载教学楼，并优先精确匹配“最近下一节课”的楼宇。
    private func loadBuildings(requestID: Int) async throws {
        let fetchedBuildings = try await withClassroomRequestTimeout { [self] in
            try await service.fetchBuildings(campusCode: cache.selectedCampusCode.isEmpty ? nil : cache.selectedCampusCode)
        }
        guard isCurrentClassroomRequest(requestID) else { throw CancellationError() }

        applyFetchedBuildingsForCurrentSelection(fetchedBuildings, allowsPreferredCampus: true, allowsPreferredBuilding: true)
    }

    /// 优先用上次成功获取的校区 / 教学楼元数据恢复选择器，避免进入页面时阻塞等待元数据接口。
    @discardableResult
    private func applyCachedClassroomMetaIfAvailable() -> Bool {
        guard !cache.cachedClassroomCampuses.isEmpty else { return false }

        campuses = cache.cachedClassroomCampuses
        resolveSelectedCampusIfNeeded(allowsPreferredCampus: true)

        let cachedBuildings = cache.cachedClassroomBuildingsByCampusCode[cache.selectedCampusCode] ?? []
        guard !cachedBuildings.isEmpty else {
            buildings = []
            selectedBuildingID = ""
            cache.selectedBuildingID = ""
            persist()
            return true
        }

        buildings = cachedBuildings
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: true)
        return true
    }

    /// 有缓存时后台静默刷新低频变化的元数据；成功后更新缓存，失败不打扰用户。
    private func refreshClassroomMetaInBackgroundIfNeeded() {
        guard let token = classroomCoordinator.beginMetadataRefresh() else { return }

        Task { [weak self] in
            await self?.refreshClassroomMetaSilently(token: token)
        }
    }

    /// 后台刷新校区 / 教学楼元数据。
    ///
    /// 这条链路不参与空教室结果请求代号，也不弹错误；目的只是让下一次打开页面更快、更准。
    private func refreshClassroomMetaSilently(token: Int) async {
        defer {
            classroomCoordinator.finishMetadataRefresh(token)
        }

        do {
            let fetchedCampuses = try await withClassroomRequestTimeout { [self] in
                try await service.fetchCampuses()
            }
            guard classroomCoordinator.isCurrentMetadataRefresh(token) else { return }
            applyFetchedCampuses(fetchedCampuses, allowsPreferredCampus: false)

            guard !cache.selectedCampusCode.isEmpty else { return }

            let fetchedBuildings = try await withClassroomRequestTimeout { [self] in
                try await service.fetchBuildings(campusCode: cache.selectedCampusCode)
            }
            guard classroomCoordinator.isCurrentMetadataRefresh(token) else { return }
            applyFetchedBuildings(fetchedBuildings, for: cache.selectedCampusCode, allowsPreferredBuilding: false)
        } catch {
            return
        }
    }

    /// 写入新的校区元数据，并保持当前选择尽量稳定。
    private func applyFetchedCampuses(_ fetchedCampuses: [CampusRecord], allowsPreferredCampus: Bool) {
        guard !fetchedCampuses.isEmpty else { return }

        campuses = fetchedCampuses
        cache.cachedClassroomCampuses = fetchedCampuses
        resolveSelectedCampusIfNeeded(allowsPreferredCampus: allowsPreferredCampus)
        persist()
    }

    /// 写入教学楼元数据，并在未缓存校区列表时从教学楼字段反推出校区，避免首屏额外等待校区接口。
    private func applyFetchedBuildingsForCurrentSelection(
        _ fetchedBuildings: [BuildingRecord],
        allowsPreferredCampus: Bool,
        allowsPreferredBuilding: Bool
    ) {
        guard !fetchedBuildings.isEmpty else {
            applyFetchedBuildings([], for: cache.selectedCampusCode, allowsPreferredBuilding: allowsPreferredBuilding)
            return
        }

        let grouped = Dictionary(grouping: fetchedBuildings, by: \.campusCode)
        for (campusCode, campusBuildings) in grouped where !campusCode.isEmpty {
            cache.cachedClassroomBuildingsByCampusCode[campusCode] = campusBuildings
        }

        if campuses.isEmpty {
            let generatedCampuses = grouped.compactMap { campusCode, campusBuildings -> CampusRecord? in
                guard !campusCode.isEmpty else { return nil }
                let campusName = campusBuildings.first?.campusName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return CampusRecord(id: campusCode, name: campusName.isEmpty ? campusCode : campusName, code: campusCode)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            if !generatedCampuses.isEmpty {
                campuses = generatedCampuses
                cache.cachedClassroomCampuses = generatedCampuses
            }
        }

        resolveSelectedCampusIfNeeded(allowsPreferredCampus: allowsPreferredCampus)

        let selectedCampusBuildings: [BuildingRecord]
        if !cache.selectedCampusCode.isEmpty, let campusBuildings = grouped[cache.selectedCampusCode] {
            selectedCampusBuildings = campusBuildings
        } else {
            selectedCampusBuildings = fetchedBuildings
        }

        buildings = selectedCampusBuildings
        if !cache.selectedCampusCode.isEmpty {
            cache.cachedClassroomBuildingsByCampusCode[cache.selectedCampusCode] = selectedCampusBuildings
        }
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: allowsPreferredBuilding)
        persist()
    }

    /// 写入某个校区下的教学楼元数据，并保持当前选择尽量稳定。
    private func applyFetchedBuildings(
        _ fetchedBuildings: [BuildingRecord],
        for campusCode: String,
        allowsPreferredBuilding: Bool
    ) {
        buildings = fetchedBuildings
        cache.cachedClassroomBuildingsByCampusCode[campusCode] = fetchedBuildings
        resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: allowsPreferredBuilding)
        persist()
    }

    /// 在校区列表变化后修正选中校区。
    private func resolveSelectedCampusIfNeeded(allowsPreferredCampus: Bool) {
        let validCampusCodes = Set(campuses.map(\.code))

        if validCampusCodes.contains(cache.selectedCampusCode) {
            cache.selectedCampusName = campuses.first(where: { $0.code == cache.selectedCampusCode })?.name ?? cache.selectedCampusName
            return
        }

        if allowsPreferredCampus, let preferredCampus = preferredCampus(from: campuses) {
            cache.selectedCampusCode = preferredCampus.code
            cache.selectedCampusName = preferredCampus.name
            return
        }

        cache.selectedCampusCode = campuses.first?.code ?? ""
        cache.selectedCampusName = campuses.first?.name ?? ""
    }

    /// 在教学楼列表变化后修正选中教学楼。
    private func resolveSelectedBuildingIfNeeded(allowsPreferredBuilding: Bool) {
        let validBuildingIDs = Set(buildings.map(\.buildingCode))
        let cachedBuildingID = cache.selectedBuildingID

        if validBuildingIDs.contains(selectedBuildingID) {
            cache.selectedBuildingID = selectedBuildingID
            return
        }

        if validBuildingIDs.contains(cachedBuildingID) {
            selectedBuildingID = cachedBuildingID
            return
        }

        if allowsPreferredBuilding, let preferredBuildingID = preferredBuildingID(from: buildings), validBuildingIDs.contains(preferredBuildingID) {
            selectedBuildingID = preferredBuildingID
            cache.selectedBuildingID = selectedBuildingID
            return
        }

        selectedBuildingID = buildings.first?.buildingCode ?? ""
        cache.selectedBuildingID = selectedBuildingID
    }

    /// 按当前节次筛选把原始占用记录转换为展示模型。
    private func refreshClassroomAvailabilities() {
        classroomAvailabilities = ClassroomAvailabilityCalculator.availabilities(
            records: classroomRecords,
            timeTable: cache.timeTable,
            selectedSections: cache.selectedClassroomSectionIDs,
            nowMinutes: currentMinutes()
        )
    }

    /// 节次筛选摘要文本。
    var classroomSectionFilterSummary: String {
        let selected = ClassroomAvailabilityCalculator.normalizedSections(
            cache.selectedClassroomSectionIDs,
            in: cache.timeTable
        )
        return selected.isEmpty ? "当前空闲" : ClassroomAvailabilityCalculator.sectionsText(selected)
    }

    /// 当前是否处于“当前空闲”模式。
    var isCurrentFreeClassroomMode: Bool {
        ClassroomAvailabilityCalculator.normalizedSections(
            cache.selectedClassroomSectionIDs,
            in: cache.timeTable
        ).isEmpty
    }

    /// 计算某间教室与当前筛选节次的命中摘要。
    func classroomMatchedSectionsText(for availability: ClassroomAvailability) -> String {
        ClassroomAvailabilityCalculator.matchedSectionsText(
            freeSections: availability.freeSections,
            selectedSections: cache.selectedClassroomSectionIDs,
            timeTable: cache.timeTable
        )
    }

    /// 根据首周日期推导当前周次。
    private func resolvedCurrentWeek() -> Int {
        guard let firstDay = cache.firstDay else {
            return 1
        }

        let start = Calendar.current.startOfDay(for: firstDay)
        let today = Calendar.current.startOfDay(for: Date())
        let diff = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return ScheduleWeekCodec.weekNumber(forDayOffset: diff)
    }

    /// 计算今天所在周后，仅对自动定位结果做边界保护；手动翻页仍可继续向前或向后浏览。
    func resolvedAutomaticWeek() -> Int {
        ScheduleAutomaticWeekPolicy.clamped(resolvedCurrentWeek())
    }

    /// 当前时间在一天中的分钟偏移。
    private func currentMinutes() -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 统一兼容任务取消错误。
    func isCancellation(_ error: Error) -> Bool {
        TaskCancellation.matches(error)
    }

    /// 开始一轮新的空教室请求，并让所有旧请求失去 UI 回写资格。
    private func beginClassroomRequest(clearsLoadingState: Bool = true) -> Int {
        let request = classroomCoordinator.beginRequest(hasVisibleResults: !classroomAvailabilities.isEmpty)
        shouldShowInitialClassroomSpinner = request.shouldShowInitialSpinner
        if clearsLoadingState {
            isLoadingClassroomMeta = false
            isLoadingClassrooms = false
        }
        return request.id
    }

    /// 判断指定空教室请求是否仍然是当前最新请求。
    private func isCurrentClassroomRequest(_ requestID: Int) -> Bool {
        classroomCoordinator.isCurrent(requestID)
    }

    /// 统一处理空教室链路错误。
    ///
    /// 只有当前最新请求可以关闭 loading 和弹窗；旧请求失败会被静默丢弃。
    private func handleClassroomRequestError(_ error: Error, requestID: Int, title: String) {
        guard isCurrentClassroomRequest(requestID) else { return }

        if isCancellation(error) {
            classroomCoordinator.finish(requestID)
            shouldShowInitialClassroomSpinner = false
            return
        }

        classroomCoordinator.finish(requestID)
        shouldShowInitialClassroomSpinner = false
        isLoadingClassroomMeta = false
        isLoadingClassrooms = false
        notice = ScheduleNotice(title: title, message: error.localizedDescription)
    }

    /// 标记当前空教室请求已正常结束。
    private func finishClassroomRequestIfCurrent(_ requestID: Int) {
        guard isCurrentClassroomRequest(requestID) else { return }
        classroomCoordinator.finish(requestID)
        shouldShowInitialClassroomSpinner = false
    }

    /// 给单个空教室网络请求加超时，避免学校接口长期挂起。
    private func withClassroomRequestTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await classroomCoordinator.withTimeout(operation: operation)
    }

    /// 从磁盘重新加载缓存，并同步周次与当前教学楼。
    func reloadFromDisk() {
        let previousScheduleIndex = selectedCourseScheduleIndex
        let previousWeek = selectedWeek
        cache = ScheduleCacheStore.load()
        selectedCourseScheduleIndex = min(max(previousScheduleIndex, 0), max(courseSchedules.count - 1, 0))
        // 本地编辑会通过 scheduleCacheDidChange 回到这里。只更新数据，
        // 不把用户正在查看的历史/未来周强制跳回当前周。
        selectedWeek = previousWeek
        selectedBuildingID = cache.selectedBuildingID
    }

    /// 写回缓存。
    func persist(source: ScheduleCacheStore.SaveSource = .local) {
        ScheduleCacheStore.save(cache, source: source)
    }

    /// 从“最近下一节课”的教室名推导最匹配的教学楼。
    ///
    /// 规则是：永远先做精确匹配，精确失败后才退回前缀匹配，再不行才回退缓存。
    private func preferredBuildingID(from buildings: [BuildingRecord]) -> String? {
        guard let course = nextUpcomingCourse() else { return nil }
        let candidates = ClassroomAvailabilityCalculator.buildingCandidates(from: course.classroom)
        guard !candidates.isEmpty else { return nil }

        let normalizedBuildings = buildings.map { ($0, ClassroomAvailabilityCalculator.normalizedBuildingName($0.name)) }

        if let exact = normalizedBuildings.first(where: { pair in
            candidates.contains(pair.1)
        }) {
            return exact.0.buildingCode
        }

        return normalizedBuildings.first { pair in
            let buildingName = pair.1
            guard !buildingName.isEmpty else { return false }
            return candidates.contains { candidate in
                candidate.hasPrefix(buildingName) || buildingName.hasPrefix(candidate)
            }
        }?.0.buildingCode
    }

    /// 从“最近下一节课”的校区信息推导默认校区。
    private func preferredCampus(from campuses: [CampusRecord]) -> CampusRecord? {
        guard let course = nextUpcomingCourse() else { return nil }
        let normalizedCampus = ClassroomAvailabilityCalculator.normalizedBuildingName(course.campus)
        guard !normalizedCampus.isEmpty else { return nil }

        return campuses.first { campus in
            let campusName = ClassroomAvailabilityCalculator.normalizedBuildingName(campus.name)
            let campusCode = ClassroomAvailabilityCalculator.normalizedBuildingName(campus.code)
            return normalizedCampus.contains(campusName) || campusName.contains(normalizedCampus) || normalizedCampus == campusCode
        }
    }

    /// 找出当前时间之后最近开始的一节正式课程。
    private func nextUpcomingCourse() -> CourseRecord? {
        guard let firstDay = cache.firstDay else { return nil }
        let slotMap = Dictionary(uniqueKeysWithValues: cache.timeTable.map { ($0.id, $0) })
        let now = Date()

        return cache.courses
            .compactMap { course -> (CourseRecord, Date)? in
                let nextStart = course.weeks.compactMap { week -> Date? in
                    guard
                        let slot = slotMap[course.startSection],
                        let startDate = combineCourseDate(
                            firstDay: firstDay,
                            week: week,
                            weekday: course.weekday,
                            time: slot.start
                        )
                    else {
                        return nil
                    }
                    return startDate >= now ? startDate : nil
                }.min()

                guard let nextStart else { return nil }
                return (course, nextStart)
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    /// 把课程的教学周/星期/节次时间拼成真实日期时间。
    private func combineCourseDate(firstDay: Date, week: Int, weekday: Int, time: String) -> Date? {
        let dayOffset = ScheduleWeekCodec.weekOffset(forWeekNumber: week) * 7 + (weekday - 1)
        guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: firstDay) else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    /// 按当前时间自动切换到对应的节次块筛选。
    ///
    /// 不是首次才做，而是每次进入空教室页都会重新计算。
    private func applyCurrentClassroomSectionBlock() {
        let sectionIDs = ClassroomAvailabilityCalculator.sectionBlock(at: currentMinutes(), in: cache.timeTable)
        guard !sectionIDs.isEmpty else { return }

        let normalized = ClassroomAvailabilityCalculator.normalizedSections(sectionIDs, in: cache.timeTable)
        guard cache.selectedClassroomSectionIDs != normalized else { return }
        cache.selectedClassroomSectionIDs = normalized
        persist()
        if !classroomRecords.isEmpty {
            refreshClassroomAvailabilities()
        }
    }
}
