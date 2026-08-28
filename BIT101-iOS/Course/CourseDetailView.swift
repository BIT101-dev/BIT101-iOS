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
    @ObservedObject private var settings = AppSettingsStore.shared
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
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                metricsSection
                courseResourcesSection
                Divider()

                CourseCommentsSection(
                    comments: filteredComments,
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
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("课程详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: courseShareURL,
                    subject: Text(viewModel.resolvedName)
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享课程")
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
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(viewModel.resolvedName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        composerTarget = .course(courseID: initialCourse.id)
                    } label: {
                        Image(systemName: "bubble.right")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(Color.orange.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
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
                        .foregroundStyle(viewModel.isCourseLiked ? Color.orange : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.orange.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLikingCourse)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
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
        HStack(spacing: 18) {
            Text("\(CourseRatingText.text(from: viewModel.resolvedRate, empty: "暂无评分"))")
            Text("\(viewModel.resolvedLikeNum)赞")
            Text("\(viewModel.resolvedCommentNum)评论")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var courseResourcesSection: some View {
        HStack(spacing: 12) {
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

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: settings.snapshot)
    }

    /// 独立跳转域名使用稳定的 `/course/{id}` 路由；未安装 App 时由 Worker 转至网页。
    private var courseShareURL: URL {
        URL(string: "https://open.aihelpme.dev/course/\(initialCourse.id)")!
    }
}

private struct CourseResourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
