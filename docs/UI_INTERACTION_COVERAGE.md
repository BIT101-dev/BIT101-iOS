# UI 交互覆盖

## 验收约定

用户要求 UI 自动化覆盖每一个可点击、可滑动和可交互部位。维护范围按控件与操作语义清点：点击、文本输入与键盘提交、选择与开关、列表滚动与下拉刷新、分区横滑、课表周次拖动、长按菜单、双指缩放、Sheet 下滑关闭，以及确认、取消、成功、失败和重试分支。日期、周次、评分等值域由控件类型与业务状态断言承接。

用例分布在 [日程与社区流程](../BIT101-iOSUITests/LoginAndScheduleUITests.swift) 和 [综合交互流程](../BIT101-iOSUITests/InteractionCoverageUITests.swift)，共 57 项：`LoginAndScheduleUITests` 22 项、`InteractionCoverageUITests` 35 项，共用 `UIAutomationTestCase`。完整批次顺序执行并复用一个 App 进程；每次场景切换与存储重新读取都校验同一进程 ID。同页操作复用创建、导航和编辑过程，下表保留逐控件与业务分支的映射；同一流程可以对应多行。完整交互回归以 5 分钟内完成为优化目标，耗时从真机运行的固定指标文件读取。

## 日程、登录和地图

下表列出完整测试选择参数，例如 `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes`。

| 用例 | 操作与结果 |
| --- | --- |
| `InteractionCoverageUITests/testLoginSubmitButtonAndKeyboardScrollDismissal` | 学号 / 密码、必填禁用、键盘焦点、进入日程；键盘提交由账号退出后重新登录流程验证 |
| `InteractionCoverageUITests/testLoginSubmitButtonAndKeyboardScrollDismissal` | 输入、滚动收键盘、登录按钮提交、进入主界面 |
| `LoginAndScheduleUITests/testMainTabsRemainAccessibleAtAccessibilityDynamicType` | 五个 Tab、离线提示关闭、选中状态 |
| `LoginAndScheduleUITests/testMainTabsRemainAccessibleAtAccessibilityDynamicType` | 浅 / 深色大字号、Tab 点击、主要内容可见与可触达 |
| `InteractionCoverageUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 添加日程、保存、重新装载恢复 |
| `LoginAndScheduleUITests/testCustomSchedulesAreIsolatedBetweenAccounts` | 退出、改账号登录、账号日程隔离 |
| `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` | 上 / 下一周、指定周、课表 / DDL / 空教室横滑与点击 |
| `LoginAndScheduleUITests/testScheduleDayHolidayAndTransferConfirmationCancellation` | 每日表头、放假 / 调休选择、确认取消、窗口取消 |
| `InteractionCoverageUITests/testHolidayAndTransferConfirmedMutations` | 放假确认、调休日期控件、调休确认、原日期和目标日期课程变更 |
| `LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch` | 线性时间轴上下滚动、双指放大 / 缩小、缩放值更新 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` | 时间轴、显示方式、内容选择、周末 / 考试开关、主课表改名与重新装载恢复 |
| `LoginAndScheduleUITests/testCalendarOfflineTermFailureAndCancellation` | 学期入口、学校离线提示、关闭失败提示和返回设置 |
| `InteractionCoverageUITests/testCalendarReminderCloudSwitchesAndLeadTimePersistence` | 两类云开关、提醒确认取消 / 开启、阈值滚轮保存 / 取消、重新装载状态 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` | 时间表非法输入、有效保存、取消保留、课表改名取消 |
| `InteractionCoverageUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` | 学期下拉刷新 / 切换、日期滚轮 / 学校日期、校区 / 教学楼 / 教室刷新、订阅及学校 DDL 刷新 |
| `InteractionCoverageUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 日程详情、编辑保存、删除、新增取消 |
| `InteractionCoverageUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 空标题默认名称、地点 / 描述编辑、详情、单项日历导入 / 移除 |
| `InteractionCoverageUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 日期 / 开始时间 / 结束时间选择器、逐列时间滚轮、线性轴显示任意时间、编辑取消保留 |
| `LoginAndScheduleUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` | 课程名称 / 教师 / 教室 / 周次、星期 / 起止节次、保存、调课入口、删除确认 / 取消 |
| `InteractionCoverageUITests/testCourseAndExamSystemCalendarActions` | 楼宇 / 房间号、周次 / 星期 / 节次多选、单节及整门保存、单节删除确认 / 取消 |
| `InteractionCoverageUITests/testCourseAndExamSystemCalendarActions` | 单节 / 整门 / 考试日历导入与移除、重复移除结果、整学期导入及删除确认 |
| `InteractionCoverageUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation` | 学校课表刷新、短信取消、错误重试、验证继续和课程保存 |
| `LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete` | 分享编码复制、剪贴板粘贴、导入、改名、课表上下滑循环、分享课表左滑删除 |
| `LoginAndScheduleUITests/testLongPressOpensScheduleContextMenuAndImportSheet` | 空白区长按、导入菜单、输入 Sheet |
| `LoginAndScheduleUITests/testImportInvalidCodeReportsErrorAndKeepsEditor` | 无效编码、错误提示、保留输入、取消 |
| `InteractionCoverageUITests/testFutureScheduleImportUpdateCancellationAndLink` | 新版本编码、更新提示取消、App Store 目标地址 |
| `InteractionCoverageUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal` | 空分享取消、导入说明取消、新增 Sheet 下滑关闭 |
| `InteractionCoverageUITests/testScheduleWeekStripScrollAndCourseLongPressShare` | 周次栏拖动、课程长按分享、空白区长按分享、课表系统分享面板 |
| `InteractionCoverageUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing` | 手动待办新增 / 编辑、完成状态、详情、删除、取消 |
| `InteractionCoverageUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing` | 空标题校验、详情输入、日历翻月 / 年月滚轮 / 日期选择、逐列时间滚轮、取消修改 |
| `LoginAndScheduleUITests/testDDLSettingsWheelSaveCancelAndPersistence` | 滞留天数滚轮、保存 / 取消、重新装载恢复 |
| `LoginAndScheduleUITests/testSchoolDDLSourcesAndCompletionPersistAcrossSceneReload` | 两类学校日程、详情来源、完成按钮、重新装载恢复 |
| `LoginAndScheduleUITests/testDDLEmptyStateExplainsTheRetentionWindow` | 过期日程与滞留范围说明 |
| `InteractionCoverageUITests/testSchoolSSODDLVerificationCancelAndContinuation` | 学校 DDL 刷新、SSO 短信取消、验证继续、刷新结果 |
| `InteractionCoverageUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` | 空结果刷新、节次单选、全选 / 全不选、清除筛选与状态 |
| `LoginAndScheduleUITests/testMapCampusLayerPanAndZoomPersist` | 三个校区、图层、地图平移 / 双指缩放、重新装载恢复 |
| `InteractionCoverageUITests/testMapLocationAndScheduleLocationRoute` | 课程地点进入地图、定位 / 单次权限、下一节课导航到 Maps、返回 |

