//
//  GalleryMessagesView.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryMessagesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: GalleryMessageViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var networkObserver = GalleryNetworkObserver()
    @State private var selectedPoster: GalleryPoster?
    @State private var localAlert: AppAlert?
    private let service = GalleryService()

    var body: some View {
        ZStack {
            AppDesignSystem.Palette.groupedBackground
                .ignoresSafeArea()

            Group {
                if isInitialLoading {
                    AppLoadingState(title: "正在加载消息")
                } else if case let .failed(message) = currentState.status, currentState.items.isEmpty {
                    AppFailureState(
                        title: "加载消息失败",
                        systemImage: "bell.badge",
                        message: message,
                        onRetry: {
                            Task {
                                await viewModel.refreshSelectedType()
                            }
                        }
                    )
                } else {
                    List {
                        if currentState.items.isEmpty {
                            AppEmptyState(
                                title: "暂无消息",
                                systemImage: "bell",
                                message: "当前分类还没有可展示的消息。"
                            )
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(Array(currentState.items.enumerated()), id: \.element.id) { index, message in
                                VStack(spacing: 0) {
                                    GalleryMessageRow(
                                        type: viewModel.selectedType,
                                        message: message,
                                        isUnread: viewModel.isUnread(message, in: viewModel.selectedType),
                                        onOpenPoster: {
                                            Task {
                                                await openMessage(message)
                                            }
                                        }
                                    )

                                    if index != currentState.items.count - 1 {
                                        Divider()
                                            .padding(.leading, AppDesignSystem.Size.content.messageDividerLeading)
                                    }
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .onAppear {
                                    Task {
                                        await viewModel.loadMoreIfNeeded(for: viewModel.selectedType, currentMessage: message)
                                    }
                                }
                            }

                            if currentState.isLoadingMore {
                                AppInlineLoadingState()
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await viewModel.refreshSelectedType()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(messageSwitchGesture)
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    viewModel.markCurrentTypeAsRead()
                }
                .disabled(!viewModel.hasUnreadInCurrentType)
            }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(title: "消息分类", selection: $viewModel.selectedType) {
                ForEach(GalleryMessageType.allCases) { type in
                    Text(title(for: type)).tag(type)
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: networkObserver.isReachable) { oldValue, newValue in
            guard newValue, !oldValue else { return }
            Task {
                await retryCurrentTypeIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await retryCurrentTypeIfNeeded()
            }
        }
        .onChange(of: viewModel.selectedType) { _, newType in
            if viewModel.state(for: newType).status == .idle {
                Task {
                    await viewModel.refresh(type: newType)
                }
            }
        }
        .navigationDestination(item: $selectedPoster) { poster in
            GalleryPosterDetailView(poster: poster)
        }
        .diagnosticAlert(item: $viewModel.alert)
        .diagnosticAlert(item: $localAlert)
    }

    private var currentState: GalleryMessageListState {
        viewModel.state(for: viewModel.selectedType)
    }

    /// 网络恢复或回到前台时，当前消息分类处于失败状态且消息为空时自动刷新一次。
    private func retryCurrentTypeIfNeeded() async {
        guard networkObserver.isReachable else { return }
        let state = currentState
        guard case .failed = state.status, state.items.isEmpty else { return }
        await viewModel.refreshSelectedType()
    }

    private var isInitialLoading: Bool {
        switch currentState.status {
        case .idle, .loading:
            return currentState.items.isEmpty
        default:
            return false
        }
    }

    /// 消息分类左右切换手势。
    private var messageSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchType)
    }

    /// 顶部分段标题；有未读时在标题右侧追加计数。
    private func title(for type: GalleryMessageType) -> String {
        let unread = viewModel.unreadCount(for: type)
        guard unread > 0 else { return type.title }
        return unread > 99 ? "\(type.title) 99+" : "\(type.title) \(unread)"
    }

    /// 把消息分类切换到相邻页签。
    private func switchType(step: Int) {
        let allTypes = GalleryMessageType.allCases
        guard let currentIndex = allTypes.firstIndex(of: viewModel.selectedType) else { return }

        let nextIndex = currentIndex + step
        guard allTypes.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut) {
            viewModel.selectedType = allTypes[nextIndex]
        }
    }

    /// 打开单条消息。
    ///
    /// 服务端返回的消息对象可能关联已删除帖子，因此先请求帖子详情。
    /// 帖子已删除时显示本地提示，避免进入“对象不存在”的错误页。
    private func openMessage(_ message: GalleryMessage) async {
        viewModel.markMessageAsRead(message, in: viewModel.selectedType)

        guard let posterID = message.linkedPosterID else { return }

        do {
            let poster = try await service.fetchPoster(id: posterID)
            selectedPoster = poster.asPoster
        } catch {
            if TaskCancellation.matches(error) {
                return
            }
            localAlert = AppAlert(title: "无法打开", message: "相关帖子不存在或已删除。")
        }
    }
}

/// 单条消息行。
///
/// 新消息样式使用本地伪未读：客户端根据服务端分类未读数标记最新前 N 条。
/// 系统通知和服务端逐条 read 字段均不参与这项样式。
private struct GalleryMessageRow: View {
    let type: GalleryMessageType
    let message: GalleryMessage
    let isUnread: Bool
    let onOpenPoster: () -> Void

    private var canOpenPoster: Bool {
        message.linkedPosterID != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
            GalleryMessageAvatarView(user: message.fromUser, type: type)

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: AppDesignSystem.Spacing.regular) {
                    if isUnread {
                        Circle()
                            .fill(AppDesignSystem.Palette.highlight)
                            .frame(width: AppDesignSystem.Size.content.unreadIndicator, height: AppDesignSystem.Size.content.unreadIndicator)
                    }

                    Text(message.fromUser.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(AppDateText.relativeText(from: message.updateTime, fallback: "未知时间"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(type.actionText(for: message))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if canOpenPoster {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, AppDesignSystem.Spacing.micro)
            }
        }
        .padding(.horizontal, AppDesignSystem.Spacing.container)
        .padding(.vertical, AppDesignSystem.Spacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUnread ? AppDesignSystem.Palette.highlightSurface : AppDesignSystem.Palette.systemBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpenPoster else { return }
            onOpenPoster()
        }
    }
}

/// 消息头像。
///
/// 系统消息使用消息类型对应的语义图标作为头像回退。
private struct GalleryMessageAvatarView: View {
    let user: GalleryMessageUser
    let type: GalleryMessageType

    var body: some View {
        if user.id == 0 {
            AppAvatarView(
                imageURL: nil,
                size: AppDesignSystem.Comment.layout.avatarSize,
                systemImage: type == .system ? "bell.fill" : "person.fill"
            )
        } else {
            AppAvatarView(imageURL: user.avatar.preferredURL)
        }
    }
}
