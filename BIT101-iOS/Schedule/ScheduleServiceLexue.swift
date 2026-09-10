//
//  ScheduleServiceLexue.swift
//  BIT101-iOS
//
//  Lexue calendar discovery and iCalendar synchronization.
//

import Foundation

enum SchoolSMSDeliveryMode: Equatable {
    case send
    case preflight
}

extension ScheduleService {
    /// 同步乐学 DDL，复用已缓存的订阅地址。
    ///
    /// 订阅 URL 通常稳定，优先复用缓存；缓存为空时从网页抓取。
    func syncDDLEvents(
        existingEvents: [DDLEventRecord],
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil
    ) async throws -> DDLSyncPayload {
        try await syncDDLEvents(
            existingEvents: existingEvents,
            storedURL: storedURL,
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: .send
        )
    }

    func syncDDLEvents(
        existingEvents: [DDLEventRecord],
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode
    ) async throws -> DDLSyncPayload {
        try await ensureSchoolSession(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode
        )

        let finalURL = try await resolveLexueCalendarURL(
            storedURL: storedURL,
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode
        )
        let remoteEvents = try await fetchLexueEvents(
            urlString: finalURL,
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode
        )

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
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil) async throws -> String {
        try await refreshLexueCalendarURL(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: .send
        )
    }

    func refreshLexueCalendarURL(
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode
    ) async throws -> String {
        try await ensureSchoolSession(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode
        )
        return try await resolveLexueCalendarURL(
            storedURL: "",
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode
        )
    }

