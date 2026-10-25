import ClientCore
import Foundation
import ScoreDomain
import ScorePorts
import TransportCore

/// 教务系统 HTML 表格协议；列名参与校验，字段扩展沿学校表头保留。
nonisolated enum NativeSchoolScoreParser {
    @concurrent static func parse(_ data: Data) async throws -> Table {
        guard let html = String(data: data, encoding: .utf8) else { throw ScoreServiceError.invalidResponse }
        if let failure = SchoolServiceFailure.schoolResponse(html) { throw failure }
        return try parse(html)
    }

    @concurrent static func detail(_ data: Data) async throws -> [String] {
        guard let html = String(data: data, encoding: .utf8) else { throw ScoreServiceError.invalidResponse }
        if let failure = SchoolServiceFailure.schoolResponse(html) { throw failure }
        return try detail(html)
    }

    struct Record: Sendable {
        var values: [String]
        let detailPath: String?
    }
    struct Table: Sendable {
        let headers: [String]
        let records: [Record]
    }

    static func parse(_ html: String) throws -> Table {
        guard let table = tables(html).first else { throw ScoreServiceError.invalidResponse }
        let rows = captures(#"<tr\b[^>]*>([\s\S]*?)</tr\s*>"#, in: table)
        guard let header = rows.first else { throw ScoreServiceError.invalidResponse }
        let headers = cells(header).map(text)
        guard Set(headers).isSuperset(of: ScoreRow.requiredHeaderNames),
              headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count else {
            throw ScoreServiceError.invalidResponse
        }
        var records: [Record] = []
        for row in rows.dropFirst() {
            try Task.checkCancellation()
            let raw = cells(row)
            // 学校空结果提示以 colspan 单元格呈现。
            if raw.count == 1, row.range(of: #"\bcolspan\s*="#, options: .regularExpression) != nil { continue }
            guard raw.count == headers.count else { throw ScoreServiceError.invalidResponse }
            var values = raw.map(text)
            if let index = headers.firstIndex(of: "成绩"),
               let numeric = ["优秀": "95", "良好": "85", "中等": "75", "及格": "65", "不及格": "0"][values[index]] {
                values[index] = numeric
            }
            guard ScoreRow(index: records.count, headers: headers, values: values).hasValidCourseIdentity else {
                throw ScoreServiceError.invalidResponse
            }
            let path = captures(#"['"](/jsxsd/kscj/cjfx[^'"]*)['"]"#, in: decode(row)).first
            records.append(Record(values: values, detailPath: path))
        }
        return Table(headers: headers, records: records)
    }

    static let detailHeaders = ["专业人数", "学习人数", "平均分", "本人成绩", "班级人数", "最高分",
        "该课程所有教学班成绩录入完毕", "本人成绩在班级中占", "本人成绩在专业中占", "本人成绩在所有学生中占"]

    static func detail(_ html: String) throws -> [String] {
        let list = tables(html)
        guard list.count >= 3 else { throw ScoreServiceError.invalidResponse }
        let detailCells = cells(list[1]) + cells(list[2])
        var fields: [String: String] = [:]
        for cell in detailCells {
            let parts = text(cell).split(separator: "：", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard fields["本人成绩"] != nil else { throw ScoreServiceError.invalidResponse }
        return detailHeaders.map { fields[$0] ?? "" }
    }

    static func tables(_ html: String) -> [String] {
        captures(#"<table\b[^>]*\bid\s*=\s*["']dataList["'][^>]*>([\s\S]*?)</table\s*>"#, in: html)
    }

    private static func cells(_ html: String) -> [String] {
        captures(#"<t[dh]\b[^>]*>([\s\S]*?)</t[dh]\s*>"#, in: html)
    }

    private static func captures(_ pattern: String, in html: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func text(_ html: String) -> String {
        decode(html.replacingOccurrences(of: #"<script\b[\s\S]*?</script>|<style\b[\s\S]*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ html: String) -> String {
        var result = html
        for (entity, value) in ["&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&"] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        let expression = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in (expression?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []).reversed() {
            guard let valueRange = Range(match.range(at: 1), in: result), let range = Range(match.range, in: result) else { continue }
            let value = String(result[valueRange])
            let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
        }
        return result
    }
}

final class NativeSchoolScoreQuery {
    let challenge: BITLoginAuthenticationChallenge
    var table: NativeSchoolScoreParser.Table?
    var remoteChallenge: BITLoginAuthenticationChallenge?
    init(_ challenge: BITLoginAuthenticationChallenge) { self.challenge = challenge }
}

final class NativeSchoolScoreQueries {
    private var current: NativeSchoolScoreQuery?
    func query(for challenge: BITLoginAuthenticationChallenge) -> NativeSchoolScoreQuery {
        if let current, current.challenge == challenge { return current }
        let query = NativeSchoolScoreQuery(challenge)
        current = query
        return query
    }
}

struct NativeSchoolScoreReader {
    let client: HTTPClient
    let validate: () throws -> Void
    let query: NativeSchoolScoreQuery
    let deadline: ContinuousClock.Instant

    func fetch(detail: Bool, session: SchoolAuthenticatedSession) async throws -> [ScoreRow] {
        let url = try resource("/jsxsd/kscj/cjcx_list", base: session.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(session.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        guard let host = url.host else { throw ScoreServiceError.invalidResponse }
        request.setValue("https://" + host, forHTTPHeaderField: "Origin")
        request.httpBody = HTTPFormEncoding.body([("kksj", ""), ("kcxz", ""), ("kcmc", ""), ("xsfs", "all")])
        let table: NativeSchoolScoreParser.Table
        if let cached = query.table { table = cached }
        else {
            table = try await decoded(request, using: NativeSchoolScoreParser.parse)
            query.table = table
        }
        defer { if detail { query.table = nil } }
        var rows: [ScoreRow] = []
        var failure: (any Error)?
        for (index, record) in table.records.enumerated() {
            try validate()
            var values = record.values
            var headers = table.headers
            if detail {
                if let path = record.detailPath {
                    do {
                        let request = URLRequest(url: try resource(path, base: session.baseURL))
                        values += try await decoded(request, using: NativeSchoolScoreParser.detail)
                        headers += NativeSchoolScoreParser.detailHeaders
                    } catch {
                        try validate()
                        if TaskCancellation.matches(error) { throw error }
                        if failure == nil || SchoolServiceFailure.from(error) != nil { failure = error }
                    }
                } else {
                    headers += NativeSchoolScoreParser.detailHeaders
                    values += Array(repeating: "", count: NativeSchoolScoreParser.detailHeaders.count)
                }
            }
            let row = ScoreRow(index: index, headers: headers, values: values)
            rows.append(row)
        }
        try validate()
        if let failure { throw PartialScoreResult(rows: rows, failure: failure) }
        return rows
    }

    private func decoded<Value: Sendable>(_ original: URLRequest, using decode: (Data) async throws -> Value) async throws -> Value {
        try validate()
        var request = original
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw URLError(.timedOut) }
        request.timeoutInterval = min(25, seconds)
        let response: HTTPResponse
        do { response = try await client.send(request) }
        catch let HTTPClientError.unacceptableStatus(code, _) where code == 403 || code >= 500 {
            throw NativeSchoolAuthenticationError.serviceUnavailable(code)
        }
        try validate()
        let value = try await response.validated { data, http in
            guard http.url == request.url else { throw ScoreServiceError.invalidResponse }
            return try await decode(data)
        }
        try validate()
        return value
    }

    private func resource(_ path: String, base: URL) throws -> URL {
        let url: URL?
        if base.host == "webvpn.bit.edu.cn", path.hasPrefix("/jsxsd/") {
            url = URL(string: base.absoluteString + path)
        } else { url = URL(string: path, relativeTo: base)?.absoluteURL }
        guard let url, AppURL.isSameOrigin(url, as: base), url.scheme == "https", url.user == nil,
              url.password == nil, url.path.hasPrefix(base.host == "webvpn.bit.edu.cn" ? base.path + "/jsxsd/" : "/jsxsd/") else {
            throw ScoreServiceError.invalidResponse
        }
        return url
    }
}
