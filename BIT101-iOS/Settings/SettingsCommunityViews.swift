import SwiftUI
import UIKit
import WebKit

struct GallerySettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var hiddenUsers: [MineUserInfo] = []
    @State private var isLoadingUsers = false
    @State private var alert: AppAlert?
    @State private var imageCacheLimitMB = GalleryImageCachePreferences.limitMB
    @State private var imageCacheUsageText = "计算中"

    private let service = SettingsNetworkService()

    var body: some View {
        List {
            Section {
                NavigationLink {
                    HiddenUsersPage(hiddenUsers: hiddenUsers, isLoading: isLoadingUsers) { index in
                        settings.removeHiddenUser(at: index + (settings.galleryHiddenUserIDs.first == -1 ? 1 : 0))
                        Task { await loadHiddenUsers() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("隐藏用户")
                        Text("当前列表中\(settings.galleryHiddenUserIDs.filter { $0 != -1 }.count == 0 ? "没有用户" : "有 \(settings.galleryHiddenUserIDs.filter { $0 != -1 }.count) 名用户")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    HiddenPostersPage(hiddenPosters: settings.galleryHiddenPosters) { index in
                        settings.removeHiddenPoster(at: index)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("隐藏帖子")
                        Text("当前列表中\(settings.galleryHiddenPosters.isEmpty ? "没有帖子" : "有 \(settings.galleryHiddenPosters.count) 条帖子")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("隐藏匿名用户", isOn: Binding(
                    get: { settings.galleryHiddenUserIDs.first == -1 },
                    set: { _ in settings.toggleHideAnonymous() }
                ))

                Toggle("严格屏蔽模式", isOn: Binding(
                    get: { settings.galleryHideStrictMode },
                    set: { settings.updateGallerySettings(hideStrictMode: $0) }
                ))
            } header: {
                Text("屏蔽设置")
            } footer: {
                Text("开启后，如果一条评论是在回复已屏蔽用户，也会一并隐藏。")
            }

            Section("机器人") {
                Toggle("在搜索结果中隐藏机器人帖子", isOn: Binding(
                    get: { settings.galleryHideBotPosterInSearch },
                    set: { settings.updateGallerySettings(hideBotPosterInSearch: $0) }
                ))
            }

            Section {
                HStack(spacing: 12) {
                    TextField("缓存上限", value: $imageCacheLimitMB, format: .number)
                        .keyboardType(.numberPad)
                        .onChange(of: imageCacheLimitMB) { _, newValue in
                            let normalized = max(newValue, 0)
                            if normalized != newValue {
                                imageCacheLimitMB = normalized
                                return
                            }
                            GalleryImageCachePreferences.limitMB = normalized
                            Task {
                                await GalleryImageCache.shared.enforceCurrentLimit()
                                await refreshImageCacheUsage()
                            }
                        }

                    Text("已用缓存 \(imageCacheUsageText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            } header: {
                Text("本地图片缓存上限（MB）")
            } footer: {
                Text("低清图、高清图和动图共用此额度。输入 0 表示无限；缓存仍可能在设备空间不足时被系统清理。")
            }

            Section("社区治理") {
                Text(settings.hasAcceptedCurrentCommunityRules ? "当前设备已同意最新社区规则。" : "当前设备尚未同意社区规则，首次进入话廊时会弹出提示。")
                    .foregroundStyle(.secondary)
                Text("联系邮箱：\(CommunitySupport.email)")
                    .textSelection(.enabled)

                if settings.hasAcceptedCurrentCommunityRules {
                    Button("撤销同意社区规则", role: .destructive) {
                        settings.revokeCommunityRulesAcceptance()
                    }
                }
            }
        }
        .task {
            imageCacheLimitMB = GalleryImageCachePreferences.limitMB
            await refreshImageCacheUsage()
            await loadHiddenUsers()
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    /// 在后台统计话廊图片缓存，并以系统文件大小格式回写设置页。
    private func refreshImageCacheUsage() async {
        let bytes = await GalleryImageCache.shared.usedBytes()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        imageCacheUsageText = formatter.string(fromByteCount: bytes)
    }

    /// 批量加载已隐藏用户的公开资料，供列表展示昵称和头像。
    private func loadHiddenUsers() async {
        isLoadingUsers = true
        defer { isLoadingUsers = false }
        do {
            hiddenUsers = try await withThrowingTaskGroup(of: MineUserInfo.self) { group in
                for uid in settings.galleryHiddenUserIDs where uid != -1 {
                    group.addTask { try await service.fetchUserInfo(id: uid) }
                }
                var result: [MineUserInfo] = []
                for try await item in group {
                    result.append(item)
                }
                return result.sorted { $0.user.id < $1.user.id }
            }
        } catch {
            alert = AppAlert(title: "加载失败", message: error.localizedDescription)
        }
    }
}

/// 关于页。
///
/// 这里集中放版本、致谢、联系方式、开源声明以及本地数据清理入口。
struct AboutSettingsPage: View {
    let onLogout: () -> Void

    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var alert: AppAlert?
    @State private var isResettingLocalData = false
    @State private var isClearingCaches = false
    @State private var isShowingResetConfirmation = false
    @State private var isShowingWidgetUsageGuide = false

    var body: some View {
        List {
            Section("致谢") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。")
                    Link("如果你也想加入，可以点击此处，向开发者发送邮件，以索要L站邀请码。", destination: URL(string: "mailto:systemd@linux.do")!)
                }
                .padding(.vertical, 2)
            }

            Section("联系我们") {
                Link("项目仓库", destination: URL(string: "https://github.com/BIT101-dev/BIT101-iOS")!)
                Link("QQ交流群", destination: URL(string: "https://jq.qq.com/?_wv=1027&k=OTttwrzb")!)
                Link("邮箱", destination: URL(string: "mailto:systemd@linux.do")!)
            }

            Section("关于本 APP") {
                Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                    LabeledContent("ICP备案") {
                        Text(AppLegalInfo.icpDisplayText)
                            .foregroundStyle(.tint)
                    }
                }

                NavigationLink("开源声明") {
                    ScrollView {
                        Text(mitLicenseText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                    .navigationTitle("开源声明")
                }
            }

            Section("提示") {
                Button("重新观看小组件提示") {
                    isShowingWidgetUsageGuide = true
                }
            }

            Section("调试") {
                Button {
                    Task { await clearCaches() }
                } label: {
                    HStack {
                        Text("清理缓存")
                        Spacer()
                        if isClearingCaches {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isClearingCaches || isResettingLocalData)

                Button(role: .destructive) {
                    isShowingResetConfirmation = true
                } label: {
                    HStack {
                        Text("删除所有文稿与数据")
                        Spacer()
                        if isResettingLocalData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isResettingLocalData || isClearingCaches)

                Text("“清理缓存”只会清空临时文件、图片缓存和网络缓存；“删除所有文稿与数据”会清除本地登录信息、设置、课表/DDL缓存、Cookie 和网页数据，并退回登录页。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
        .alert("非常有用的几个用法", isPresented: $isShowingWidgetUsageGuide) {
            Button("知道了") {
                settings.markCurrentWidgetUsageGuideSeen()
            }
        } message: {
            Text("推荐在锁屏添加锁屏小组件（如果你习惯使用息屏显示）。\n桌面小组件也很实用，可以尝试一波。")
        }
        .alert("删除所有文稿与数据", isPresented: $isShowingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await resetAllLocalData() }
            }
        } message: {
            Text("此操作不可撤销。应用将清空本地数据并返回登录页。")
        }
    }

    /// 清空本地所有用户数据，并退回登录页。
    @MainActor
    private func resetAllLocalData() async {
        guard !isResettingLocalData else { return }
        isResettingLocalData = true
        defer { isResettingLocalData = false }

        LoginStorage.shared.clearAllLocalData()
        // 先让根状态机退出主壳层，再执行可能耗时的网页数据清理。否则清掉公告已读标记后，
        // AppShell 仍可能在 clearWebData 等待期间短暂弹出版本公告，随后才被登录页替换。
        onLogout()
        ScheduleCacheStore.clear()
        clearUserDefaults()
        clearFileSystemCaches()
        URLCache.shared.removeAllCachedResponses()
        await clearWebData()
        AppSettingsStore.shared.resetToDefaults()
    }

    /// 清空 bundle 对应的 `UserDefaults` 域。
    @MainActor
    private func clearCaches() async {
        guard !isClearingCaches, !isResettingLocalData else { return }
        isClearingCaches = true
        defer { isClearingCaches = false }

        let manager = FileManager.default
        let cachesURL = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temporaryURL = manager.temporaryDirectory
        let reclaimedBytes = (cachesURL.map { directorySize(at: $0) } ?? 0) + directorySize(at: temporaryURL)

        if let cachesURL {
            deleteContents(of: cachesURL, using: manager)
        }
        deleteContents(of: temporaryURL, using: manager)
        URLCache.shared.removeAllCachedResponses()
        await CachedRemoteImageCacheMaintenance.clearAll()

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        let formatted = formatter.string(fromByteCount: max(reclaimedBytes, 0))
        alert = AppAlert(title: "清理完成", message: "已清理约 \(formatted) 缓存。")
    }

    private func clearUserDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    /// 清空常见本地目录里的缓存与文稿。
    private func clearFileSystemCaches() {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
            .cachesDirectory,
        ]

        for directory in directories {
            guard let url = manager.urls(for: directory, in: .userDomainMask).first else { continue }
            deleteContents(of: url, using: manager)
        }

        deleteContents(of: manager.temporaryDirectory, using: manager)
    }

    /// 删除某个目录下的可见内容。
    private func deleteContents(of directory: URL, using manager: FileManager) {
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            try? manager.removeItem(at: url)
        }
    }

    private func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    /// 清空 `WKWebView` 相关站点数据。
    private func clearWebData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: dataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
