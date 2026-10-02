import StorageCore
import TransportCore
import MediaKit
import DesignSystemKit
import SwiftUI

struct GallerySettingsPage: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let media: MediaEnvironment
    @State private var imageCacheLimitMB: Int
    @State private var imageCacheUsageText = "计算中"
    @State private var imageCacheUsageGeneration = 0
    @State private var hiddenUserIDsText = ""
    @State private var hiddenUserIDsAlert: AppAlert?
    @StateObject private var networkDiagnosis = NetworkDiagnosisRunner()
    @State private var diagnosisAlert: AppAlert?

    init(media: MediaEnvironment) {
        self.media = media
        _imageCacheLimitMB = State(initialValue: media.cacheLimitMB)
    }

    var body: some View {
        List {
            Section {
                Toggle("隐藏机器人帖子", isOn: Binding(
                    get: { settings.galleryHideBotPosterInSearch },
                    set: { settings.updateGallerySettings(hideBotPosterInSearch: $0) }
                ))
                .appSelectionFeedback(trigger: settings.galleryHideBotPosterInSearch)
                .appInteractiveListRow()

                Toggle("隐藏匿名内容", isOn: Binding(
                    get: { settings.galleryHideAnonymousContent },
                    set: { settings.updateGallerySettings(hideAnonymousContent: $0) }
                ))
                .appSelectionFeedback(trigger: settings.galleryHideAnonymousContent)
                .appInteractiveListRow()

                TextField("", text: $hiddenUserIDsText, prompt: AppInputPrompt.text("屏蔽用户 UID（逗号分隔）"))
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit { saveHiddenUserIDs() }
            }

            Section("显示") {
                Toggle("使用网页话廊", isOn: Binding(
                    get: { settings.galleryUseWebView },
                    set: { settings.updateGallerySettings(useWebView: $0) }
                ))
                .appSelectionFeedback(trigger: settings.galleryUseWebView)
                .appInteractiveListRow()
            }

            Section("网络诊断") {
                Button {
                    Task {
                        guard let report = await networkDiagnosis.run() else {
                            diagnosisAlert = AppAlert.informational(
                                title: "网络诊断未完成",
                                message: "请稍后重试。"
                            )
                            return
                        }
                        diagnosisAlert = AppAlert(
                            title: "网络诊断完成",
                            message: report.summary,
                            showsRecoveryLinks: false
                        )
                    }
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("测试网络并生成诊断报告")
                        Spacer()
                        if networkDiagnosis.isRunning {
                            Text("\(networkDiagnosis.completedCount)/\(networkDiagnosis.totalCount)")
                                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        }
                    }
                }
                .disabled(networkDiagnosis.isRunning)
                .appInteractiveListRow()
                if networkDiagnosis.isRunning {
                    ProgressView(
                        value: Double(networkDiagnosis.completedCount),
                        total: Double(networkDiagnosis.totalCount)
                    )
                    .accessibilityLabel("网络诊断进度")
                    .accessibilityValue("\(networkDiagnosis.completedCount)/\(networkDiagnosis.totalCount)")
                }
            }

            Section {
                HStack(spacing: AppDesignSystem.Spacing.content) {
                    TextField("缓存上限", value: $imageCacheLimitMB, format: .number)
                        .keyboardType(.numberPad)
                        .onChange(of: imageCacheLimitMB) { _, newValue in
                            let normalized = MediaEnvironment.normalizedCacheLimitMB(newValue)
                            if normalized != newValue {
                                imageCacheLimitMB = normalized
                                return
                            }
                            media.cacheLimitMB = normalized
                            Task {
                                await media.enforceCurrentLimit()
                                await refreshImageCacheUsage()
                            }
                        }

                    Text("已用缓存 \(imageCacheUsageText)")
                        .font(AppDesignSystem.Typography.subheadline)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        .fixedSize()
                }
            } header: {
                AppListSectionHeader("本地图片缓存上限（MB）")
            }

        }
        .appGroupedListStyle()
        .diagnosticAlert(item: $hiddenUserIDsAlert)
        .diagnosticAlert(item: $diagnosisAlert)
        .task {
            imageCacheLimitMB = media.cacheLimitMB
            hiddenUserIDsText = settings.galleryHiddenUserIDs.map(String.init).joined(separator: ",")
            await refreshImageCacheUsage()
        }
        .onChange(of: settings.galleryHiddenUserIDs) { _, newValue in
            hiddenUserIDsText = newValue.map(String.init).joined(separator: ",")
        }
    }

    private func saveHiddenUserIDs() {
        let tokens = hiddenUserIDsText.split { character in
            character == "," || character == "，" || character.isWhitespace
        }
        let values = tokens.compactMap { Int($0) }
        guard values.count == tokens.count, values.allSatisfy({ $0 > 0 }) else {
            hiddenUserIDsAlert = AppAlert.userInput(
                title: "UID 格式错误",
                message: "请填写正整数 UID，多个 UID 使用逗号分隔。"
            )
            return
        }
        settings.updateGallerySettings(hiddenUserIDs: values)
        hiddenUserIDsText = settings.galleryHiddenUserIDs.map(String.init).joined(separator: ",")
    }

    /// 该方法异步统计话廊图片缓存，并按系统文件大小格式更新设置页。
    private func refreshImageCacheUsage() async {
        imageCacheUsageGeneration &+= 1
        let generation = imageCacheUsageGeneration
        let bytes = await media.usedBytes()
        guard generation == imageCacheUsageGeneration else { return }
        let formatter = ByteCountFormatter()
        imageCacheUsageText = formatter.string(fromByteCount: bytes)
    }

}

