import ScheduleDomain
//
//  ScheduleDDLEditor.swift
//  BIT101-iOS
//

import Foundation

/// DDL 集合的纯编辑规则。
///
/// 手动编辑与学校来源合并共用完成状态和排序规则。
enum ScheduleDDLEditor {
    static func draft(for event: DDLEventRecord?) -> DDLDraft {
        guard let event else { return DDLDraft() }
        return DDLDraft(title: event.title, dueAt: event.dueAt, text: event.text)
    }

    static func mergingSyncedEvents(
        _ syncedEvents: [DDLEventRecord],
        into existingEvents: [DDLEventRecord],
        syncedGroups: Set<String> = ["lexue"]
    ) -> [DDLEventRecord] {
        let manualEvents = existingEvents.filter { !syncedGroups.contains($0.group) }
        let existingLexueEvents = Dictionary(
            existingEvents
                .filter { syncedGroups.contains($0.group) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let uniqueEvents = Dictionary(syncedEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mergedSyncedEvents = uniqueEvents.values.map { event in
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