    /// 解析乐学日历订阅 URL。
    ///
    /// 乐学页面可能使用 `webcal://`、`http://` 和 HTML 转义表示订阅链接。
    private func resolveLexueCalendarURL(
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode,
        secondFactorRetryCount: Int = 0
    ) async throws -> String {
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
            if let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: indexHTML, baseURL: schoolSSOBaseURL) {
                guard secondFactorRetryCount == 0 else {
                    throw ScheduleServiceError.schoolSecondFactorRequired
                }
                guard smsDeliveryMode == .preflight || schoolSMSCodeHandler != nil else {
                    throw ScheduleServiceError.schoolSecondFactorRequired
                }
                try await completeSchoolSecondFactor(
                    context,
                    handler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode
                )
                return try await resolveLexueCalendarURL(
                    storedURL: "",
                    schoolSMSCodeHandler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode,
                    secondFactorRetryCount: secondFactorRetryCount + 1
                )
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

        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(
            html: calendarHTML,
            baseURL: schoolSSOBaseURL
        ) {
            guard secondFactorRetryCount == 0 else {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
            guard smsDeliveryMode == .preflight || schoolSMSCodeHandler != nil else {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
            try await completeSchoolSecondFactor(
                context,
                handler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode
            )
            return try await resolveLexueCalendarURL(
                storedURL: "",
                schoolSMSCodeHandler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode,
                secondFactorRetryCount: secondFactorRetryCount + 1
            )
        }

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

    func completeSchoolSecondFactor(
        _ context: SchoolSecondFactorContext,
        handler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode
    ) async throws {
        let phone = try await fetchSecondFactorPhone(userObjectID: context.userObjectID)
        guard smsDeliveryMode == .send else {
            throw ScheduleServiceError.schoolSecondFactorRequired
        }
        guard let handler else {
            throw ScheduleServiceError.schoolSecondFactorRequired
        }
        try await sendSecondFactorCode(to: phone.phone)
        let code = try await handler(
            SchoolSMSCodeRequest(
                maskedPhone: phone.maskedPhone,
                purpose: "school_sso_second_factor"
            )
        )
        try await verifySecondFactorCode(code, phone: phone.phone)

        var request = URLRequest(url: context.formAction)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(BIT101APIClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = formBody([
            ("username", storage.currentStudentID),
            ("password", code),
            ("type", "smsLogin"),
            ("_eventId", "submit"),
            ("geolocation", ""),
            ("execution", context.execution),
            ("captcha_code", ""),
            ("trustDevice", "false"),
        ])

        let (data, response) = try await sendRequest(request)
        let responseURL = response.url ?? context.formAction
        guard BIT101APIClient.isAcceptedSchoolLoginCompletion(
            statusCode: response.statusCode,
            url: responseURL,
            schoolHost: schoolSSOBaseURL.host
        ) else {
            throw LoginServiceError.schoolSMSUnavailable(
                "学校短信验证请求失败，HTTP 状态码 \(response.statusCode)。"
            )
        }
        if SchoolLoginHTMLParser.parseSecondFactorPage(
            html: String(decoding: data, as: UTF8.self),
            baseURL: schoolSSOBaseURL
        ) != nil {
            throw LoginServiceError.schoolSMSCodeInvalid("短信验证码错误或已失效，请重新发起验证。")
        }
    }

    private func fetchSecondFactorPhone(userObjectID: String) async throws -> (phone: String, maskedPhone: String) {
        let encrypted = try LoginCrypto.encryptSchoolURLCryptoBody(
            object: ["userId": userObjectID],
            publicKeyPEM: LoginCrypto.schoolURLCryptoPublicKey
        )
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/getPhoneNumberByUserId"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "hasCrypto")
        request.setValue(encrypted.encryptedKey, forHTTPHeaderField: "privateKey")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in LoginCrypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = Data(encrypted.body.utf8)

        let (data, response) = try await sendRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw LoginServiceError.schoolSMSUnavailable("无法获取短信验证手机号。")
        }
        let decrypted = try LoginCrypto.decryptSchoolURLCryptoResponse(data, aesKey: encrypted.aesKey)
        guard let value = try phonePayload(from: decrypted, aesKey: encrypted.aesKey) else {
            let code = responseCode(from: decrypted).map(String.init) ?? "未知"
            let message = responseMessage(from: decrypted) ?? "无"
            throw LoginServiceError.schoolSMSUnavailable(
                "学校未返回可用的短信验证手机号（code=\(code)，message=\(message)，响应结构：\(jsonShape(decrypted))）。"
            )
        }
        guard
            let phone = phoneValue(in: value),
            !phone.isEmpty
        else {
            throw LoginServiceError.schoolSMSUnavailable("学校未返回可用的短信验证手机号。")
        }
        let maskedPhone = (value["maskTel"] as? String)
            ?? (value["maskedPhone"] as? String)
            ?? "绑定手机"
        return (phone, maskedPhone)
    }

    private func phonePayload(from data: Data, aesKey: Data) throws -> [String: Any]? {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        if let found = phoneDictionary(in: root) { return found }
        if let dictionary = root as? [String: Any], let nested = dictionary["data"] as? String {
            let decryptedNested = try LoginCrypto.decryptSchoolURLCryptoResponse(
                Data(nested.utf8),
                aesKey: aesKey
            )
            if let nestedRoot = try? JSONSerialization.jsonObject(with: decryptedNested),
               let found = phoneDictionary(in: nestedRoot) {
                return found
            }
        }
        return nil
    }

    private func phoneDictionary(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if phoneValue(in: dictionary) != nil { return dictionary }
            for child in dictionary.values {
                if let found = phoneDictionary(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = phoneDictionary(in: child) { return found }
            }
        }
        return nil
    }

    private func phoneValue(in dictionary: [String: Any]) -> String? {
        for key in ["tel", "phone", "phoneNumber", "mobile", "telephone", "opaquePhone"] {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func jsonShape(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return "非 JSON"
        }
        if let dictionary = root as? [String: Any] {
            let keys = dictionary.keys.sorted().joined(separator: ",")
            if let data = dictionary["data"] {
                return "对象字段 \(keys)，data=\(jsonShape(data, depth: 1))"
            }
            return "对象字段 \(keys)"
        }
        if root is [Any] { return "数组" }
        return "JSON 基础值"
    }

    private func jsonShape(_ value: Any, depth: Int) -> String {
        guard depth < 2 else { return "嵌套对象" }
        if let dictionary = value as? [String: Any] {
            return "对象字段 \(dictionary.keys.sorted().joined(separator: ","))"
        }
        if value is [Any] { return "数组" }
        if value is String { return "字符串" }
        return "基础值"
    }

    private func sendSecondFactorCode(to phone: String) async throws {
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/publicNoToken/sendSmsCode"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in LoginCrypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phone": phone,
            "businessNo": "0008",
        ])
        let (data, response) = try await sendRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw LoginServiceError.schoolSMSUnavailable("短信验证码发送失败。")
        }
        let code = responseCode(from: data)
        let message = responseMessage(from: data)
        let codeRemainsValid = message?.contains("验证码") == true
            && message?.contains("有效期内") == true
            && message?.contains("重复发送") == true
        guard code == 200 || codeRemainsValid else {
            throw LoginServiceError.schoolSMSUnavailable(message ?? "短信验证码发送失败。")
        }
    }

    private func verifySecondFactorCode(_ code: String, phone: String) async throws {
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/checkToken"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in LoginCrypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phone": phone,
            "token": code,
            "delete": false,
            "trustDevice": false,
        ])
        let (data, response) = try await sendRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw LoginServiceError.schoolSMSCodeInvalid(responseMessage(from: data) ?? "短信验证码错误或已失效，请重新发起验证。")
        }
        guard responseCode(from: data) == 200 else {
            throw LoginServiceError.schoolSMSCodeInvalid(responseMessage(from: data) ?? "短信验证码错误或已失效，请重新发起验证。")
        }
    }

    private func responseCode(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let number = root["code"] as? NSNumber { return number.intValue }
        if let string = root["code"] as? String { return Int(string) }
        return nil
    }

    private func responseMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["message", "msg", "errorMessage"] {
            if let message = root[key] as? String, !message.isEmpty { return message }
        }
        if let nested = root["data"] as? [String: Any] {
            for key in ["message", "msg", "errorMessage"] {
                if let message = nested[key] as? String, !message.isEmpty { return message }
            }
        }
        return nil
    }

    /// 下载并解析乐学 ICS 数据。
    private func fetchLexueEvents(
        urlString: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode,
        retriedAfterSecondFactor: Bool = false
    ) async throws -> [DDLEventRecord] {
        // 订阅链接可能使用 webcal:// 或 http://，请求前统一升级为 HTTPS。
        let secureURLString = HTTPSURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let ics = try await sendStringRequest(request)
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(
            html: ics,
            baseURL: schoolSSOBaseURL
        ) {
            guard !retriedAfterSecondFactor else {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
            guard smsDeliveryMode == .preflight || schoolSMSCodeHandler != nil else {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
            try await completeSchoolSecondFactor(
                context,
                handler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode
            )
            return try await fetchLexueEvents(
                urlString: urlString,
                schoolSMSCodeHandler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode,
                retriedAfterSecondFactor: true
            )
        }
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