## 成绩与课程

| 用例 | 操作与结果 |
| --- | --- |
| `InteractionCoverageUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 查询、短信输入、验证继续、成绩展示 |
| `InteractionCoverageUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 空 / 错误 / 正确验证码、学期 / 类型全选和清空、六种排序、方向、成绩详情 |
| `InteractionCoverageUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 查询取消、逐项筛选、已有成绩刷新、未出分详情、成绩到课程评价路由 |
| `InteractionCoverageUITests/testTrustedTranscriptSMSRetryPreviewAndCancellation` | 申请、短信取消、申请重试、错误验证重试、两页点击与 Quick Look 左右滑动 / 关闭 |
| `LoginAndScheduleUITests/testCourseSearchHistoryLikeAndRatingComposer` | 课程搜索、详情、历史成绩、课程点赞 / 取消、评分评论发布 |
| `InteractionCoverageUITests/testCourseCommentRepliesRatingsCleaningSearchAndShare` | 清除搜索、数据清洗开关、十种半星评分 / 再选清空、匿名 / 取消、评论点赞 / 图片 / 回复、课程分享 |
| `InteractionCoverageUITests/testCourseHistoryChartSelectionAndHomeSurfaceSwipes` | 成绩 / 课程横滑、历史图双向拖动和学期选中值 |
| `InteractionCoverageUITests/testCourseScheduleAcademicRouteAndPosterAuthorProfile` | 学校课程进入匹配评价、帖子作者及评论昵称进入公开主页 |

## 话廊、文章与消息

| 用例 | 操作与结果 |
| --- | --- |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 五类话题、搜索 / 清除、四类消息 / 全部已读 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 帖子详情、帖子点赞 / 取消、评论发送、编辑入口 |
| `LoginAndScheduleUITests/testGalleryComposerTagsSettingsPublishAndDelete` | 发布校验、草稿保存 / 加载 / 丢弃、标准 / 自定义标签、删除标签、匿名 / 公开、发布、删除确认 / 取消 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 帖子标题 / 正文保存、声明选择、保存后详情和列表同步 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 评论长按复制 / 举报 / 删除、原因输入、提交、删除取消 / 确认 |
| `InteractionCoverageUITests/testPosterReportSelectionCancellationAndSubmission` | 卡片及详情举报、类型选择、取消、说明提交、成功返回 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 评论排序、点赞 / 取消、回复、评论照片选择器取消、文章回复 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题及消息双向横滑、消息关联详情、两类搜索结果进入详情、文章排序 |
| `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval` | 卡片 / 帖子 / 评论图片预览、原有图片移除及取消、新图上传失败 / 重试 / 成功 / 移除、照片选择器取消、建议图片移除 / 放弃草稿 |
| `LoginAndScheduleUITests/testPaperPublishEditCommentAndDelete` | 文章标题 / 简介 / 正文发布、评论发布、编辑保存 / 取消、再编辑、删除确认 / 取消 |
| `LoginAndScheduleUITests/testPaperSearchDetailLikeAndComposer` | 文章搜索 / 清除、详情点赞 / 取消、编辑器字段、匿名开关、取消 |
| `InteractionCoverageUITests/testPaperImagePreviewCommentsSortAndShare` | 正文链接、正文图片预览、页尾点赞及顶部同步、评论排序、文章分享、匿名评论取消 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题及文章搜索排序、搜索刷新、文章列表双向排序横滑 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题 / 文章列表及详情、消息、文章搜索下拉刷新 |
| `InteractionCoverageUITests/testOfflineRecoveryRetryAndErrorReportEditor` | 离线重试、诊断编辑、原始模式、复现 / 联系方式、确认取消 / 确认、提交失败保留、关闭 |
| `InteractionCoverageUITests/testCommunityFailedRequestsRetryToLoadedState` | 课程 / 话题 / 文章首次失败、重试到加载成功 |
| `InteractionCoverageUITests/testErrorReportSanitizedSubmissionAndFailureRecovery` | 报告原始 / 脱敏切换、缺少联系方式继续提交、提交成功关闭、列表重试恢复 |
| `InteractionCoverageUITests/testWebGallerySettingPersistenceScrollingAndNativeReturn` | 网页开关、WebKit 上下滑动、重新装载保留、切回原生列表 |

## 我的、设置与反馈

| 用例 | 操作与结果 |
| --- | --- |
| `InteractionCoverageUITests/testMinePublicProfileFollowAndPostDeletion` | 个人统计入口、用户行进入公开主页、关注成功 |
| `InteractionCoverageUITests/testMinePublicProfileFollowAndPostDeletion` | 粉丝 / 关注 / 帖子列表刷新、公开主页关注状态、头像预览、统计显示 / 刷新、公开帖子详情 / 下滑关闭、个人帖子详情、删除取消 / 确认 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 学号 / UID 显示和隐藏、昵称 / 签名编辑取消、头像选择器取消 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 昵称 / 签名保存及重新加载、登录检查、退出、重新登录 |
| `LoginAndScheduleUITests/testGallerySettingsValidationTogglesAndPersistence` | 机器人 / 匿名 / 网页开关、屏蔽 UID 校验 / 保存 / 重新装载 |
| `LoginAndScheduleUITests/testSuggestionDraftRestoreAndDiscard` | 建议 / 联系方式输入、空提交禁用、草稿保存 / 加载 / 丢弃 |
| `InteractionCoverageUITests/testSuggestionMissingContactConfirmationAndSubmitFailure` | 图片选择器取消、缺少联系信息返回补充 / 继续、提交失败保留、草稿丢弃 |
| `InteractionCoverageUITests/testSuggestionSuccessfulSubmissionAndDiscardSavedDraft` | 草稿放弃加载、提交确认、成功关闭、草稿清理 |
| `InteractionCoverageUITests/testCacheLimitPersistenceClearAndConfirmedReset` | 缓存上限输入 / 重新装载保留、缓存清理、文稿删除确认、返回登录、测试日程清理 |
| `LoginAndScheduleUITests/testAboutLicenseUpdateAndResetConfirmation` | 开源声明滚动、自动更新开关、离线检查提示、重置取消 |
| `InteractionCoverageUITests/testManualUpdatePromptAllActionsAndCurrentVersion` | 新版本本次忽略 / 忽略此版本 / App Store、当前版本提示 |
| `InteractionCoverageUITests/testExternalLinksFromLoginAboutAndCourseResources` | 登录及关于页备案、仓库、QQ、邮件、邀请码、课程共享资料目标 URL |
| `InteractionCoverageUITests/testNetworkDiagnosisProgressAndReport` | 网络诊断触发、八步汇总、结束后恢复按钮 |

## 测试数据与平台动作

| 配置 | 场景 |
| --- | --- |
| `BIT101_UI_TEST_CONTENT=1` | 内存 HTTP 响应，经过生产社区 Service 解码；维护发布、编辑、删除、点赞、评论、关注和资料变更；反馈提交返回合成成功响应 |
| `BIT101_UI_TEST_SCHOOL=1` | 当前周起始日期、学校课程 / 考试、两个学期、两个校区 / 楼宇、空教室和学校 DDL 固定响应 |
| `BIT101_UI_TEST_SCHOOL_SMS=1` | 学校课程和 DDL 的验证码 challenge；`123456` 验证成功，其他输入进入错误分支 |
| `BIT101_UI_TEST_MEDIA=1` | 合成 PNG、帖子 / 评论 / 头像图片、Editor.js 正文图片与链接、带图片的两类草稿；第一次上传失败，第二次成功 |
| `BIT101_UI_TEST_FAILURE_ONCE=1` | 课程、话题和文章首次请求失败，随后重试成功 |
| `BIT101_UI_TEST_UPDATE=new/current` | App Store 查询返回新版本 / 当前版本固定结果 |
| `BIT101_UI_TEST_DDL_FIXTURE=sources/overdue` | 学校双来源 / 滞留范围空状态与持久化 |

所有测试凭据、文件、偏好和媒体缓存归隔离会话与测试目录。系统日历确认通过内存 `SchedulePlatformActions` 验收，偏好云同步使用内存 `PreferenceCloudStoring`。外部链接通过 UI 宿主接收页面实际 URL，并展示完整目标供断言。地图导航仍交给 Maps。测试清理场景使用隔离文件和偏好清理动作。常规 Release 恢复由测试脚本承接。

真机专项范围包括照片库真实选择与读取、系统日历 / 通知授权与实际日历写入、浏览器 / 邮件 / App Store 的系统交接、网页自身交互、Widget 与 Watch 界面。上述范围需要对应设备、系统权限和专项运行证据。

## 执行流程

`Scripts/check-ui-consistency.py` 校验全部可执行方法与覆盖表一致。测试结果、耗时和设备状态保存在固定日志与结果包中。

完整批次串行复用一个 App 进程，每次配置和持久化重新读取都验证同一进程 ID。场景通过测试专用的本机通道更新，重新创建页面及模型，夹具修改按场景清空；各项维持独立的隔离数据重置。UIKit 过渡动画在 UI 宿主加速，手势保留标准 XCTest 实现。取消、保存、重试及全部业务断言继续执行；失败保留截图和元素树。异步错误与成功提示等待预期标题出现，出现、消失和数值变化先检查当前状态。按钮查询先判断存在，避免复合标签的自动查找重试；时间滚轮采用快速短距离拖动、停留释放及原值恢复，图表拖动保留必要的按住时间。

快速开发可将受影响用例通过直接填写多个用例关键词合并到同一次调用；完整验收运行整个 UI 组。真机批次结束后恢复常规 Release App。

照片选择器等待“照片”控件出现后点击顶层取消并确认关闭；返回操作选择当前可交互导航栏。空白多行字段点击首行后输入，短信验证码提交先收起键盘。

真机输入助手在第三方输入法缺少 XCTest 键盘元素时点击系统“下一个键盘”，等待原生键盘后输入并核对完整字段值。场景切换遇到 App 位于后台时激活原进程；运行期间保持 BIT101 前台并暂停手动操作。

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh build ui
Scripts/run-static-audit.sh
```

完整验收要求全部 57 项实际执行并通过。报告记录构建与运行耗时、用例耗时合计、最慢十项、App 启动次数、进程 ID 和系统交互动作。编译使用 `ui-tests-build.log`，运行使用 `ui-tests.log`，结果使用固定 `test-results.xcresult`、`test-metrics.txt` 和按需导出的 `diagnostics/`；真机初始化阻塞与实际用例失败分别记录。
