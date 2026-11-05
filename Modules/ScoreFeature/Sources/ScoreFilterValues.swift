import DesignSystemKit
import Foundation
import ScoreDomain

extension ScoreViewModel {
    /// 提取筛选项并保留原始出现顺序，缺失字段归入“未分类”。
    func uniqueFilterValues(from source: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for item in source {
            let trimmed = normalizedFilterValue(item)
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            values.append(trimmed)
        }
        return values
    }

    /// 课程号和名称比较时忽略空白及大小写差异。
    func normalizedCourseIdentity(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    func normalizedFilterValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }

    func updateFilterOptions() {
        availableTerms = uniqueFilterValues(
            from: rows.map(\.term) + Array(cachedCoursesByTerm.keys).sorted())
        availableCourseTypes = uniqueFilterValues(
            from: rows.map(\.courseType)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// 刷新可选项后，同步修正当前筛选集合。
    ///
    /// 首次进入时恢复本地偏好；后续刷新时把当前筛选限制在现有选项范围内。
    func synchronizeFilters(previousTerms: Set<String>, previousTypes: Set<String>) {
        let originalTerms = selectedTerms
        let previousCourseTypes = selectedCourseTypes
        let termSet = Set(availableTerms)
        let typeSet = Set(availableCourseTypes)

        if !didInitializeTermSelection, !termSet.isEmpty {
            if let persistedTerms = preferenceSnapshot?.selectedTerms {
                selectedTerms = restoredFilterSelection(persistedTerms, options: termSet)
            } else {
                selectedTerms = termSet
            }
            didInitializeTermSelection = true
        } else if didInitializeTermSelection, !termSet.isEmpty {
            selectedTerms =
                !previousTerms.isEmpty && selectedTerms == previousTerms
                ? termSet : selectedTerms.intersection(termSet)
        }

        if !didInitializeCourseTypeSelection, !typeSet.isEmpty {
            if let persistedCourseTypes = preferenceSnapshot?.selectedCourseTypes {
                selectedCourseTypes = restoredFilterSelection(
                    persistedCourseTypes, options: typeSet)
            } else {
                selectedCourseTypes = typeSet
            }
            didInitializeCourseTypeSelection = true
        } else if didInitializeCourseTypeSelection, !typeSet.isEmpty {
            selectedCourseTypes =
                !previousTypes.isEmpty && selectedCourseTypes == previousTypes
                ? typeSet : selectedCourseTypes.intersection(typeSet)
        }

        if originalTerms != selectedTerms || previousCourseTypes != selectedCourseTypes {
            persistFilterPreferences()
        }
    }

    /// iCloud 拉取完成后立即更新已存在的成绩页面。
    func applyStoredFilters() {
        preferenceSnapshot = preferenceStore.load()
        updateFilterRecovery()
        guard let preferenceSnapshot else { return }

        restoreSortPreferences()
        if didInitializeTermSelection {
            selectedTerms = restoredFilterSelection(
                preferenceSnapshot.selectedTerms, options: Set(availableTerms))
        }
        if didInitializeCourseTypeSelection {
            selectedCourseTypes = restoredFilterSelection(
                preferenceSnapshot.selectedCourseTypes, options: Set(availableCourseTypes))
        }
        pendingCourses = calculatePendingCourses()
    }

    func matchesSelectedCourseType(_ value: String) -> Bool {
        availableCourseTypes.isEmpty || selectedCourseTypes.count == availableCourseTypes.count
            || selectedCourseTypes.contains(normalizedFilterValue(value))
    }

    func restoredFilterSelection(_ values: [String], options: Set<String>) -> Set<String> {
        let selection = Set(values).intersection(options)
        return selection.isEmpty && !values.isEmpty ? options : selection
    }

    func restoreSortPreferences() {
        sortIndex =
            preferenceSnapshot?.sortIndex.flatMap(ScoreSortIndex.init(rawValue:)) ?? .courseName
        sortOrder =
            preferenceSnapshot?.sortOrder.flatMap(ScoreSortOrder.init(rawValue:)) ?? .ascending
    }

    /// 保存当前筛选结果到本地偏好。
    func persistFilterPreferences() {
        guard !isSynchronizingScoreFields else { return }
        if preferenceStore.hasUnreadableSnapshot {
            needsStorageRecovery = true
            return
        }
        guard
            preferenceSnapshot != nil
                || (didInitializeTermSelection
                    && (didInitializeCourseTypeSelection || !rows.isEmpty))
        else { return }
        let saved = preferenceStore.save(
            selectedTerms: didInitializeTermSelection
                ? selectedTerms : Set(preferenceSnapshot?.selectedTerms ?? []),
            selectedCourseTypes: didInitializeCourseTypeSelection
                ? selectedCourseTypes : Set(preferenceSnapshot?.selectedCourseTypes ?? []),
            sortIndex: sortIndex,
            sortOrder: sortOrder
        )
        if !saved {
            needsStorageRecovery = true
            alert = AppAlert(
                title: "筛选偏好保存受阻", message: "当前筛选与排序在本次使用中生效。原始偏好数据已保留，可通过“恢复成绩存储”重建本账号的成绩与筛选。")
        }
    }

    func updateFilterRecovery() {
        if preferenceStore.hasUnreadableSnapshot {
            needsStorageRecovery = true
        }
    }
}
