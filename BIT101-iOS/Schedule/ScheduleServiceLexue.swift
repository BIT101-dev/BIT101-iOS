//
//  ScheduleServiceLexue.swift
//  BIT101-iOS
//
//  Lexue calendar discovery and iCalendar synchronization.
//

import Foundation

extension ScheduleService {
    /// 同步乐学 DDL，复用已缓存的订阅地址。
    ///
    /// 订阅 URL 通常稳定，优先复用缓存；缓存为空时从网页抓取。
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
        try await ensureSchoolSession()

        let finalURL = try await resolveLexueCalendarURL(storedURL: storedURL)
        let remoteEvents = try await fetchLexueEvents(urlString: finalURL)

        let existingDoneMap = Dictionary(uniqueKeysWithValues: existingEvents.map { ($0.id, $0.done) })
        let merged = remoteEvents.map { event in
            DDLEventRecord(
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
    /// 乐学页面可能使用 `webcal://`、`http://` 和 HTML 转义表示订阅链接。
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
            if isSchoolSMSAuthenticationPage(indexHTML) {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
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

        return fullURL
    }

    /// CAS 在切换网络或判定风险较高时可能直接进入短信二次认证页。
    private func isSchoolSMSAuthenticationPage(_ html: String) -> Bool {
        !html.captureGroups(
            pattern: #"id=[\"'](?:sso-second|current-login-type)[\"'][^>]*>\s*(?:true|smsLogin)\s*<"#,
            options: [.caseInsensitive]
        ).isEmpty
    }

    /// 下载并解析乐学 ICS 数据。
    private func fetchLexueEvents(urlString: String) async throws -> [DDLEventRecord] {
        // 订阅链接可能使用 webcal:// 或 http://，请求前统一升级为 HTTPS。
        let secureURLString = HTTPSURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let ics = try await sendStringRequest(request)
        return try ScheduleICSParser.parse(ics)
    }

    /// 从乐学页面提取订阅链接。
    private func extractCalendarURL(from html: String, pattern: String) -> String? {
        html.captureGroups(pattern: pattern, options: [.dotMatchesLineSeparators]).first
            .map { rawURLString in
                // 乐学页面可能把参数中的 & 转义为 &amp;，请求前需要还原。
                let urlString = decodeHTML(urlString: rawURLString)

                if urlString.lowercased().hasPrefix("webcal://") {
                    return "https://" + urlString.dropFirst("webcal://".count)
                }
                return HTTPSURLUpgrade.upgradedURLString(from: urlString)
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
