//
//  CourseDetailView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Charts
import SwiftUI

/// 课程详情页。
struct CourseDetailView: View {
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    let initialCourse: CourseSummary

    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel: CourseDetailViewModel
    @State private var composerTarget: CourseCommentComposerTarget?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var userRoute: UserRoute?
    @State private var isShowingHistoryGrades = false

    init(initialCourse: CourseSummary) {
        self.initialCourse = initialCourse
        _viewModel = StateObject(wrappedValue: CourseDetailViewModel(initialCourse: initialCourse))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.prominent) {
                summarySection
                metricsSection
                courseResourcesSection
                Divider()

                CourseCommentsSection(
                            comments: viewModel.commentState.items,
                    totalCommentCount: viewModel.resolvedCommentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        Task {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    }
                )
            }
            .padding(.horizontal, AppDesignSystem.Spacing.prominent)
            .padding(.top, AppDesignSystem.Spacing.prominent)
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .navigationTitle("课程详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AppDetailShareLink(
                    item: courseShareURL,
                    subject: viewModel.resolvedName,
                    accessibilityLabel: "分享课程"
                )
            }
        }
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .sheet(item: $composerTarget) { target in
            CourseCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous, rate in
                Task {
                    let success = await viewModel.submitComment(text: text, anonymous: anonymous, rate: rate, target: target)
                    if success {
                        composerTarget = nil
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingHistoryGrades) {
            CourseHistoryGradesSheet(
                grades: viewModel.historyGrades,
                status: viewModel.historyGradeStatus,
                onRetry: {
                    await viewModel.reloadHistoryGrades()
                }
            )
            .task {
                await viewModel.loadHistoryGradesIfNeeded()
            }
        }
        .gallerySystemImagePreview(item: $imageViewer)
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
                Text(viewModel.resolvedName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppDesignSystem.Spacing.control) {
                    AppDetailCircleButton {
                        composerTarget = .course(courseID: initialCourse.id)
                    } label: {
                        Image(systemName: "bubble.right")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }

                    AppDetailCircleButton {
                        Task {
                            await viewModel.likeCourse()
                        }
                    } label: {
                        Group {
                            if viewModel.isLikingCourse {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: viewModel.isCourseLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .font(.headline)
                            }
                        }
                        .foregroundStyle(viewModel.isCourseLiked ? AppDesignSystem.Palette.highlight : Color.primary)
                    }
                    .disabled(viewModel.isLikingCourse)
                }
            }

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                LabeledContent("课程号", value: viewModel.resolvedNumber)
                LabeledContent("学分", value: viewModel.resolvedCreditText)
                LabeledContent("教师", value: viewModel.resolvedTeachersName.isEmpty ? "-" : viewModel.resolvedTeachersName)
                LabeledContent("教师号", value: viewModel.resolvedTeachersNumber.isEmpty ? "-" : viewModel.resolvedTeachersNumber)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricsSection: some View {
        HStack(spacing: AppDesignSystem.Spacing.prominent) {
            Text("\(CourseRatingText.text(from: viewModel.resolvedRate, empty: "暂无评分"))")
            Text("\(viewModel.resolvedLikeNum)赞")
            Text("\(viewModel.resolvedCommentNum)评论")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var courseResourcesSection: some View {
        HStack(spacing: AppDesignSystem.Spacing.content) {
            Button {
                if let url = viewModel.sharedMaterialsURL {
                    openURL(url)
                } else {
                    viewModel.alert = AppAlert(title: "无法打开共享资料", message: "课程名称或课程号为空。")
                }
            } label: {
                CourseResourceCard(
                    title: "共享资料",
                    subtitle: "在浏览器打开",
                    systemImage: "folder"
                )
            }
            .buttonStyle(.plain)

            Button {
                isShowingHistoryGrades = true
            } label: {
                CourseResourceCard(
                    title: "历史成绩",
                    subtitle: "查看历年统计",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// 独立跳转域名使用稳定的 `/course/{id}` 路由；未安装 App 时由 Worker 转至网页。
    private var courseShareURL: URL {
        AppURL.required("https://open.aihelpme.dev/course/\(initialCourse.id)")
    }
}

private struct CourseResourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        AppCard(variant: .secondaryGrouped) {
            HStack(spacing: AppDesignSystem.Spacing.control) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
                    .frame(
                        width: AppDesignSystem.Size.control.detailActionButton,
                        height: AppDesignSystem.Size.control.detailActionButton
                    )
                    .background(AppDesignSystem.Palette.highlightSurface, in: Circle())

                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
