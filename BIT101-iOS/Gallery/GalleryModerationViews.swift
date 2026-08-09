//
//  GalleryModerationViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryReportContext: Identifiable {
    let poster: GalleryPoster
    let action: CommunityReportAction

    var id: String {
        "\(action.rawValue)-\(poster.id)"
    }
}

/// 统一执行“举报后本地先隐藏 / 屏蔽”的治理动作。
///
/// 信息流和帖子详情页的本地治理副作用完全相同，因此集中到同一处，避免两边各自维护一套分支。
func applyGalleryModerationAction(
    _ context: GalleryReportContext,
    type: CommunityReportType,
    note: String,
    settings: AppSettingsStore,
    reportService: CommunityReportService
) {
    switch context.action {
    case .hidePoster:
        settings.hidePoster(
            id: context.poster.id,
            title: context.poster.title,
            userID: context.poster.user.id,
            userNickname: context.poster.user.nickname,
            createdTime: context.poster.createTime
        )
    case .blockUser:
        if context.poster.anonymous || context.poster.user.id == -1 {
            if settings.galleryHiddenUserIDs.first != -1 {
                settings.toggleHideAnonymous()
            }
        } else {
            var hiddenUserIDs = settings.galleryHiddenUserIDs
            if !hiddenUserIDs.contains(context.poster.user.id) {
                hiddenUserIDs.append(context.poster.user.id)
                settings.updateGallerySettings(hiddenUserIDs: hiddenUserIDs)
            }
        }
    }

    reportService.submitReport(for: context.poster, type: type, note: note, action: context.action)
}

/// 帖子卡片右上角的更多操作菜单。
///
/// 举报和删帖都是条件出现的能力，因此统一放在这个菜单里按场景裁剪。
struct GalleryPosterActionMenu: View {
    let onSelectAction: ((CommunityReportAction) -> Void)?
    let onDelete: (() -> Void)?
    @State private var isPresentingFallbackActions = false

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                Menu {
                    menuActions
                } label: {
                    menuLabel
                }
            } else {
                Button {
                    isPresentingFallbackActions = true
                } label: {
                    menuLabel
                }
                .confirmationDialog("", isPresented: $isPresentingFallbackActions, titleVisibility: .hidden) {
                    menuActions
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menuActions: some View {
        if let onSelectAction {
            Button(CommunityReportAction.hidePoster.title, systemImage: "eye.slash") {
                onSelectAction(.hidePoster)
            }

            Button(CommunityReportAction.blockUser.title, systemImage: "person.crop.circle.badge.xmark") {
                onSelectAction(.blockUser)
            }
        }

        if let onDelete {
            Button("删除帖子", systemImage: "trash", role: .destructive) {
                onDelete()
            }
        }
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
    }
}

/// 举报弹层。
///
/// 负责收集举报类型和补充说明，提交后再交给上层执行本地隐藏与异步上报。
struct CommunityReportSheet: View {
    let context: GalleryReportContext
    let onSubmit: (CommunityReportType, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedType = CommunityModeration.reportTypes.last ?? CommunityReportType(id: 7, title: "其他")
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("处理对象") {
                    Text(context.poster.title.isEmpty ? "未命名帖子" : context.poster.title)
                    Text(context.poster.user.nickname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("举报类型") {
                    Picker("类型", selection: $selectedType) {
                        ForEach(CommunityModeration.reportTypes) { type in
                            Text(type.title).tag(type)
                        }
                    }
                }

                Section("补充说明") {
                    TextField("可选，补充你看到的问题", text: $note, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                }

                Section("联系开发者") {
                    Text(CommunitySupport.email)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(context.action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") {
                        onSubmit(selectedType, note.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 搜索输入框。
///
/// 输入框本体、自定义排序按钮和清空按钮都集中在这里，避免搜索页本身承载过多细节。
