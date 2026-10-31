import SchedulePorts
import ClientCore
import TransportCore
import ScheduleDomain
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
    /// 诊断网络链路时探测乐学 DDL，避免触发短信发送。
    public func syncDDLEventsForPreflight(
        existingEvents: [DDLEventRecord],
        storedURL: String
    ) async throws -> DDLSyncPayload {
        try await syncDDLEvents(
            existingEvents: existingEvents,
            storedURL: storedURL,
            schoolSMSCodeHandler: nil,
            smsDeliveryMode: .preflight
        )
    }

    func syncDDLEvents(
        existingEvents: [DDLEventRecord],
        storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode,
        owner: SchoolSessionIdentity? = nil
    ) async throws -> DDLSyncPayload {
        let owner = owner ?? credentials.schoolSessionIdentity
        try validateAuthenticationOwner(owner)
        try await ensureSchoolSession(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode,
            owner: owner
        )

        var lastError: Error?
        for (index, baseURL) in lexueRouteBaseURLs(storedURL: storedURL).enumerated() {
            do {
                if smsDeliveryMode == .send, baseURL.host == webVPNLexueBaseURL.host, let nativeAuthenticator {
                    _ = try await nativeAuthenticator.authenticate(.webVPN)
                }
                var finalURL = try await resolveLexueCalendarURL(
                    storedURL: index == 0 ? storedURL : "",
                    baseURL: baseURL,
                    schoolSMSCodeHandler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode,
                    owner: owner
                )
                let remoteEvents: [DDLEventRecord]
                do {
                    remoteEvents = try await fetchLexueEvents(urlString: finalURL, schoolSMSCodeHandler: schoolSMSCodeHandler,
                        smsDeliveryMode: smsDeliveryMode, owner: owner)
                } catch {
                    guard index == 0, !storedURL.isEmpty, shouldRetryLexueRoute(after: error) else { throw error }
                    finalURL = try await resolveLexueCalendarURL(storedURL: "", baseURL: baseURL,
                        schoolSMSCodeHandler: schoolSMSCodeHandler, smsDeliveryMode: smsDeliveryMode, owner: owner)
                    remoteEvents = try await fetchLexueEvents(urlString: finalURL, schoolSMSCodeHandler: schoolSMSCodeHandler,
                        smsDeliveryMode: smsDeliveryMode, owner: owner)
                }

                let existingDoneMap = Dictionary(existingEvents.map { ($0.id, $0.done) }, uniquingKeysWith: { first, _ in first })
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
            } catch {
                lastError = error
                guard shouldRetryLexueRoute(after: error) else { throw error }
            }
        }
        throw lastError ?? ScheduleServiceError.invalidLexuePage
    }

    /// 强制重新抓取乐学订阅地址。
    public func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil) async throws -> String {
        try await refreshLexueCalendarURL(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: .send
        )
    }

    /// 诊断网络链路时探测学校二次验证页面，避免触发短信发送。
    public func refreshLexueCalendarURLForPreflight() async throws -> String {
        try await refreshLexueCalendarURL(
            schoolSMSCodeHandler: nil,
            smsDeliveryMode: .preflight
        )
    }

    func refreshLexueCalendarURL(
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode
    ) async throws -> String {
        let owner = credentials.schoolSessionIdentity
        try validateAuthenticationOwner(owner)
        try await ensureSchoolSession(
            schoolSMSCodeHandler: schoolSMSCodeHandler,
            smsDeliveryMode: smsDeliveryMode,
            owner: owner
        )
        var lastError: Error?
        for baseURL in lexueRouteBaseURLs(storedURL: "") {
            do {
                if smsDeliveryMode == .send, baseURL.host == webVPNLexueBaseURL.host, let nativeAuthenticator {
                    _ = try await nativeAuthenticator.authenticate(.webVPN)
                }
                return try await resolveLexueCalendarURL(
                    storedURL: "",
                    baseURL: baseURL,
                    schoolSMSCodeHandler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode,
                    owner: owner
                )
            } catch {
                lastError = error
                guard shouldRetryLexueRoute(after: error) else { throw error }
            }
        }
        throw lastError ?? ScheduleServiceError.invalidLexuePage
    }

    /// 解析乐学日历订阅 URL。
    ///
    /// 乐学页面可能使用 `webcal://`、`http://` 和 HTML 转义表示订阅链接。
    private func resolveLexueCalendarURL(
        storedURL: String,
        baseURL: URL,
        schoolSMSCodeHandler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode,
        owner: SchoolSessionIdentity,
        secondFactorRetryCount: Int = 0
    ) async throws -> String {
        if !storedURL.isEmpty {
            return storedURL
        }

        let indexPage = try await sendStringResponse(
            baseURL: baseURL,
            path: "/",
            requiresTeachingCenterSession: false,
            owner: owner
        )
        let indexHTML = indexPage.html
        guard
            let sesskey = indexHTML.captureGroups(pattern: #"[\"']sesskey[\"']:[\"']([^\"']+)[\"']"#).first,
            !sesskey.isEmpty
        else {
            if let context = SchoolLoginHTMLParser.parseSecondFactorPage(html: indexHTML, baseURL: schoolSSOBaseURL, documentURL: indexPage.url) {
                guard secondFactorRetryCount == 0 else {
                    throw ScheduleServiceError.schoolSecondFactorRequired
                }
                guard smsDeliveryMode == .preflight || schoolSMSCodeHandler != nil else {
                    throw ScheduleServiceError.schoolSecondFactorRequired
                }
                try await completeSchoolSecondFactor(
                    context,
                    handler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode,
                    owner: owner
                )
                return try await resolveLexueCalendarURL(
                    storedURL: "",
                    baseURL: baseURL,
                    schoolSMSCodeHandler: schoolSMSCodeHandler,
                    smsDeliveryMode: smsDeliveryMode,
                    owner: owner,
                    secondFactorRetryCount: secondFactorRetryCount + 1
                )
            }
            throw ScheduleServiceError.invalidLexuePage
        }

        let calendarPage = try await sendStringResponse(
            baseURL: baseURL,
            path: "/calendar/export.php",
            method: "POST",
            body: [
                ("sesskey", sesskey),
                ("_qf__core_calendar_export_form", "1"),
                ("events[exportevents]", "all"),
                ("period[timeperiod]", "recentupcoming"),
                ("generateurl", "获取日历网址"),
            ],
            requiresTeachingCenterSession: false,
            owner: owner
        )

        let calendarHTML = calendarPage.html
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(
            html: calendarPage.html,
            baseURL: schoolSSOBaseURL, documentURL: calendarPage.url
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
                smsDeliveryMode: smsDeliveryMode,
                owner: owner
            )
            return try await resolveLexueCalendarURL(
                storedURL: "",
                baseURL: baseURL,
                schoolSMSCodeHandler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode,
                owner: owner,
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

    private func lexueRouteBaseURLs(storedURL: String) -> [URL] {
        if nativeAuthenticator != nil { return [lexueBaseURL, webVPNLexueBaseURL] }
        if URL(string: storedURL)?.host == webVPNLexueBaseURL.host { return [webVPNLexueBaseURL, lexueBaseURL] }
        let studentID = credentials.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return teachingCenterState.shouldPreferDirect(for: studentID)
            ? [lexueBaseURL, webVPNLexueBaseURL] : [webVPNLexueBaseURL, lexueBaseURL]
    }

    /// 本机服务票据与学校功能共享同一套短信验证实现。
    public func completeSchoolAuthentication(_ context: SchoolSecondFactorContext,
        acceptingServiceTicket: Bool = false,
        handler: @escaping SchoolSMSCodeHandler) async throws {
        try await completeSchoolSecondFactor(context, handler: handler, smsDeliveryMode: .send,
            owner: credentials.schoolSessionIdentity, acceptingServiceTicket: acceptingServiceTicket)
    }

    private func shouldRetryLexueRoute(after error: Error) -> Bool {
        if isScheduleTransientNetworkError(error) { return true }

        let nsError = error as NSError
        let decodingFailure = ScheduleServiceError.invalidResponse as NSError
        if nsError.domain == decodingFailure.domain, nsError.code == decodingFailure.code { return true }
        if nsError.domain == "BIT101.Schedule", (400 ..< 600).contains(nsError.code) {
            return true
        }

        guard let error = error as? ScheduleServiceError else { return false }
        switch error {
        case .secondFactorRequired,
             .schoolSecondFactorRequired,
             .challengeInvalid:
            return false
        case .schoolTransportFailure,
             .invalidResponse,
             .invalidLexuePage,
             .invalidCalendarURL:
            return true
        default:
            return false
        }
    }

    func completeSchoolSecondFactor(
        _ context: SchoolSecondFactorContext,
        handler: SchoolSMSCodeHandler?,
        smsDeliveryMode: SchoolSMSDeliveryMode,
        owner: SchoolSessionIdentity,
        acceptingServiceTicket: Bool = false
    ) async throws {
        try validateAuthenticationOwner(owner)
        guard smsDeliveryMode == .send else { throw ScheduleServiceError.schoolSecondFactorRequired }
        guard let handler else { throw ScheduleServiceError.schoolSecondFactorRequired }
        teachingCenterState.selectOwner(owner)
        try await teachingCenterState.schoolSecondFactorRecovery.refresh(identity: owner) {
            try await self.completeSchoolSecondFactorBody(context, handler: handler, owner: owner,
                acceptingServiceTicket: acceptingServiceTicket)
        }
        try validateAuthenticationOwner(owner)
    }

    private func completeSchoolSecondFactorBody(
        _ context: SchoolSecondFactorContext, handler: @escaping SchoolSMSCodeHandler, owner: SchoolSessionIdentity,
        acceptingServiceTicket: Bool
    ) async throws {
        try validateAuthenticationOwner(owner)
        let studentID = credentials.currentStudentID
        let phone = try await fetchSecondFactorPhone(userObjectID: context.userObjectID, owner: owner)
        try await sendSecondFactorCode(to: phone.phone, owner: owner)
        let code = try await handler(
            SchoolSMSCodeRequest(
                maskedPhone: phone.maskedPhone,
                purpose: "school_sso_second_factor"
            )
        )
        try validateAuthenticationOwner(owner)
        try await verifySecondFactorCode(code, phone: phone.phone, owner: owner)

        var request = URLRequest(url: context.formAction)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(crypto.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = HTTPFormEncoding.body([
            ("username", studentID),
            ("password", code),
            ("type", "smsLogin"),
            ("_eventId", "submit"),
            ("geolocation", ""),
            ("execution", context.execution),
            ("captcha_code", ""),
            ("trustDevice", "false"),
        ])

        let (data, response) = try await sendRequest(request, owner: owner)
        let responseURL = response.url ?? context.formAction
        if let failure = SchoolServiceFailure.schoolResponse(String(decoding: data, as: UTF8.self)) { throw failure }
        let issuedServiceTicket = acceptingServiceTicket && (300..<400).contains(response.statusCode)
            && responseURL.host == schoolSSOBaseURL.host && responseURL == context.formAction
            && response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: responseURL)?.absoluteURL }
                .map(NativeSchoolAuthenticator.isIdentityServiceTicket) == true
        guard issuedServiceTicket || crypto.isAcceptedSchoolLoginCompletion(
            statusCode: response.statusCode,
            url: responseURL,
            schoolHost: schoolSSOBaseURL.host
        ) else {
            throw schoolSMSRequestFailure(.schoolSMSUnavailable("学校短信验证请求失败，HTTP 状态码 \(response.statusCode)。"),
                status: response.statusCode)
        }
        if SchoolLoginHTMLParser.parseSecondFactorPage(
            html: String(decoding: data, as: UTF8.self),
            baseURL: schoolSSOBaseURL, documentURL: responseURL
        ) != nil {
            throw ScheduleServiceError.schoolSMSCodeInvalid("短信验证码错误或已失效，请重新发起验证。")
        }
    }

    private func fetchSecondFactorPhone(userObjectID: String, owner: SchoolSessionIdentity) async throws -> (phone: String, maskedPhone: String) {
        let encrypted = try crypto.encryptSchoolURLCryptoBody(
            object: ["userId": userObjectID],
            publicKeyPEM: crypto.schoolURLCryptoPublicKey
        )
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/getPhoneNumberByUserId"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "hasCrypto")
        request.setValue(encrypted.encryptedKey, forHTTPHeaderField: "privateKey")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in crypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = Data(encrypted.body.utf8)

        let (data, response) = try await sendRequest(request, owner: owner)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw schoolSMSRequestFailure(.schoolSMSUnavailable("无法获取短信验证手机号。"), status: response.statusCode)
        }
        let decrypted = try crypto.decryptSchoolURLCryptoResponse(data, aesKey: encrypted.aesKey)
        guard let value = try phonePayload(from: decrypted, aesKey: encrypted.aesKey) else {
            let code = responseCode(from: decrypted).map(String.init) ?? "未知"
            let message = responseMessage(from: decrypted) ?? "无"
            throw ScheduleServiceError.schoolSMSUnavailable(
                "学校未返回可用的短信验证手机号（code=\(code)，message=\(message)，响应结构：\(jsonShape(decrypted))）。"
            )
        }
        guard
            let phone = phoneValue(in: value),
            !phone.isEmpty
        else {
            throw ScheduleServiceError.schoolSMSUnavailable("学校未返回可用的短信验证手机号。")
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
            let decryptedNested = try crypto.decryptSchoolURLCryptoResponse(
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

    private func sendSecondFactorCode(to phone: String, owner: SchoolSessionIdentity) async throws {
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/publicNoToken/sendSmsCode"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in crypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phone": phone,
            "businessNo": "0008",
        ])
        let (data, response) = try await sendRequest(request, owner: owner)
        let reusableCode = hasReusableSecondFactorCode(data)
        guard (200 ..< 300).contains(response.statusCode) || response.statusCode == 412 && reusableCode else {
            throw schoolSMSRequestFailure(.schoolSMSUnavailable(response.statusCode == 412
                ? "短信发送暂时受限，请稍后重试。" : "短信验证码发送失败。"), status: response.statusCode)
        }
        let code = responseCode(from: data)
        let message = responseMessage(from: data)
        let codeRemainsValid = message?.contains("验证码") == true
            && message?.contains("有效期内") == true
            && message?.contains("重复发送") == true
        guard code == 200 || codeRemainsValid || reusableCode else {
            throw ScheduleServiceError.schoolSMSUnavailable(code == 412
                ? "短信发送暂时受限，请稍后重试。" : message ?? "短信验证码发送失败。")
        }
    }

    private func hasReusableSecondFactorCode(_ data: Data) -> Bool {
        struct Response: Decodable {
            struct Failure: Decodable {
                let errorCode: Int
                let errorMessage: String
            }
            let code: Int
            let data: Failure
        }
        struct Cooldown: Decodable {
            let interval: Int
            let remaining: Int
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.code == 412, response.data.errorCode == 8000068,
              let cooldown = try? JSONDecoder().decode(Cooldown.self, from: Data(response.data.errorMessage.utf8)) else { return false }
        return cooldown.interval > 0 && cooldown.remaining > 0 && cooldown.remaining <= cooldown.interval
    }

    private func verifySecondFactorCode(_ code: String, phone: String, owner: SchoolSessionIdentity) async throws {
        var request = URLRequest(url: schoolSSOBaseURL.appending(path: "cas/api/protected/sms/checkToken"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(schoolSSOBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(schoolSSOBaseURL.appending(path: "cas/").absoluteString, forHTTPHeaderField: "Referer")
        for (field, value) in crypto.schoolProtectedHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phone": phone,
            "token": code,
            "delete": false,
            "trustDevice": false,
        ])
        let (data, response) = try await sendRequest(request, owner: owner)
        let failureMessage = response.statusCode == 412 || responseCode(from: data) == 412
            ? "短信验证码错误或已失效，请重新发起验证。"
            : responseMessage(from: data) ?? "短信验证码错误或已失效，请重新发起验证。"
        guard (200 ..< 300).contains(response.statusCode) else {
            throw schoolSMSRequestFailure(.schoolSMSCodeInvalid(failureMessage), status: response.statusCode)
        }
        guard responseCode(from: data) == 200 else {
            throw ScheduleServiceError.schoolSMSCodeInvalid(failureMessage)
        }
    }

    private func responseCode(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let number = root["code"] as? NSNumber { return number.intValue }
        if let string = root["code"] as? String { return Int(string) }
        return nil
    }

    private func schoolSMSRequestFailure(_ error: ScheduleServiceError, status: Int) -> any Error {
        if status == 403 || status >= 500 {
            return error.caused(by: NativeSchoolAuthenticationError.serviceUnavailable(status))
        }
        return error
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
        owner: SchoolSessionIdentity,
        retriedAfterSecondFactor: Bool = false
    ) async throws -> [DDLEventRecord] {
        // 订阅链接可能使用 webcal:// 或 http://，请求前统一升级为 HTTPS。
        let secureURLString = HTTPSURLUpgrade.upgradedURLString(from: urlString)

        guard let url = URL(string: secureURLString) else {
            throw ScheduleServiceError.invalidCalendarURL
        }

        let request = URLRequest(url: url)
        let calendarPage = try await sendStringResponse(request, owner: owner)
        let ics = calendarPage.html
        if let context = SchoolLoginHTMLParser.parseSecondFactorPage(
            html: ics,
            baseURL: schoolSSOBaseURL, documentURL: calendarPage.url
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
                smsDeliveryMode: smsDeliveryMode,
                owner: owner
            )
            return try await fetchLexueEvents(
                urlString: urlString,
                schoolSMSCodeHandler: schoolSMSCodeHandler,
                smsDeliveryMode: smsDeliveryMode,
                owner: owner,
                retriedAfterSecondFactor: true
            )
        }
        guard ics.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) != nil else {
            throw ScheduleServiceError.invalidLexuePage
        }
        let events = try await Self.parseCalendar(ics)
        try validateAuthenticationOwner(owner)
        return events
    }

    @concurrent
    private static func parseCalendar(_ ics: String) async throws -> [DDLEventRecord] {
        try Task.checkCancellation()
        let events: [DDLEventRecord]
        do {
            events = try ScheduleICSParser.parse(ics)
        } catch {
            try Task.checkCancellation()
            throw ScheduleServiceError.invalidCalendarData
        }
        try Task.checkCancellation()
        return events
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
