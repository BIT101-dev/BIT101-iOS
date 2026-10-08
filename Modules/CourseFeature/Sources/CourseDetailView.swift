#if os(iOS)
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  CourseDetailView.swift
//  BIT101-iOS
//

import SwiftUI

public struct CourseDetailView: View {
    private let scene: CourseDetailViewScene
    private let identity: [ObjectIdentifier]
    private let resourceID: Int

    public init(dependencies: CourseDependencies, media: MediaEnvironment, profiles: CommunityProfileDestination, initialCourse: CourseSummary) {
        scene = CourseDetailViewScene(dependencies: dependencies, media: media, profiles: profiles, initialCourse: initialCourse)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
        resourceID = initialCourse.id
    }

    public var body: some View {
        scene.id(identity)
            .id(resourceID)
    }
}

private struct CourseDetailViewScene: View {
    private let dependencies: CourseDependencies
    private let destinations: CommunityProfileDestination
    private let media: MediaEnvironment
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    let initialCourse: CourseSummary

    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel: CourseDetailViewModel
    @ObservedObject private var appSettings: CommunityPreferences
    @State private var composerTarget: CourseCommentComposerTarget?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var userRoute: UserRoute?

    init(dependencies: CourseDependencies, media: MediaEnvironment, profiles: CommunityProfileDestination, initialCourse: CourseSummary) {
        self.dependencies = dependencies
        self.media = media
        self.destinations = profiles
        self.initialCourse = initialCourse
        _appSettings = ObservedObject(wrappedValue: dependencies.preferences)
        _viewModel = StateObject(wrappedValue: CourseDetailViewModel(initialCourse: initialCourse, service: dependencies.detail, loadCourseCredits: dependencies.loadCourseCredits))
    }

    var body: some View {
        content.environment(dependencies).environment(media).environment(destinations)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
                summarySection
                metricsSection
                historyGradesSection
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
                        imageViewer = ImagePreviewRequest(remoteImages: images.map(\.previewImage), initialIndex: index)
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
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .padding(.top, AppDesignSystem.Spacing.section)
        }
        .background(AppDesignSystem.Palette.Background.grouped)
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
            destinations.profile(route.userID)
        }
        .task {
            await viewModel.bootstrapIfNeeded()
            await viewModel.loadHistoryGradesIfNeeded()
        }
        .sheet(item: $composerTarget) { target in
            CourseCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous, rate in
                await viewModel.submitComment(text: text, anonymous: anonymous, rate: rate, target: target)
            }
            .id(target.id)
        }
        .systemImagePreview(item: $imageViewer)
        .diagnosticAlert(item: $viewModel.alert)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
                Text(viewModel.resolvedName)
                    .font(AppDesignSystem.Typography.titleEmphasis)
                    .foregroundStyle(AppDesignSystem.Foreground.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    AppDetailCircleButton(accessibilityLabel: "评论课程") {
                        composerTarget = .course(courseID: initialCourse.id)
                    } label: {
                        Image(systemName: "bubble.right")
                            .font(AppDesignSystem.Typography.title)
                            .foregroundStyle(AppDesignSystem.Foreground.primary)
                    }

                    AppDetailCircleButton(
                        accessibilityLabel: viewModel.isCourseLiked ? "取消课程点赞" : "点赞课程"
                    ) {
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
                                    .font(AppDesignSystem.Typography.title)
                            }
                        }
                        .foregroundStyle(viewModel.isCourseLiked ? AppDesignSystem.Course.accent : AppDesignSystem.Foreground.primaryColor)
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
            .font(AppDesignSystem.Typography.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricsSection: some View {
        HStack(spacing: AppDesignSystem.Spacing.section) {
            Text(CourseRatingText.text(from: viewModel.resolvedRate, empty: "暂无评分"))
            Text("\(viewModel.resolvedLikeNum)赞")
            Text("\(viewModel.resolvedCommentNum)评论")
        }
        .font(AppDesignSystem.Typography.subheadline)
        .foregroundStyle(AppDesignSystem.Foreground.secondary)
    }

    @ViewBuilder
    private var historyGradesSection: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
            switch viewModel.historyGradeStatus {
            case .idle, .loading:
                AppInlineLoadingState("正在加载历史成绩")

            case let .failed(message):
                AppFailureState(
                    title: "加载历史成绩失败",
                    systemImage: "chart.line.uptrend.xyaxis",
                    message: message,
                    allowsDiagnostics: viewModel.historyGradesAllowsDiagnostics,
                    onRetry: {
                        Task { await viewModel.reloadHistoryGrades() }
                    }
                )

            case .loaded:
                if viewModel.historyGrades.isEmpty {
                    AppEmptyState(
                        title: "暂无历史成绩",
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                } else {
                    CourseHistoryGradesChart(
                        grades: viewModel.historyGrades,
                        courseNumber: viewModel.resolvedNumber,
                        hidesMakeupOutliers: appSettings.hidesCourseHistoryMakeupOutliers
                    )

                    courseResourceCards
                }
            }
        }
    }

    private var courseResourceCards: some View {
        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.content) {
            Button {
                if let url = viewModel.sharedMaterialsURL {
                    openURL(url)
                } else {
                    viewModel.alert = AppAlert.userInput(title: "无法打开共享资料", message: "课程名称或课程号为空。")
                }
            } label: {
                AppCard(variant: .secondaryGrouped) {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Image(systemName: "folder")
                            .font(AppDesignSystem.Typography.title)
                            .foregroundStyle(AppDesignSystem.Course.accent)
                            .frame(
                                width: AppDesignSystem.Size.Control.detailActionButton,
                                height: AppDesignSystem.Size.Control.detailActionButton
                            )
                            .background(AppDesignSystem.Course.accentSurface, in: Circle())

                        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                            Text("共享资料")
                                .font(AppDesignSystem.Typography.bodyEmphasis)
                                .foregroundStyle(AppDesignSystem.Foreground.primary)
                            Text("在浏览器打开")
                                .font(AppDesignSystem.Typography.caption)
                                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        }

                        Spacer(minLength: AppDesignSystem.Spacing.none)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button {
                appSettings.setHidesCourseHistoryMakeupOutliers(
                    !appSettings.hidesCourseHistoryMakeupOutliers
                )
            } label: {
                AppCard(variant: .secondaryGrouped) {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(AppDesignSystem.Typography.title)
                            .foregroundStyle(AppDesignSystem.Course.accent)
                            .frame(
                                width: AppDesignSystem.Size.Control.detailActionButton,
                                height: AppDesignSystem.Size.Control.detailActionButton
                            )
                            .background(AppDesignSystem.Course.accentSurface, in: Circle())

                        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                            Text("数据清洗")
                                .font(AppDesignSystem.Typography.bodyEmphasis)
                                .foregroundStyle(AppDesignSystem.Foreground.primary)
                            Text(appSettings.hidesCourseHistoryMakeupOutliers ? "隐藏疑似补考" : "全部显示")
                                .font(AppDesignSystem.Typography.caption)
                                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        }

                        Spacer(minLength: AppDesignSystem.Spacing.none)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("数据清洗")
            .accessibilityValue(appSettings.hidesCourseHistoryMakeupOutliers ? "隐藏疑似补考" : "全部显示")
            .appSelectionFeedback(trigger: appSettings.hidesCourseHistoryMakeupOutliers)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 使用稳定的 `/course/{id}` 路由作为课程分享地址。
    private var courseShareURL: URL {
        AppURL.required("https://open.aihelpme.dev/course/\(initialCourse.id)")
    }
}

#endif
