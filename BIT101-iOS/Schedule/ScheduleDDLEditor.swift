//
//  ScheduleDDLEditor.swift
//  BIT101-iOS
//

import Foundation

/// DDL 集合的纯编辑规则。
///
/// 这里不接触持久化或页面状态，使手动 DDL 的增删改、完成状态与乐学同步合并
/// 可以独立测试；`ScheduleViewModel` 只负责把结果写回缓存。
enum ScheduleDDLEditor {
    static func draft(for event: DDLEventRecord?) -> DDLDraft {
        guard let event else { return DDLDraft() }
        return DDLDraft(title: event.title, dueAt: event.dueAt, text: event.text)
    }

    static func mergingSyncedEvents(
        _ syncedEvents: [DDLEventRecord],
        into existingEvents: [DDLEventRecord]
    ) -> [DDLEventRecord] {
        let manualEvents = existingEvents.filter { $0.group != "lexue" }
        let existingLexueEvents = Dictionary(
            existingEvents
                .filter { $0.group == "lexue" }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mergedSyncedEvents = syncedEvents.map { event in
            guard let existing = existingLexueEvents[event.id] else { return event }
            var merged = event
            merged.done = existing.done
            return merged
        }
        return (manualEvents + mergedSyncedEvents).sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
    }

    static func togglingDone(id: String, in events: [DDLEventRecord]) -> [DDLEventRecord] {
        var events = events
        guard let index = events.firstIndex(where: { $0.id == id }) else { return events }
        events[index].done.toggle()
        return events
    }

    static func adding(
        _ draft: DDLDraft,
        to events: [DDLEventRecord],
        id: String = UUID().uuidString
    ) throws -> [DDLEventRecord] {
        var events = events
        events.append(DDLEventRecord(
            id: id,
            group: "main",
            title: try normalizedTitle(draft.title),
            text: draft.text,
            dueAt: draft.dueAt,
            done: false
        ))
        return events.sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
    }

    static func updating(
        id: String,
        with draft: DDLDraft,
        in events: [DDLEventRecord]
    ) throws -> [DDLEventRecord] {
        var events = events
        guard let index = events.firstIndex(where: { $0.id == id }) else { return events }
        events[index].title = try normalizedTitle(draft.title)
        events[index].text = draft.text
        events[index].dueAt = draft.dueAt
        return events.sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
    }

    static func deleting(id: String, from events: [DDLEventRecord]) -> [DDLEventRecord] {
        events.filter { $0.id != id }
    }

    private static func normalizedTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw NSError(
                domain: "BIT101.Schedule",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "标题不能为空。"]
            )
        }
        return title
    }
}
