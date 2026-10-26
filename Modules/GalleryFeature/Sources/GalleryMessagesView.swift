#if os(iOS)
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  GalleryMessagesView.swift
//  BIT101-iOS
//
//

import SwiftUI

struct GalleryMessagesView: View {
    let papers: CommunityPaperDestination
    let courses: CommunityCourseDestination
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(GalleryDependencies.self) private var dependencies
    @Environment(MediaEnvironment.self) private var media
    @Environment(CommunityProfileDestination.self) private var profiles
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: GalleryMessageViewModel
    @Environment(\.dismiss) private var dismiss
    private var networkObserver: NetworkPathState { dependencies.networkPath }
    @State private var requestedMessage: GalleryMessage?
    @State private var showsReadRecoveryConfirmation = false
    @State private var readRecovery: (@MainActor () async -> Void)?

    var body: some View {
        let type = viewModel.selectedType
        let state = viewModel.state(for: type)
        ZStack {
            AppDesignSystem.Palette.Background.grouped
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
                            viewModel.pendingOperations.enqueue {
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
                                VStack(spacing: AppDesignSystem.Spacing.none) {
                                    GalleryMessageRow(
                                        type: type,
                                        message: message,
                                        isUnread: viewModel.isUnread(message, in: type),
                                        onOpenResource: {
                                            requestedMessage = message
                                        }
                                    )

                                    if index != currentState.items.count - 1 {
                                        Divider()
                                            .padding(.leading, AppDesignSystem.Gallery.messageDividerLeading)
                                    }
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .task(id: viewModel.paginationTaskID(for: type)) {
                                    await viewModel.loadMoreIfNeeded(for: type, currentMessage: message)
                                }
                            }

                            CommunityPaginationFooter(isLoading: currentState.isLoadingMore, errorMessage: currentState.paginationError) {
                                await viewModel.loadMoreIfNeeded(for: type, currentMessage: state.items.last)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .accessibilityIdentifier("interaction.GalleryMessagesView.list")
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                    interactionEvidence?("interaction.GalleryMessagesView.refreshable", "refresh")

                        await viewModel.refreshSelectedType()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(messageSwitchGesture)
        .accessibilityIdentifier("gallery.message-surface")
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
                    .accessibilityIdentifier("ui.gallery-messages-view.cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    viewModel.pendingOperations.enqueue { await viewModel.markCurrentTypeAsRead() }
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
        .task(id: viewModel.selectedType) {
            if currentState.status == .idle { await viewModel.bootstrapIfNeeded() }
            else { await viewModel.retrySelectedTypeIfNeeded() }
        }
        .onChange(of: networkObserver.snapshot.status) { _, newValue in
            guard newValue == .connected else { return }
            viewModel.pendingOperations.enqueue {
                await retryCurrentTypeIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.pendingOperations.enqueue {
                await retryCurrentTypeIfNeeded()
            }
        }
        .onChange(of: viewModel.selectedType) { _, _ in
            requestedMessage = nil
            viewModel.pendingOperations.cancel()
        }
        .onDisappear { viewModel.pendingOperations.cancel() }
        .task(id: requestedMessage) {
            guard let message = requestedMessage else { return }
            await viewModel.openMessage(message, in: viewModel.selectedType, using: dependencies.posterDetail)
            if requestedMessage == message { requestedMessage = nil }
        }
        .navigationDestination(item: $viewModel.destination) { destination in
            switch destination {
            case let .poster(poster):
                GalleryPosterDetailView(dependencies: dependencies, media: media, profiles: profiles, poster: poster.asPoster, initialDetail: poster)
            case let .paper(id): papers.detail(id)
            case let .course(id): courses.course(id)
            }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            if viewModel.needsReadStateRecovery {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
                    Text("消息已读记录需要恢复").font(AppDesignSystem.Typography.title)
                    Text("当前消息继续展示。请重试读取，或确认恢复本机已读记录。")
                    Button("重试读取") { viewModel.pendingOperations.enqueue { await viewModel.refreshSelectedType() } }
                        .accessibilityIdentifier("messages.storage.retry")
                    Button("恢复已读状态") {
                        readRecovery = viewModel.readStateRecoveryAction()
                        showsReadRecoveryConfirmation = true
                    }
                    .accessibilityIdentifier("messages.storage.recover")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRecoveringReadState)
                .padding(AppDesignSystem.Spacing.content)
                .background(AppDesignSystem.Palette.Background.grouped)
            }
        }
        .alert("恢复消息已读状态？", isPresented: $showsReadRecoveryConfirmation) {
            Button("恢复已读状态", role: .destructive) { viewModel.pendingOperations.enqueue { await readRecovery?() } }
                .accessibilityIdentifier("messages.storage.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前账号的本机已读记录将重新建立，部分消息可能再次显示为未读。消息内容与其他资料继续保留。")
        }
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var currentState: GalleryMessageListState {
        viewModel.state(for: viewModel.selectedType)
    }

    /// 网络恢复或回到前台时，继续当前分类的失败读取。
    private func retryCurrentTypeIfNeeded() async {
        guard networkObserver.isReachable else { return }
        await viewModel.retrySelectedTypeIfNeeded()
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

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedType = allTypes[nextIndex]
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
    let onOpenResource: () -> Void

    private var canOpenResource: Bool {
        message.linkedResource != nil
    }

    var body: some View {
        Button(action: onOpenResource) {
            HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
                GalleryMessageAvatarView(user: message.fromUser, type: type)

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                    HStack(alignment: .firstTextBaseline, spacing: AppDesignSystem.Spacing.regular) {
                        if isUnread {
                            Circle()
                                .fill(AppDesignSystem.Palette.Accent.primary)
                                .frame(width: AppDesignSystem.Gallery.unreadIndicator, height: AppDesignSystem.Gallery.unreadIndicator)
                        }

                        Text(message.fromUser.displayName)
                            .font(AppDesignSystem.Typography.bodyEmphasis)
                            .foregroundStyle(AppDesignSystem.Foreground.primary)
                            .lineLimit(1)

                        Spacer(minLength: AppDesignSystem.Spacing.none)

                        Text(AppDateText.relativeText(from: message.updateTime, fallback: "未知时间"))
                            .font(AppDesignSystem.Typography.caption)
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    }

                    Text(type.actionText(for: message))
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(AppDesignSystem.Foreground.primary)

                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(AppDesignSystem.Typography.body)
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if canOpenResource {
                    Image(systemName: "chevron.right")
                        .font(AppDesignSystem.Typography.captionEmphasis)
                        .foregroundStyle(AppDesignSystem.Foreground.tertiary)
                        .padding(.top, AppDesignSystem.Spacing.micro)
                }
            }
            .padding(.horizontal, AppDesignSystem.Spacing.content)
            .padding(.vertical, AppDesignSystem.Spacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUnread ? AppDesignSystem.Palette.Accent.surface : AppDesignSystem.Palette.Background.system)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(canOpenResource ? "打开关联\(message.resourceTitle)" : "标记为已读")
        .accessibilityIdentifier("gallery.message.\(message.id)")
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
                size: AppDesignSystem.Size.Avatar.standard,
                systemImage: type == .system ? "bell.fill" : "person.fill"
            )
        } else {
            AppAvatarView(imageURL: user.avatar.preferredURL, fallbackImageURL: user.avatar.originalURL)
        }
    }
}

#endif
