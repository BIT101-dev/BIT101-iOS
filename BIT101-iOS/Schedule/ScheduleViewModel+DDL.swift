//
//  ScheduleViewModel+DDL.swift
//  BIT101-iOS
//

import Foundation

extension ScheduleViewModel {
    /// 同步乐学 DDL，并保留本地手动项目和完成状态。
    @discardableResult
    func syncDDL(showSuccessNotice: Bool = true, showErrorNotice: Bool = true) async -> Bool {
        guard !isSyncingDDL else { return false }
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            let payload = try await service.syncDDLEvents(
                existingEvents: cache.ddlEvents,
                storedURL: cache.lexueCalendarURL
            )
            cache.lexueCalendarURL = payload.url
            cache.ddlEvents = ScheduleDDLEditor.mergingSyncedEvents(
                payload.events,
                into: cache.ddlEvents
            )
            cache.ddlUpdatedAt = Date()
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(
                    title: "DDL 同步成功",
                    message: payload.events.isEmpty ? "已更新成功，当前没有乐学日程。" : "已更新成功，共同步 \(payload.events.count) 条乐学日程。"
                )
            }
            return true
        } catch ScheduleServiceError.schoolSecondFactorRequired {
            notice = ScheduleNotice(
                title: "需要短信验证",
                message: "学校要求短信二次验证，请先在学校登录页面完成验证后再重试。"
            )
            return false
        } catch {
            if showErrorNotice {
                notice = ScheduleNotice(title: "DDL 同步失败", message: error.localizedDescription)
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
    func refreshLexueCalendarURL(showSuccessNotice: Bool = true) async {
        isSyncingDDL = true
        defer { isSyncingDDL = false }

        do {
            cache.lexueCalendarURL = try await service.refreshLexueCalendarURL()
            persist()
            if showSuccessNotice {
                notice = ScheduleNotice(title: "订阅链接更新成功", message: "已重新获取乐学订阅链接。")
            }
        } catch ScheduleServiceError.schoolSecondFactorRequired {
            notice = ScheduleNotice(
                title: "需要短信验证",
                message: "学校要求短信二次验证，请先在学校登录页面完成验证后再重试。"
            )
        } catch {
            notice = ScheduleNotice(title: "订阅链接获取失败", message: error.localizedDescription)
        }
    }

    /// 切换某条 DDL 的完成状态。
    ///
    /// `done` 是纯本地状态，不会回写乐学网页端。
    func toggleDDLDone(_ event: DDLEventRecord) {
        guard cache.ddlEvents.contains(where: { $0.id == event.id }) else { return }
        cache.ddlEvents = ScheduleDDLEditor.togglingDone(id: event.id, in: cache.ddlEvents)
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
    func setDDLBeforeDay(_ value: Int) {
        cache.ddlBeforeDay = max(value, 0)
        persist()
    }

    /// 修改 DDL 过期后仍保留显示的窗口。
    func setDDLAfterDay(_ value: Int) {
        cache.ddlAfterDay = max(value, 0)
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
    /// 这里返回字符串而不是 `Color`，是为了让 View 层自己决定具体颜色映射。
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

}
