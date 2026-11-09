#if os(iOS)
import SwiftUI
import OSLog
import UIKit

/// 原生内容在目标窗口及尺寸就绪后直接交接，保留已完成的布局和渲染状态。
open class AppPreparedViewHost<Content: UIView>: UIView {
    public let content: Content
    public var onWillMount: (() -> Void)?
    public var onFirstMount: (() -> Void)?
    public private(set) var isContentMounted = false

    public init(content: Content) {
        self.content = content
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public final override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfReady()
    }

    public final override func layoutSubviews() {
        super.layoutSubviews()
        attachIfReady()
        if content.superview === self, content.frame != bounds { content.frame = bounds }
    }

    private func attachIfReady() {
        guard window != nil, !bounds.isEmpty else { return }
        let willMount = onWillMount
        onWillMount = nil
        willMount?()
        if content.superview !== self {
            content.frame = bounds
            addSubview(content)
        }
        if !isContentMounted {
            isContentMounted = true
            let action = onFirstMount
            onFirstMount = nil
            action?()
        }
    }
}

/// 首次显示时构建内容，后续保留实例；呈现动画由页面容器统一负责。
@MainActor
public final class AppPageLifetime {
    private var hasShown = false

    public init() {}

    public func retainIfVisible(_ isVisible: Bool) -> Bool {
        hasShown = hasShown || isVisible
        return hasShown
    }
}

@MainActor
public final class AppPageLoadMeasurement {
    private static let logger = Logger(subsystem: "BIT101", category: "PagePerformance")
    private let started = ProcessInfo.processInfo.systemUptime
    private var recorded: Set<String> = []

    public init() {}

    public var elapsedDuration: Double {
        ProcessInfo.processInfo.systemUptime - started
    }

    @discardableResult
    public func record(
        _ page: String, stage: String, count: Int = 0, duration: Double? = nil
    ) -> Double? {
        guard recorded.insert(stage).inserted else { return nil }
        let duration = duration ?? ProcessInfo.processInfo.systemUptime - started
        Self.logger.info(
            """
            page=\(page, privacy: .public) stage=\(stage, privacy: .public) \
            seconds=\(duration) items=\(count)
            """)
        return duration
    }
}

private struct AppPageLoadObserverKey: EnvironmentKey {
    static let defaultValue: ((String, String, Double, Int) -> Void)? = nil
}

extension EnvironmentValues {
    public var appPageLoadObserver: ((String, String, Double, Int) -> Void)? {
        get { self[AppPageLoadObserverKey.self] }
        set { self[AppPageLoadObserverKey.self] = newValue }
    }
}

private struct AppFirstContentModifier: ViewModifier {
    let page: String
    let count: Int?
    @State private var measurement = AppPageLoadMeasurement()
    @Environment(\.appPageIsVisible) private var isVisible
    @Environment(\.appPageLoadObserver) private var observer

    func body(content: Content) -> some View {
        content
            .onAppear { record() }
            .onChange(of: count) { record() }
            .onChange(of: isVisible) { record() }
    }

    private func record() {
        guard isVisible else { return }
        report(stage: "appear", count: 0)
        if let count { report(stage: "content-ready", count: count) }
    }

    private func report(stage: String, count: Int) {
        if let duration = measurement.record(page, stage: stage, count: count) {
            observer?(page, stage, duration, count)
        }
    }
}

extension View {
    public func appFirstContent(_ page: String, count: Int?) -> some View {
        modifier(AppFirstContentModifier(page: page, count: count))
    }
}

public typealias AppFailureRecoveryActionsBuilder = (String, String, Bool, (any Error)?) ->
    AnyView

private struct AppFailureRecoveryActionsKey: EnvironmentKey {
    static let defaultValue: AppFailureRecoveryActionsBuilder? = nil
}

extension EnvironmentValues {
    public var appFailureRecoveryActions: AppFailureRecoveryActionsBuilder? {
        get { self[AppFailureRecoveryActionsKey.self] }
        set { self[AppFailureRecoveryActionsKey.self] = newValue }
    }
}

/// 交互回调的执行观察器，由宿主按需注入。
private struct AppInteractionEvidenceKey: EnvironmentKey {
    static let defaultValue: ((String, String) -> Void)? = nil
}

extension EnvironmentValues {
    public var appInteractionEvidence: ((String, String) -> Void)? {
        get { self[AppInteractionEvidenceKey.self] }
        set { self[AppInteractionEvidenceKey.self] = newValue }
    }
}

/// AppLoadingState 为页面级首屏加载状态提供统一的进度样式和可用空间约束。
public struct AppLoadingState: View {
    public init(title: String) {
        self.title = title
    }

    let title: String

    public var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped)
    }
}

/// AppInlineLoadingState 为列表分区和滚动内容提供统一的加载状态与居中布局。
public struct AppInlineLoadingState: View {
    let title: String?

    public init(_ title: String? = nil) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Spacer()
            if let title {
                ProgressView(title)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding(.vertical, AppDesignSystem.Spacing.content)
        .listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped)
    }
}

/// AppScrollStateContainer 通过容器提供的垂直空间居中呈现滚动页首屏状态，并适配不同设备的可用高度。
public struct AppScrollStateContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack {
            Spacer(minLength: AppDesignSystem.Spacing.none)
            content
            Spacer(minLength: AppDesignSystem.Spacing.none)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }
}

/// AppFailureState 统一提供加载失败状态、重试与宿主恢复入口。
public struct AppFailureState: View {
    let title: String
    let systemImage: String
    let message: String
    let retryTitle: String
    let onRetry: (() -> Void)?
    let allowsDiagnostics: Bool
    let underlyingError: (any Error)?
    @Environment(\.appFailureRecoveryActions) private var appFailureRecoveryActions

    public init(
        title: String,
        systemImage: String,
        message: String,
        retryTitle: String = "重试",
        allowsDiagnostics: Bool = true,
        underlyingError: (any Error)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.retryTitle = retryTitle
        self.onRetry = onRetry
        self.allowsDiagnostics = allowsDiagnostics
        self.underlyingError = underlyingError
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let onRetry {
                Button(retryTitle, action: onRetry)
                    .accessibilityIdentifier("ui.app-failure-state.retry")
            }
            if let appFailureRecoveryActions {
                appFailureRecoveryActions(title, message, allowsDiagnostics, underlyingError)
            }
        }
        .buttonStyle(.borderless)
        .listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped)
    }
}

/// AppEmptyState 统一提供无数据状态的图标、说明和可选操作入口。
public struct AppEmptyState: View {
    let title: String
    let systemImage: String
    let message: String?
    let actionTitle: String?
    let onAction: (() -> Void)?

    public init(
        title: String,
        systemImage: String,
        message: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let onAction, let actionTitle {
                Button(actionTitle, action: onAction)
                    .accessibilityIdentifier("ui.app-empty-state.action")
            }
        }
        .listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped)
    }
}
#endif
