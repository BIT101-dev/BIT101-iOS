import SchedulePorts
import ClientCore
import TransportCore
import ScheduleDomain
//
//  ScheduleDDLViewModel.swift
//  BIT101-iOS
//

import Combine
import Foundation

@MainActor
public final class ScheduleDDLViewModel: ObservableObject, ScheduleStateConsumer {
    private(set) var cache: ScheduleDDLState {
        get { repository.ddlState }
        set { repository.ddlState = newValue }
    }

    let beforeSchoolRequest: @MainActor () async -> Void
    let virtualNetworkLikely: @MainActor () -> Bool
    let repository: ScheduleRepository
    private let service: any ScheduleDDLServicing
    @Published public var isSyncingDDL = false
    @Published public var notice: ScheduleNotice?
    @Published var schoolSMSCodeRequest: SchoolSMSCodeRequest?
    private var schoolSMSContinuation: CheckedContinuation<String, Error>?
    private(set) var schoolSMSWaitID: UUID?
    private var subscription: AnyCancellable?

    public init(service: any ScheduleDDLServicing, repository: ScheduleRepository, virtualNetworkLikely: @escaping @MainActor () -> Bool = { false }, beforeSchoolRequest: @escaping @MainActor () async -> Void = {}) {
        self.service = service
        self.beforeSchoolRequest = beforeSchoolRequest
        self.repository = repository
        self.virtualNetworkLikely = virtualNetworkLikely
        subscription = repository.ddlChanges.sink { [weak self] in self?.objectWillChange.send() }
    }

    func reset() {
        isSyncingDDL = false
        notice = nil
        cancelSchoolSMSWait()
    }

    public func loadIfNeeded() async { await repository.loadIfNeeded() }

    func isCancellation(_ error: Error) -> Bool { TaskCancellation.matches(error) }

    func submitSchoolSMSCode(_ code: String) {
        let normalized = code.filter(\.isNumber)
        guard (4 ... 8).contains(normalized.count) else { return }
        let continuation = schoolSMSContinuation
        schoolSMSContinuation = nil
        schoolSMSWaitID = nil
        schoolSMSCodeRequest = nil
        continuation?.resume(returning: normalized)
    }

    func dismissSchoolSMSCode() {
        cancelSchoolSMSWait()
    }

