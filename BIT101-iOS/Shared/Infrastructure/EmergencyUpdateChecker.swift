import Foundation

/// Cloudflare 远程配置命中的紧急功能更新提醒。
struct EmergencyUpdateNotice: Decodable, Equatable, Identifiable {
    let schemaVersion: Int
    let enabled: Bool
    let noticeID: String
    let maximumAffectedBuild: Int
    let title: String
    let message: String
    let updateURL: URL?

    enum CodingKeys: String, CodingKey {
        case enabled, title, message
        case schemaVersion = "schema_version"
        case noticeID = "notice_id"
        case maximumAffectedBuild = "maximum_affected_build"
        case updateURL = "update_url"
    }

    var id: String { noticeID }

    /// 远程配置不能把用户引向任意网站；非法地址统一回退到 BIT101 的 App Store 页面。
    var safeUpdateURL: URL {
        if let updateURL,
           updateURL.host?.lowercased() == "apps.apple.com",
           updateURL.path.contains("id6761147125")
        {
            return updateURL
        }
        return BIT101AppStore.url
    }
}

/// 启动时异步读取紧急更新配置；失败静默，不阻塞 App 首屏。
@MainActor
final class EmergencyUpdateChecker {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let ignoredNoticeKey = "app.emergency-update.ignored-notice"
    nonisolated static let ignoredDateKey = "app.emergency-update.ignored-date"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private let installedBuild: () -> Int
    private let endpointURL: () -> URL?
    private let loadData: DataLoader

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        installedBuild: @escaping () -> Int = {
            Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        },
        endpointURL: @escaping () -> URL? = {
            guard
                let raw = Bundle.main.object(forInfoDictionaryKey: "BIT101EmergencyUpdateURL") as? String,
                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return URL(string: raw)
        },
        loadData: @escaping DataLoader = { request in
            let response = try await HTTPClient.shared.send(request, accepting: 100 ..< 600)
            return (response.data, response.response)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.installedBuild = installedBuild
        self.endpointURL = endpointURL
        self.loadData = loadData
    }

    func noticeToPresentAtLaunch() async -> EmergencyUpdateNotice? {
        guard let endpointURL = endpointURL() else { return nil }

        var request = URLRequest(
            url: endpointURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 5
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await loadData(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode)
            else { return nil }

            let notice = try JSONDecoder().decode(EmergencyUpdateNotice.self, from: data)
            guard notice.schemaVersion == 1,
                  notice.enabled,
                  !notice.noticeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !notice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !notice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  installedBuild() <= notice.maximumAffectedBuild,
                  !isIgnoredToday(noticeID: notice.noticeID)
            else { return nil }
            return notice
        } catch {
            return nil
        }
    }

    /// 只允许忽略到本地日历的当天结束；不能永久屏蔽某条紧急提醒。
    func ignoreForToday(noticeID: String) {
        defaults.set(noticeID, forKey: Self.ignoredNoticeKey)
        defaults.set(now(), forKey: Self.ignoredDateKey)
    }

    private func isIgnoredToday(noticeID: String) -> Bool {
        guard defaults.string(forKey: Self.ignoredNoticeKey) == noticeID,
              let ignoredAt = defaults.object(forKey: Self.ignoredDateKey) as? Date
        else { return false }
        return calendar.isDate(ignoredAt, inSameDayAs: now())
    }
}
