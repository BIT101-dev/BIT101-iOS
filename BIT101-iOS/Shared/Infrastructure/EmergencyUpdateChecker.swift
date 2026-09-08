import Foundation

private enum EmergencyUpdateURLPolicy {
    nonisolated static let endpointHost = "update.aihelpme.dev"
    nonisolated static let appStoreHost = "apps.apple.com"

    nonisolated static func acceptsHTTPS(_ url: URL, host: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.port == nil || url.port == 443
        else { return false }
        return true
    }
}

/// 应用在 Cloudflare 远程配置命中条件时展示紧急功能更新提醒。
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

    /// 应用接受 HTTPS 的 apps.apple.com 地址、默认端口或 443 端口以及 BIT101 App ID；其余地址回退到 BIT101AppStore.url。
    var safeUpdateURL: URL {
        if let updateURL,
           EmergencyUpdateURLPolicy.acceptsHTTPS(updateURL, host: EmergencyUpdateURLPolicy.appStoreHost),
           updateURL.path.contains("id6761147125")
        {
            return updateURL
        }
        return BIT101AppStore.url
    }
}

/// 应用启动时异步读取紧急更新配置；update.aihelpme.dev 的 HTTPS 默认端口或 443 端口满足端点条件，其余输入、请求错误与无效内容返回 nil，首屏保持可用。
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
            guard let url = URL(string: raw),
                  EmergencyUpdateURLPolicy.acceptsHTTPS(url, host: EmergencyUpdateURLPolicy.endpointHost)
            else { return nil }
            return url
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

    /// 应用按本地日历日期保存忽略状态；日期变化后同一提醒重新参与判断。
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