/// 关于页显示致谢、联系方式、ICP备案、开源声明和本地数据清理入口。
struct AboutSettingsPage: View {
    let onLogout: () -> Void
    let localData: AppLocalDataService

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var alert: AppAlert?
    @State private var isResettingLocalData = false
    @State private var isClearingCaches = false
    @State private var isShowingResetConfirmation = false
    @State private var isCheckingForUpdates = false

    var body: some View {
        List {
            Section("致谢") {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    Text("特别感谢 LINUX DO（L站）以及佬友们。这个 App 的诞生，离不开他们提供的免费 tokens 与无私的支持。L站倡导“真诚、友善、团结、专业，共建你我引以为荣之社区。”某种意义上，BIT101 也是在这样的氛围里，被一点点推出来的。")
                    Link("如果你也想加入，可以点击此处，向开发者发送邮件，以索要L站邀请码。", destination: AppURL.required("mailto:systemd@linux.do"))
                    .appInteractiveListRow()
                }
                .padding(.vertical, AppDesignSystem.Spacing.micro)
            }

            Section("联系我们") {
                Link("项目仓库", destination: AppURL.required("https://github.com/BIT101-dev/BIT101-iOS"))
                .appInteractiveListRow()
                Link("QQ交流群", destination: AppURL.required("https://jq.qq.com/?_wv=1027&k=OTttwrzb"))
                .appInteractiveListRow()
                Link("邮箱", destination: AppURL.required("mailto:systemd@linux.do"))
                .appInteractiveListRow()
            }

            Section("关于本 APP") {
                Link(destination: AppLegalInfo.icpPublicNoticeURL) {
                    LabeledContent("ICP备案") {
                        Text(AppLegalInfo.icpDisplayText)
                            .foregroundStyle(.tint)
                    }
                }
                .appInteractiveListRow()

                NavigationLink("开源声明") {
                    ScrollView {
                        Text(mitLicenseText)
                            .font(AppDesignSystem.Typography.footnote.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppDesignSystem.Spacing.section)
                            .textSelection(.enabled)
                    }
                    .navigationTitle("开源声明")
                }
                .appInteractiveListRow()
            }

            Section("版本更新") {
                Toggle("自动检查更新", isOn: Binding(
                    get: { settings.automaticUpdateChecksEnabled },
                    set: settings.setAutomaticUpdateChecksEnabled
                ))
                .appSelectionFeedback(trigger: settings.automaticUpdateChecksEnabled)
                .appInteractiveListRow()

                Button {
                    Task { await checkForUpdates() }
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("检查更新")
                        Spacer()
                        if isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isCheckingForUpdates)
                .appInteractiveListRow()
            }

            Section("调试") {
                Button {
                    Task { await clearCaches() }
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("清理缓存")
                        Spacer()
                        if isClearingCaches {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isClearingCaches || isResettingLocalData)
                .appImpactFeedback(trigger: isClearingCaches)
                .appInteractiveListRow()

                Button(role: .destructive) {
                    isShowingResetConfirmation = true
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("删除所有文稿与数据")
                        Spacer()
                        if isResettingLocalData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isResettingLocalData || isClearingCaches)
                .appImpactFeedback(trigger: isResettingLocalData)
                .appInteractiveListRow(isDestructive: true)
            }
        }
        .appGroupedListStyle()
        .diagnosticAlert(item: $alert)
        .alert("删除所有文稿与数据", isPresented: $isShowingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await resetAllLocalData() }
            }
        } message: {
            Text("此操作不可撤销。应用将清空本机数据并返回登录页；已同步到 iCloud 的数据继续保留。")
        }
    }

    @MainActor
    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            switch try await AppUpdatePromptCoordinator.shared.checkManually() {
            case let .update(release):
                AppPromptCoordinator.shared.enqueue(AppPrompt(
                    id: "manual-app-update-\(UUID().uuidString)",
                    title: "发现新版本 \(release.version)",
                    message: release.updateMessage,
                    actions: [
                        AppPromptAction(
                            id: "open-store",
                            title: "前往 App Store",
                            isDefault: true
                        ) {
                            openURL(release.appStoreURL)
                        },
                        AppPromptAction(id: "dismiss", title: "本次忽略") {},
                        AppPromptAction(id: "ignore-version", title: "忽略此版本") {
                            AppUpdatePromptCoordinator.shared.ignore(version: release.version)
                        }
                    ],
                    onPresent: {
                        AppUpdatePromptCoordinator.shared.markPresented(version: release.version)
                    }
                ))
            case .current:
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                alert = AppAlert(
                    title: "已是最新版本",
                    message: "当前版本：\(version) (\(build))"
                )
            }
        } catch {
            alert = AppAlert(title: "检查更新失败", message: error.localizedDescription)
        }
    }

    @MainActor
    private func resetAllLocalData() async {
        guard !isResettingLocalData else { return }
        isResettingLocalData = true
        defer { isResettingLocalData = false }
        let succeeded = await localData.resetAllLocalData(onLogout: onLogout)
        if !succeeded {
            AppErrorPresenter.shared.present(AppAlert.informational(
                title: "本机数据清理部分完成",
                message: "部分本机数据仍待清理，可稍后重试。"
            ))
        }
    }

    @MainActor
    private func clearCaches() async {
        guard !isClearingCaches, !isResettingLocalData else { return }
        isClearingCaches = true
        defer { isClearingCaches = false }
        let result = await localData.clearCaches()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        let formatted = formatter.string(fromByteCount: max(result.reclaimedBytes, 0))
        alert = AppAlert.informational(
            title: result.succeeded ? "清理完成" : "清理部分完成",
            message: result.succeeded
                ? "已清理约 \(formatted) 缓存。"
                : "已清理约 \(formatted) 缓存，部分文件仍在使用中。"
        )
    }
}