    func makeSchoolSMSCodeHandler(for generation: Int? = nil) -> SchoolSMSCodeHandler {
        { @MainActor [weak self] request in
            guard let self else { throw CancellationError() }
            if let generation, self.accountGeneration != generation {
                throw CancellationError()
            }
            guard self.schoolSMSContinuation == nil else { throw CancellationError() }
            let waitID = UUID()
            self.schoolSMSWaitID = waitID
            self.schoolSMSCodeRequest = request
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.schoolSMSContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelSchoolSMSWait(matching: waitID)
                }
            }
        }
    }

    func cancelSchoolSMSWait(matching waitID: UUID? = nil) {
        guard waitID == nil || schoolSMSWaitID == waitID else { return }
        let continuation = schoolSMSContinuation
        schoolSMSWaitID = nil
        schoolSMSContinuation = nil
        schoolSMSCodeRequest = nil
        continuation?.resume(throwing: CancellationError())
    }

    /// DDL 列表默认向前展示的天数。
    public var beforeDay: Int { min(max(cache.ddlBeforeDay, 0), 30) }
    /// DDL 列表默认向后保留的天数。
    public var afterDay: Int { min(max(cache.ddlAfterDay, 0), 30) }

    /// 经过时间窗口裁剪后的 DDL 列表。
    var visibleDDLEvents: [DDLEventRecord] {
        let threshold = Date().addingTimeInterval(TimeInterval(-afterDay * 24 * 3600))
        return cache.ddlEvents
            .filter { $0.dueAt >= threshold }
            .sorted { lhs, rhs in
                if lhs.done != rhs.done {
                    return !lhs.done
                }
                return lhs.dueAt < rhs.dueAt
            }
    }

    var ddlEmptyStateMessage: String {
        cache.ddlEvents.isEmpty
            ? "刷新课程中心作业，也可手动添加日程。"
            : "\(cache.ddlEvents.count) 条日程已超出显示范围。当前滞留天数为 \(afterDay) 天，可在 DDL 设置调整。"
    }


    /// 同步学校 DDL，并保留手动项目和完成状态。
    @discardableResult
    public func syncDDL(showSuccessNotice: Bool = true, showErrorNotice: Bool = true) async -> Bool {
        guard !isSyncingDDL else { return false }
        let generation = accountGeneration
        notice = nil
        isSyncingDDL = true
        defer {
            if accountGeneration == generation {
                isSyncingDDL = false
            }
        }

        do {
            let payload = try await service.syncDDLEvents(
                existingEvents: cache.ddlEvents,
                storedURL: cache.lexueCalendarURL,
                schoolSMSCodeHandler: makeSchoolSMSCodeHandler(for: generation)
            )
            guard accountGeneration == generation else { return false }
            cache.lexueCalendarURL = payload.url
            for event in cache.ddlEvents where event.isSchoolSynced {
                cache.lexueDDLCompletionByID[event.id] = event.done
            }
            let syncedEvents = payload.events.map { event in
                var event = event
                event.done = cache.lexueDDLCompletionByID[event.id] ?? event.done
                cache.lexueDDLCompletionByID[event.id] = event.done
                return event
            }
            cache.ddlEvents = ScheduleDDLEditor.mergingSyncedEvents(
                syncedEvents,
                into: cache.ddlEvents,
                syncedGroups: payload.syncedGroups
            )
            cache.ddlUpdatedAt = Date()
            guard await persistAndWait(), accountGeneration == generation else { return false }
            if showSuccessNotice {
                notice = ScheduleNotice.informational(
                    title: payload.warnings.isEmpty ? "DDL 同步成功" : "DDL 部分更新",
                    message: (["已同步 \(payload.events.count) 条学校日程。"] + payload.warnings).joined(separator: "\n")
                )
            }
            return payload.warnings.isEmpty
        } catch ScheduleServiceError.schoolSecondFactorRequired {
            guard accountGeneration == generation else { return false }
            presentDDLSecondFactorNotice()
            return false
        } catch let error as ScheduleServiceError {
            guard accountGeneration == generation else { return false }
            switch error {
            case .schoolSMSCodeInvalid:
                notice = ScheduleNotice.userInput(title: "验证码错误", message: error.localizedDescription)
            case .schoolSMSUnavailable:
                notice = ScheduleNotice(title: "短信验证失败", message: error.localizedDescription)
            default:
                if showErrorNotice {
                    notice = schoolFailureNotice(
                        title: "DDL 同步失败",
                        message: error.localizedDescription,
                        networkFailure: Self.isLikelySchoolTransportError(error)
                    )
                }
            }
            return false
        } catch {
            guard accountGeneration == generation else { return false }
            if isCancellation(error) { return false }
            if showErrorNotice {
                notice = schoolFailureNotice(
                    title: "DDL 同步失败",
                    message: error.localizedDescription,
                    networkFailure: Self.isLikelySchoolTransportError(error)
                )
            }
            return false
        }
    }

    /// DDL 页面展示的最近一次成功同步时间。
    var ddlLastUpdatedText: String {
        guard let updatedAt = cache.ddlUpdatedAt else { return "更新时间：暂无记录" }
        return "更新时间：\(updatedAt.formatted(.dateTime.month().day().hour().minute()))"
    }

    /// 强制重新抓取乐学日历订阅地址。
    ///
    /// 主要用在订阅链接失效或用户主动要求重置时。
    public func refreshLexueCalendarURL(showSuccessNotice: Bool = true) async {
        guard !isSyncingDDL else { return }
        let generation = accountGeneration
        notice = nil
        isSyncingDDL = true
        defer {
            if accountGeneration == generation {
                isSyncingDDL = false
            }
        }

        do {
            let url = try await service.refreshLexueCalendarURL(
                schoolSMSCodeHandler: makeSchoolSMSCodeHandler(for: generation)
            )
            guard accountGeneration == generation else { return }
            cache.lexueCalendarURL = url
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice.informational(title: "订阅链接更新成功", message: "已重新获取乐学订阅链接。")
            }
        } catch ScheduleServiceError.schoolSecondFactorRequired {
            guard accountGeneration == generation else { return }
            presentDDLSecondFactorNotice()
        } catch let error as ScheduleServiceError {
            guard accountGeneration == generation else { return }
            switch error {
            case .schoolSMSCodeInvalid:
                notice = ScheduleNotice.userInput(title: "验证码错误", message: error.localizedDescription)
            case .schoolSMSUnavailable:
                notice = ScheduleNotice(title: "短信验证失败", message: error.localizedDescription)
            default:
                notice = schoolFailureNotice(
                    title: "订阅链接获取失败",
                    message: error.localizedDescription,
                    networkFailure: Self.isLikelySchoolTransportError(error)
                )
            }
        } catch {
            guard accountGeneration == generation else { return }
            if isCancellation(error) { return }
            notice = schoolFailureNotice(
                title: "订阅链接获取失败",
                message: error.localizedDescription,
                networkFailure: Self.isLikelySchoolTransportError(error)
            )
        }
    }

    /// 切换某条 DDL 的完成状态。
    ///
    /// `done` 是纯本地状态，不会回写乐学网页端。
    func toggleDDLDone(_ event: DDLEventRecord) {
        guard cache.ddlEvents.contains(where: { $0.id == event.id }) else { return }
        cache.ddlEvents = ScheduleDDLEditor.togglingDone(id: event.id, in: cache.ddlEvents)
        if let updated = cache.ddlEvents.first(where: { $0.id == event.id }), updated.isSchoolSynced {
            cache.lexueDDLCompletionByID[updated.id] = updated.done
        }
        persist()
    }

    /// 把已有 DDL 记录转成编辑草稿。
    func ddlDraft(for event: DDLEventRecord?) -> DDLDraft {
        ScheduleDDLEditor.draft(for: event)
    }

    /// 新增一条本地 DDL。
    ///
    /// 手动 DDL 与乐学同步项并存，但会用 `group` 字段区分来源。
    func addDDL(_ draft: DDLDraft) throws {
        cache.ddlEvents = try ScheduleDDLEditor.adding(draft, to: cache.ddlEvents)
        persist()
    }

    /// 更新一条已有的本地 DDL。
    func updateDDL(id: String, draft: DDLDraft) throws {
        cache.ddlEvents = try ScheduleDDLEditor.updating(id: id, with: draft, in: cache.ddlEvents)
        persist()
    }

    /// 删除指定 DDL。
    func deleteDDL(id: String) {
        cache.ddlEvents = ScheduleDDLEditor.deleting(id: id, from: cache.ddlEvents)
        persist()
    }

    /// 修改 DDL 提前提醒窗口。
    public func setDDLBeforeDay(_ value: Int) {
        cache.ddlBeforeDay = min(max(value, 0), 30)
        persist()
    }

    /// 修改 DDL 过期后仍保留显示的窗口。
    public func setDDLAfterDay(_ value: Int) {
        cache.ddlAfterDay = min(max(value, 0), 30)
        persist()
    }

    /// DDL 到期时间文案。
    func ddlDueText(for event: DDLEventRecord) -> String {
        ScheduleDateCodec.formatRelativeDateTime(event.dueAt)
    }

    /// DDL 剩余/超时文案。
    func ddlRemainingText(for event: DDLEventRecord) -> String {
        let minutes = Int(event.dueAt.timeIntervalSinceNow / 60)
        let absolute = abs(minutes)
        let day = absolute / 1440
        let hour = (absolute % 1440) / 60
        let minute = absolute % 60

        let body: String
        if day > 0 {
            body = "\(day)天 \(hour)小时 \(minute)分钟"
        } else if hour > 0 {
            body = "\(hour)小时 \(minute)分钟"
        } else {
            body = "\(minute)分钟"
        }

        return minutes < 0 ? "已过 \(body)" : "剩余 \(body)"
    }

    /// DDL 颜色语义。
    ///
    /// 这里返回字符串；View 层根据业务语义选择具体颜色映射。
    func ddlTint(for event: DDLEventRecord) -> String {
        if event.done {
            return "gray"
        }

        let interval = event.dueAt.timeIntervalSinceNow
        if interval <= 0 {
            return "red"
        }

        if interval <= Double(beforeDay * 24 * 3600) {
            return "orange"
        }

        return "green"
    }

    private func presentDDLSecondFactorNotice() {
        notice = ScheduleNotice.userInput(
            title: "需要短信验证",
            message: "学校要求短信二次验证，请先在学校登录页面完成验证后再重试。"
        )
    }

}
