//
//  ScheduleServiceLexue.swift
//  BIT101-iOS
//
//  Lexue calendar discovery and iCalendar synchronization.
//

import Foundation

extension ScheduleService {
    /// 同步乐学 DDL，并尽量复用已缓存的订阅地址。
    ///
    /// 订阅 URL 一般比较稳定，因此优先复用缓存；只有缓存不存在时才回退到网页抓取。
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
        try await ensureSchoolSession()

        // 乐学同步允许复用已缓存的订阅链接，只有没有链接时才回到网页里重新抓取。
        let finalURL = try await resolveLexueCalendarURL(storedURL: storedURL)
        let remoteEvents = try await fetchLexueEvents(urlString: finalURL)

        let existingDoneMap = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0.done) })
        let merged = remoteEvents.map { event in
            return DDLEventRecord(
                id: event.id,
                group: event.group,
                title: event.title,
                text: event.text,
                dueAt: event.dueAt,
                done: existingDoneMap[event.id] ?? event.done
            )
        }

        return DDLSyncPayload(url: finalURL, events: merged)
    }

    /// 强制重新抓取乐学订阅地址。
    func refreshLexueCalendarURL() async throws -> String {
        try await ensureSchoolSession()
        return try await resolveLexueCalendarURL(storedURL: "")
    }

    /// 解析乐学日历订阅 URL。
    ///
    /// 乐学页面会把真正的订阅链接埋在 HTML 中，而且可能混用 `webcal://`、`http://` 与 HTML 转义，
    /// 所以这里要做一整套兜底提取。
    private func resolveLexueCalendarURL(storedURL: String) async throws -> String {
        if !storedURL.isEmpty {
            return storedURL
        }

        let indexHTML = try await sendStringRequest(
            baseURL: lexueBaseURL,
            path: "/",
            requiresTeachingCenterSession: false
        )
        guard
            let sesskey = indexHTML.captureGroups(pattern: #"[\"']sesskey[\"']:[\"']([^\"']+)[\"']"#).first,
            !sesskey.isEmpty
        else {
            throw ScheduleServiceError.invalidLexuePage
        }

        let calendarHTML = try await sendStringRequest(
            baseURL: lexueBaseURL,
            path: "/calendar/export.php",
            method: "POST",
            body: [
                ("sesskey", sesskey),
                ("_qf__core_calendar_export_form", "1"),
                ("events[exportevents]", "all"),
                ("period[timeperiod]", "recentupcoming"),
                ("generateurl", "获取日历网址"),
            ],
            requiresTeachingCenterSession: false
        )

        let fullURL =
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(https?://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"class=["'][^"']*calendarurl[^"']*["'][^>]*>[\s\S]*?(webcal://[^<"'\s]+)"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"value=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](https?://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"href=["'](webcal://[^"']+)["']"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"https?://[^\s"'<]+"#) ??
            extractCalendarURL(from: calendarHTML, pattern: #"webcal://[^\s"'<]+"#)

        guard let fullURL else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        return ScheduleURLUpgrade.upgradedURLString(from: fullURL)
    }

    /// 下载并解析乐学 ICS 数据。
    private func fetchLexueEvents(urlString: String) async throws -> [DDLEventRecord] {
        // 订阅链接可能以 webcal:// 或 http:// 返回，这里统一标准化后再拉取 ICS。
        let secureURLString = ScheduleURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let ics = try await sendStringRequest(request)
        return try ScheduleICSParser.parse(ics)
    }

    /// 用正则从乐学页面里尝试提取订阅链接。
    private func extractCalendarURL(from html: String, pattern: String) -> String? {
        html.captureGroups(pattern: pattern, options: [.dotMatchesLineSeparators]).first
            .map { rawURLString in
                // 乐学页面可能把参数里的 & 转义成 &amp;，不先还原就会打成 404。
                let urlString = decodeHTML(urlString: rawURLString)

                if urlString.lowercased().hasPrefix("webcal://") {
                    return "https://" + urlString.dropFirst("webcal://".count)
                }
                return ScheduleURLUpgrade.upgradedURLString(from: urlString)
            }
    }

    /// 还原 HTML 属性里的常见实体转义。
    private func decodeHTML(urlString: String) -> String {
        urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
