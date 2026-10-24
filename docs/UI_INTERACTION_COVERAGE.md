# UI 交互覆盖

## 验收约定

用户要求 UI 自动化覆盖每一个可点击、可滑动和可交互部位。维护范围按控件与操作语义清点：点击、文本输入与键盘提交、选择与开关、列表滚动与下拉刷新、分区横滑、课表周次拖动、长按菜单、双指缩放、Sheet 下滑关闭，以及确认、取消、成功、失败和重试分支。日期、周次、评分等值域由控件类型与业务状态断言承接。

用例分布在 [日程与社区流程](../BIT101-iOSUITests/LoginAndScheduleUITests.swift) 、[社区发布流程](../BIT101-iOSUITests/CommunityPublishingUITests.swift) 和 [综合交互流程](../BIT101-iOSUITests/InteractionCoverageUITests.swift)，共用 `UIAutomationTestCase`；[性能场景](../BIT101-iOSUITests/MaintenancePerformanceUITests.swift) 独立测量 App 启动与切周布局。完整批次顺序执行，常规场景复用 App 进程并校验同一进程 ID；话廊偏好、学校 DDL 完成状态和自定义日程场景结束旧进程，以新进程恢复会话和磁盘数据。同页操作复用创建、导航和编辑过程，下表保留逐控件与业务分支的映射；同一流程可以对应多行。业务交互采用原生触摸与滚动，字段沿实际输入控件更新，公共键盘合同采用系统键盘；公共查询合同显式验收快速查询及控件动作与原生状态的一致性。运行耗时与操作类型从真机运行的固定指标文件读取。

## 公共组件验收归属

公共组件的每类交互合同明确验收流程，相同交互集中验证一次；每个使用页面验证入口、绑定参数和业务结果。同一控件的布局或事件实现独立时，各自保留完整验收。测试归属静态明确，关键词运行直接执行所选流程。

| 公共实现 | 完整交互合同 | 页面接入验证 |
| --- | --- | --- |
| `AppSMSVerificationSheet` | 成绩流程验证空提交禁用、系统键盘逐位输入及手动验证、整段填入自动验证、错误提示、修改重试、取消和成功；验证码清洗、长度边界及自动提交策略由模块测试覆盖 | 课表、学校 DDL 和可信成绩单验证各自取消后的恢复、提交文案及自动验证后业务继续；课表与成绩单的错误保留 challenge、修改后继续和持久化由行为测试验收；SSO 面板复用同一输入实现 |
| `ScoreFilterPage` | 学期筛选验证全选 / 清空和逐项切换 | 学期及类型分别验证绑定状态和成绩过滤结果 |
| `CommunityCommentSortPicker` | 话题评论验证最新 / 高赞 / 最旧全部选项 | 文章评论验证排序入口、选择绑定及加载结果 |
| `CommunityPaginationFooter` | 机器人分页验证继续加载，分页恢复验证失败原因、原位重试和后续内容 | 话题、文章、课程及评论保留各自分页游标和列表内容 |
| 确认框控件查询 | 公共查询合同与原生 XCTest 比较控件属性，并通过真实点击验证关闭后恢复 | 各页面保留自身确认 / 取消与业务结果 |
| 原生日期时间选择器 | DDL 流程验证翻月、年月选择、日期选择及逐列时间滚轮 | 自定义日程逐个打开日期 / 开始 / 结束入口，验证时间绑定、保存和重新读取 |
| `AppCommentComposerContentSection` | 课程评论验证匿名开关，并与评分和发布结果一起验收 | 话题及文章保留各自评论 / 回复提交和取消；匿名发布属于各自编辑器合同 |
| `KeyboardDismissSupport` | 课程评论通过系统键盘输入并实际点击完成按钮，登录验证空白点按、滚动收起及键盘提交 | 各页面验证完整字段值、实际控件绑定及业务结果 |
| `systemImagePreview` | 可信成绩单验证多页切换和关闭，话题流程验证打开预览时的场景销毁 | 卡片、正文、评论、头像和成绩单第二页分别验证来源入口及返回页面 |

文章搜索、点赞、发布和编辑分别归入已有连续页面流程；课程搜索、点赞、评分、发布与回复在同一详情中连续验收。文本表单通过实际输入控件连续填写，公共键盘合同集中验证聚焦、输入与收起，重新读取后的设置状态完成断言后交由下一场景的隔离重置清理。

UIKit 控件沿构造类型、继承或别名进入源码清单，运行门禁核对输入、滚动、手势与菜单回调的实际证据。静态辅助功能标识沿对应变量或原生控件类型解析；目标动作和菜单闭包沿现有交互观察器记录实际执行。只读富文本核对正文点按及链接动作，滚动载体与其原生手势分别核对动作类型。

完整覆盖以源码控件、动作类型和归属用例为单位，每项对应已观察实例上的实际动作。同一原生控件的无障碍包装沿相同标识及几何合并，祖先行保留业务身份。挂载库存记录各次弹窗、日期值和禁用状态的观察与待访问项，供定位覆盖缺口；值域与互斥分支由所属行为断言和公共组件合同验收。

## 日程、登录和地图

下表列出完整测试选择参数，例如 `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes`。

| 用例 | 操作与结果 |
| --- | --- |
| `ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract` | 实时查询与原生 XCTest 比较标识、类型、禁用状态、可触达状态和布局；原生点击 / 无障碍激活后的状态一致，真实触摸聚焦、聚焦前后字段绑定、键盘完成、导航返回、确认框控件、场景标识 / 窗口坐标与取消恢复 |
| `AccountRecoveryUITests/testLoginSubmitButtonAndKeyboardScrollDismissal` | 学号 / 密码、必填禁用、键盘焦点、进入日程；键盘提交由账号退出后重新登录流程验证 |
| `AccountRecoveryUITests/testLoginSubmitButtonAndKeyboardScrollDismissal` | 输入、滚动收键盘、登录按钮提交、进入主界面 |
| `ScheduleEditingUITests/testMainTabsRemainAccessibleAtAccessibilityDynamicType` | 五个 Tab、离线提示关闭、选中状态 |
| `ScheduleEditingUITests/testMainTabsRemainAccessibleAtAccessibilityDynamicType` | 浅 / 深色大字号、Tab 点击、主要内容可见与可触达 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 添加日程、保存、重新装载恢复 |
| `ScheduleEditingUITests/testCustomSchedulesAreIsolatedBetweenAccounts` | 退出、改账号登录、账号日程隔离 |
| `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` | 上 / 下一周、指定周、课表 / DDL / 空教室横滑与点击 |
| `LoginAndScheduleUITests/testScheduleDayHolidayAndTransferConfirmationCancellation` | 每日表头、放假 / 调休选择、确认取消、窗口取消 |
| `ScheduleNavigationUITests/testHolidayAndTransferConfirmedMutations` | 放假确认、调休日期控件、调休确认、原日期和目标日期课程变更 |
| `LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch` | 线性时间轴上下滚动、双指放大 / 缩小、缩放值更新及画布左边界对齐 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` | 时间轴、显示方式、内容选择、周末 / 考试开关、主课表改名与重新装载恢复 |
| `LoginAndScheduleUITests/testCalendarOfflineTermFailureAndCancellation` | 学期入口、学校离线提示、关闭失败提示和返回设置 |
| `CalendarInteractionUITests/testCalendarReminderCloudSwitchesAndLeadTimePersistence` | 两类云开关、提醒确认取消 / 开启、阈值滚轮保存 / 取消、重新装载状态、当前及其他账号的云端偏好清理确认 / 取消 / 结果与同步暂停 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` | 时间表非法输入、有效保存、取消保留、课表改名取消 |
| `ScheduleConflictUITests/testRecoveredScheduleRequiresConfirmationAndPersistsSubsequentEdits` | 日程恢复核对、读取重试、明确确认、后续编辑与冷启动重载 |
| `ScheduleConflictUITests/testDamagedRootRebuildRequiresConfirmationAndRestoresEditing` | 损坏根文件的所属日程重建、取消 / 确认、编辑恢复与冷启动重载 |
| `ScheduleConflictUITests/testDDLSettingsResumeAfterCacheRecoveryConfirmation` | DDL 设置恢复核对、读取重试、编辑状态、确认后的滚轮保存与冷启动重载 |
| `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` | 学期下拉刷新 / 切换、日期滚轮取消、手动日期按首周周一保存 / 重新装载恢复 / 学校日期、校区 / 教学楼 / 教室刷新、订阅及学校 DDL 刷新 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 日程详情、编辑保存、删除、新增取消 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 空标题提示与草稿保留、地点 / 描述编辑、详情、单项日历导入 / 移除 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions` | 日期 / 开始时间 / 结束时间选择器、开始 / 结束时间绑定、线性轴显示任意时间、编辑取消保留 |
| `ScheduleLayoutUITests/testRecurringSchedulesUseDisplayedWeekAndRetainSelection` | 上下间距一致、课程及日程默认显示周次、日程多周点选、整组编辑 / 删除与进程重启恢复 |
| `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` | 课程名称 / 教师 / 教室、周次点选、星期 / 起止节次、保存、调课入口、删除确认 / 取消 |
| `CalendarInteractionUITests/testCourseAndExamSystemCalendarActions` | 单节及整门编辑模式、楼宇 / 房间号、周次 / 星期 / 节次多选、保存结果、单节删除确认 / 取消 |
| `CalendarInteractionUITests/testCourseAndExamSystemCalendarActions` | 单节 / 整门 / 考试日历导入与移除、重复移除结果、整学期导入及删除确认 |
| `CalendarInteractionUITests/testCalendarImportHistoryRecoveryKeepsImportAvailable` | 导入索引受损提示、重建确认 / 取消、重建结果与恢复后的学期导入 |
| `CommunityRecoveryUITests/testLaterPreviewPageRecoversThroughTheNativeRetryButton` | Quick Look 后续页故障、原生工具栏重试、原位恢复与关闭 |
| `ServiceInteractionUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation` | 学校课表刷新、短信取消、验证继续和课程保存 |
| `LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete` | 分享编码复制、剪贴板粘贴、导入、改名、课表上下滑循环、分享课表左滑删除 |
| `ScheduleEditingUITests/testLongPressOpensScheduleContextMenuAndImportSheet` | 空白区长按、导入菜单、输入 Sheet |
| `ScheduleEditingUITests/testImportInvalidCodeReportsErrorAndKeepsEditor` | 无效编码、错误提示、保留输入、取消 |
| `AccountRecoveryUITests/testFutureScheduleImportUpdateCancellationAndLink` | 新版本编码、更新提示取消、App Store 目标地址 |
| `ScheduleNavigationUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal` | 空分享取消、导入说明取消、新增 Sheet 下滑关闭 |
| `ScheduleNavigationUITests/testScheduleWeekStripScrollAndCourseLongPressShare` | 周次栏拖动、课程长按分享、空白区长按分享、课表系统分享面板 |
| `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing` | 手动待办新增 / 编辑、完成状态、详情、删除、取消 |
| `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing` | 空标题校验、详情输入、日历翻月 / 年月滚轮 / 日期选择、逐列时间滚轮、取消修改 |
| `LoginAndScheduleUITests/testDDLSettingsWheelSaveCancelAndPersistence` | 滞留天数滚轮、保存 / 取消、重新装载恢复 |
| `ScheduleEditingUITests/testSchoolDDLSourcesAndCompletionPersistAcrossSceneReload` | 两类学校日程、详情来源、完成按钮、重新装载恢复 |
| `ScheduleLayoutUITests/testDeadlineWidgetLinkOpensTheDDLSection` | DDL 小组件链接、当前账号待办、课表小组件链接 |
| `ScheduleLayoutUITests/testDeadlineWidgetAppearsInTheSystemGallery` | 系统小组件库、DDL 扩展真实预览 |
| `ScheduleEditingUITests/testDDLEmptyStateExplainsTheRetentionWindow` | 过期日程与滞留范围说明 |
| `ServiceInteractionUITests/testSchoolSSODDLVerificationCancelAndContinuation` | 学校 DDL 刷新、SSO 短信取消、验证继续、刷新结果 |
| `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` | 空结果刷新、节次单选、全选 / 全不选、清除筛选与状态 |
| `LoginAndScheduleUITests/testMapCampusLayerPanAndZoomPersist` | 三个校区、图层、地图平移 / 双指缩放、重新装载恢复 |
| `ScheduleNavigationUITests/testMapLocationAndScheduleLocationRoute` | 课程地点进入地图、定位 / 单次权限、下一节课导航到 Maps、返回 |

## 成绩与课程

| 用例 | 操作与结果 |
| --- | --- |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 查询、短信输入、验证继续、成绩展示 |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 空 / 错误 / 正确验证码、公共筛选页全选和清空、学期 / 类型独立绑定、六种排序、方向、成绩详情 |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` | 查询取消、逐项筛选、已有成绩刷新、未出分详情、成绩到课程评价路由 |
| `ScoreInteractionUITests/testTrustedTranscriptSMSRetryPreviewAndCancellation` | 申请、短信取消、申请重试、验证成功、部分分页保留与重试、两页点击与 Quick Look 左右滑动 / 关闭 |
| `ScoreInteractionUITests/testTrustedTranscriptReapplicationKeepsAvailablePages` | 部分报告保留、重新申请与完整分页展示 |
| `ScoreInteractionUITests/testScoreStorageRecoveryConfirmationAndPersistence` | 账号内成绩存储恢复、取消、确认及重新装载 |
| `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` | 课程搜索、详情、历史成绩、课程点赞 / 取消、评分评论发布 |
| `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` | 清除搜索、数据清洗开关、原生半星评分增减 / 归零、匿名 / 取消、评论点赞 / 图片 / 回复、课程分享 |
| `ScheduleNavigationUITests/testCourseHistoryChartSelectionAndHomeSurfaceSwipes` | 成绩 / 课程横滑、历史图双向拖动和学期选中值 |
| `CommunityInteractionUITests/testStableRowsPaginateAgainAfterRefreshingTheSameResults` | 课程与文章列表滚动续页、下拉刷新相同对象、再次滚动续页 |
| `ScheduleNavigationUITests/testCourseScheduleAcademicRouteAndPosterAuthorProfile` | 学校课程进入匹配评价、帖子作者及评论昵称进入公开主页 |

## 话廊、文章与消息

| 用例 | 操作与结果 |
| --- | --- |
| `CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath` | 长帖与长评论完整阅读、原生文本末尾与返回页面 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 五类话题、搜索 / 清除、四类消息 / 全部已读 |
| `CommunityInteractionUITests/testGalleryBlockingUpdatesLoadedFeedsAndUnblockingRestoresThem` | 已加载列表屏蔽作者、过滤状态更新、解除屏蔽后恢复内容 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 帖子详情、帖子点赞 / 取消、评论发送、编辑入口 |
| `CommunityPublishingUITests/testGalleryComposerTagsSettingsPublishAndDelete` | 发布校验、系统下拉关闭保护、编辑中后台返回、草稿保存 / 加载 / 丢弃、标准 / 自定义标签、删除标签、匿名 / 公开、发布、删除确认 / 取消 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 帖子标题 / 正文保存、声明选择、保存后详情和列表同步 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 评论长按复制 / 举报 / 删除、原因输入、提交、删除取消 / 确认 |
| `CommunityInteractionUITests/testPosterReportSelectionCancellationAndSubmission` | 卡片及详情举报、分类失败 / 重试、类型选择、取消、说明提交、成功返回 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` | 评论排序、点赞 / 取消、回复、评论照片选择器取消 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题及消息双向横滑、消息关联详情、两类搜索结果进入详情、文章排序 |
| `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval` | 卡片 / 帖子 / 评论图片预览、预览打开时切换场景并恢复原进程页面、原有图片移除及取消、新图上传失败 / 重试 / 成功 / 移除、照片选择器取消、建议图片移除 / 放弃草稿 |
| `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete` | 文章标题 / 简介 / 正文发布、评论发布、编辑保存、取消后继续编辑 / 确认放弃、再编辑、删除确认 / 取消 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 文章搜索 / 清除、搜索结果及详情路由 |
| `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` | 顶部及页尾点赞 / 取消、文章评论回复、评论取消 |
| `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete` | 编辑器字段、空发布校验、匿名发布、编辑取消 |
| `CommunityPublishingUITests/testDamagedPaperDraftStorageRecoversAndKeepsCurrentInput` | 草稿存储恢复取消 / 确认、当前输入保留、恢复后暂存及再次读取 |
| `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` | 正文链接、正文图片预览、页尾点赞及顶部同步、评论排序绑定、文章分享、评论取消 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题及文章搜索排序、搜索刷新、文章列表双向排序横滑 |
| `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` | 话题 / 文章列表及详情、消息、文章搜索下拉刷新；竖向刷新保留分类；首尾分类向外横滑在话题 / 文章之间切换、隐藏机器人开关与顶部分栏同步、隐藏当前机器人分栏后回到推荐 |
| `InteractionCoverageUITests/testBotFeedContinuesAcrossEmptyScanBatches` | 机器人首屏与续页按批结束空扫描；继续入口沿源游标查找后续帖子 |
| `CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail` | 课程、文章列表及搜索、话题分页故障保留当前位置，页尾重试沿原游标展示后续内容 |
| `CommunityRecoveryUITests/testIdenticalFeedRefreshKeepsThePaginationPosition` | 相同首屏下拉刷新、受控分页与列表位置保留 |
| `CommunityEditingRecoveryUITests/testReportEditingAndSubmissionKeepTheirSheet` | 举报说明下滑保护、放弃确认、提交期间载荷保护与回执 |
| `CommunityEditingRecoveryUITests/testContentControlsRemainAvailableAtAccessibilityTextSizes` | 浅色及深色的大字号课程卡片、评论操作、头像统计、长标签横滑与分区切换 |
| `ScheduleEditingUITests/testScheduleEditorsProtectChangedInput` | 自定义日程及 DDL 输入保留、下滑保护、继续编辑与明确放弃 |
| `ScheduleEditingUITests/testCourseStartSectionKeepsItsEndValid` | 提高课程开始节次、关闭保护与有效节次保存 |
| `CommunityRecoveryUITests/testCourseLookupFailureKeepsTheSearchIdentity` | 两路检索故障后转入原生课程搜索，保留课程名称并展示可选择的结果 |
| `CommunityRecoveryUITests/testDuplicatePagesKeepTheVisibleTailLoading` | 课程、文章与个人帖子跳过重复页后自动继续，保留实际行任务生命周期 |
| `CommunityRecoveryUITests/testMessagePaginationRetriesAtTheVisibleTail` | 消息后续页故障提示、页尾原位重试与已加载消息保留 |
| `CommunityRecoveryUITests/testMessageReadStorageRecoveryKeepsMessagesAvailable` | 消息已读存储受损时保留正文、读取重试、恢复取消与确认、恢复后继续展示 |
| `CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard` | 三类评论输入的下滑关闭保护、继续编辑与明确放弃 |
| `CommunityEditingRecoveryUITests/testCommentBodiesShareLinksImagesAndNativePreview` | 话题、课程和文章评论统一展示链接、图片并进入系统预览 |
| `CommunityEditingRecoveryUITests/testCourseCommentsRecoverWhileHistoryLoadsIndependently` | 慢评论期间展示历史成绩、评论首屏故障原位重试、详情下拉刷新 |
| `CommunityEditingRecoveryUITests/testFailedPaperSortKeepsTheDisplayedConditionVisible` | 排序故障保留已有文章、标明结果实际条件、新条件成功后更新提示 |
| `CommunityEditingRecoveryUITests/testUploadedCommentImageCanBePreviewedAndRemoved` | 系统照片选择、上传故障后重新选择、预览和移除图片、文字保留 |
| `CommunityEditingRecoveryUITests/testSuggestionSaveWaitsForSelectedImageImport` | 系统照片选择、导入期间保存等待、已选图片与文字重载 |
| `CommunityRecoveryUITests/testCommentReviewContinuesTheConfirmedSubmission` | 评论结果待确认、人工核对确认 / 取消、同一内容再次发送 |
| `CommunityRecoveryUITests/testMessagesAndFavoritesOpenNativeResources` | 文章与课程消息打开各自原生详情，课程收藏进入原生课程页 |
| `ServiceInteractionUITests/testOfflineRecoveryRetryAndErrorReportEditor` | 离线重试、诊断编辑、原始模式、复现 / 联系方式、确认取消 / 确认、提交失败保留、关闭 |
| `ServiceInteractionUITests/testCommunityFailedRequestsRetryToLoadedState` | 课程 / 话题 / 文章首次失败、重试到加载成功 |
| `AccountRecoveryUITests/testErrorReportSanitizedSubmissionAndFailureRecovery` | 报告打开时切换场景并清理全局呈现器、报告原始 / 脱敏切换、缺少联系方式继续提交、受理后响应丢失保留完整载荷并重试、提交成功关闭、列表重试恢复 |
| `AccountRecoveryUITests/testWebGallerySettingPersistenceScrollingAndNativeReturn` | 网页开关、WebKit 上下滑动、重新装载保留、切回原生列表 |

## 我的、设置与反馈

| 用例 | 操作与结果 |
| --- | --- |
| `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` | 个人统计入口、用户行进入公开主页、关注成功 |
| `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` | 粉丝 / 关注 / 帖子列表刷新、公开主页关注状态、头像预览、统计显示 / 刷新、公开帖子详情 / 下滑关闭、个人帖子详情、删除取消 / 确认 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 学号 / UID 显示和隐藏、昵称 / 签名编辑取消、头像选择器取消 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 昵称 / 签名保存及重新加载、学校密码更新、登录检查、社区安全密码输入与取消、认证失败重试、退出、重新登录 |
| `CommunityPublishingUITests/testGallerySettingsValidationTogglesAndPersistence` | 机器人 / 匿名 / 网页开关及持久化状态、屏蔽 UID 校验 / 键盘提交 / 保存 / 重新装载 |
| `CommunityPublishingUITests/testSuggestionDraftRestoreAndDiscard` | 建议 / 联系方式输入、空提交禁用、下滑关闭保护、草稿保存 / 加载 / 丢弃 |
| `InteractionCoverageUITests/testSuggestionMissingContactConfirmationAndSubmitFailure` | 图片选择器取消、缺少联系信息返回补充 / 继续、提交失败保留、草稿丢弃 |
| `ServiceInteractionUITests/testSuggestionSuccessfulSubmissionAndDiscardSavedDraft` | 草稿放弃加载、提交确认、受理后响应丢失保留完整载荷并重试、成功关闭、草稿清理 |
| `ServiceInteractionUITests/testSuggestionSubmissionProtectsThePendingPayload` | 提交期间正文 / 联系方式 / 附件与关闭控件禁用、下滑关闭保护、原请求完成后关闭 |
| `ServiceInteractionUITests/testRecoveredSuggestionPreservesContentAndConfirmsANewSubmission` | 待确认建议附件部分恢复、文字 / 联系方式 / 可用图片保留、新建议身份确认 / 返回核对、保存重载与提交 |
| `InteractionCoverageUITests/testCacheLimitPersistenceClearAndConfirmedReset` | 缓存上限输入 / 重新装载保留、缓存清理、文稿删除确认、返回登录、测试日程清理 |
| `InteractionCoverageUITests/testSettingsRecoveryPreservesScheduleAndAccount` | 设置快照恢复入口、取消 / 确认、偏好重新保存与加载、账号及已有日程保留 |
| `CommunityPublishingUITests/testAboutLicenseUpdateAndResetConfirmation` | 开源声明滚动、自动更新开关、离线检查提示、重置取消 |
| `ServiceInteractionUITests/testManualUpdatePromptAllActionsAndCurrentVersion` | 新版本本次忽略 / 忽略此版本 / App Store、当前版本提示 |
| `CommunityInteractionUITests/testExternalLinksFromAboutAndCourseResources` | 关于页备案、仓库、QQ、邮件、课程共享资料目标 URL |
| `ScheduleNavigationUITests/testNetworkDiagnosisProgressAndReport` | 网络诊断触发、八步汇总、结束后恢复按钮 |

## 测试数据与平台动作

| 配置 | 场景 |
| --- | --- |
| `BIT101_UI_TEST_CONTENT=1` | 内存 HTTP 响应，经过生产社区 Service 解码；维护发布、编辑、删除、点赞、评论、关注和资料变更；反馈提交返回合成成功响应 |
| `BIT101_UI_TEST_SCHOOL=1` | 当前周起始日期、学校课程 / 考试、两个学期、两个校区 / 楼宇、空教室和学校 DDL 固定响应 |
| `BIT101_UI_TEST_SCHOOL_SMS=1` | 学校课程和 DDL 的验证码 challenge；`123456` 验证成功，其他输入进入错误分支 |
| `BIT101_UI_TEST_CALENDAR_HISTORY_RECOVERY=1` | 首次日历导入遇到索引受损，显式重建后继续导入 |
| `BIT101_UI_TEST_MEDIA_RECOVERY=1` | 两页图片预览，后续页原图首次请求失败、原生重试后成功 |
| `BIT101_UI_TEST_DUPLICATE_PAGES=1` | 源页包含重复首屏，后续响应延迟以覆盖行任务取消窗口 |
| `BIT101_UI_TEST_MESSAGE_PAGING_FAILURE_ONCE=1` | 消息分页首次读取失败，重试后返回后续消息 |
| `BIT101_UI_TEST_MESSAGE_STORAGE_RECOVERY=1` | 当前账号已读快照受损，保留消息正文并由用户确认恢复 |
| `BIT101_UI_TEST_SUGGESTION_RECOVERY=1` | 待确认建议保留文字、联系方式与一张可用图片，另一张图片缺失；传输验收新的提交身份与恢复内容 |
| `BIT101_UI_TEST_FEEDBACK_HOLD=1` | 建议请求等待控制通道释放，验收提交期间的表单与关闭保护 |
| `BIT101_UI_TEST_COMMENT_OUTCOME_UNKNOWN_ONCE=1` | 首次评论响应缺少有效身份，人工核对后再次发送 |
| `BIT101_UI_TEST_MEDIA=1` | 合成 PNG、帖子 / 评论 / 头像图片、Editor.js 正文图片与链接、带图片的两类草稿；第一次上传失败，第二次成功 |
| `BIT101_UI_TEST_FAILURE_ONCE=1` | 课程、话题和文章首次请求失败，随后重试成功 |
| `BIT101_UI_TEST_UPDATE=new/current` | App Store 查询返回新版本 / 当前版本固定结果 |
| `BIT101_UI_TEST_DDL_FIXTURE=sources/overdue` | 学校双来源 / 滞留范围空状态与持久化 |
| `BIT101_UI_TEST_TAB=schedule/map/gallery/home/mine` | 初始 Tab 场景，减少重复页面往返 |
| `BIT101_UI_TEST_SETTINGS=calendar/ddl/gallery/account/about` | 初始设置页场景，各设置入口保留实际点击覆盖 |
| `BIT101_UI_TEST_COURSE_COMMENT_RECOVERY=1` | 评论首屏等待控制通道释放后返回故障，原位重试恢复；历史成绩独立加载 |
| `BIT101_UI_TEST_COMMENT_MEDIA_LINKS=1` | 三类评论的图片附件和可点击正文链接 |
| `BIT101_UI_TEST_IMAGE_IMPORT_HOLD=1` | 已选照片等待控制通道释放，保存验收覆盖完整导入结果 |

所有测试凭据、文件、偏好和媒体缓存归隔离会话与测试目录。系统日历确认通过内存 `SchedulePlatformActions` 验收，偏好云同步使用内存 `PreferenceCloudStoring`。外部链接通过 UI 宿主接收页面实际 URL，并展示完整目标供断言。地图导航仍交给 Maps。测试清理场景使用隔离文件和偏好清理动作。常规 Release 恢复由测试脚本承接。

真机专项范围包括系统凭据及短信建议的实际自动填充、照片库真实选择与读取、系统日历 / 通知授权与实际日历写入、浏览器 / 邮件 / App Store 的系统交接、网页自身交互、Widget 与 Watch 界面。上述范围需要对应设备、系统权限和专项运行证据。

## 执行流程

`Scripts/check-ui-consistency.py` 校验全部可执行方法与覆盖表一致。视觉规则覆盖 App、Modules、Watch 与两种 Widget。源码库存清点 SwiftUI 与 UIKit 控件、菜单动作、手势、回调及滚动容器，原生控件继承及显式、隐式构造共同进入数量与用例归属门禁。运行门禁核对按钮、导航、菜单、链接、系统分享、照片入口、文本输入、开关、选择、日期、滑块、步进、手势载体与刷新、提交回调。动态文案沿稳定标识验收，共享验收流程中的同名分支使用独立标识。直接修饰器提供所属控件身份；运行证据按独立实例分配，核对文本输入、点击、选择、长按与滑动操作类型；刷新与键盘提交由实际回调执行后发布证据。iOS 编译条件下的交互进入真机门禁。测试结果、耗时和设备状态保存在固定日志与结果包中。

XCTest 短按前通过 SpringBoard 的通知横幅标识检查遮挡，横幅出现时上滑收起并验证关闭；触发动作的业务提示继续由对应流程点击与断言。取消、原生提交、返回、原生分栏切换和系统预览关闭共用这条处理路径。

业务点击前采集控件观察，查询和几何检查读取当前状态。滚动合同通过显式用例辅助方法执行，并在场景业务断言完成后、隔离配置重置前验收最终页面；分页和选择结果由各自流程中的实际手势触发。查询耗时按用例聚合到指标日志。

完整批次串行执行；常规配置与模型重载验证原进程 ID，三类核心持久化流程采用冷启动并核对新进程 ID。场景通过测试专用的本机通道更新，重新创建页面及模型，夹具修改按场景清空；各项维持独立的隔离数据重置；场景重载先通过全局错误呈现器的重置入口清理报告页、提示队列及迟到呈现任务。测试窗口使用系统默认动画速度，普通场景关闭 UIKit 动画；连续编辑、短信重试、媒体预览和多层弹窗场景启用系统动画，核对实际窗口速度及动画启用状态，手势保留标准 XCTest 实现。取消、保存、重试及全部业务断言继续执行；失败保留截图和元素树。异步错误与成功提示等待预期标题出现，出现、消失和数值变化先检查当前状态。按钮在当前呈现页面按实际标识和文案解析，再查询系统可点击状态；同一页面复用已选中的 Tab。场景回复与同一份界面快照共同校验原 App 进程、页面版本和初始页面状态；原生错误提示携带所属场景身份，失败夹具以预期错误提示验证首屏就绪；准备定位使用实际 UIScrollView 的可见区域滚动；显式滑动、刷新、拖动和缩放保持 XCTest 手势，复用 App 原点及已读取的容器坐标；日期时间入口、滚轮数值与布局从控件快照读取，手势复用 App 原点；时间滚轮采用慢速短距离拖动、停留释放及原值恢复；自定义日程先操作结束时间，再操作开始时间，保留时间区间联动，图表拖动保留必要的按住时间。

快速开发可将受影响用例通过直接填写多个用例关键词合并到同一次调用；完整验收运行整个 UI 组。真机批次结束后恢复常规 Release App。

照片选择器等待“照片”控件出现后点击顶层取消并确认关闭；返回操作选择当前可交互导航栏。开关定位行内的原生控件，滚动至可触达位置后执行控件操作并核对数值。普通控件状态从 App 内当前渲染的无障碍树读取，同一界面状态下按完整查询范围复用结果，快速按钮动作核对 XCTest 原生可触达状态，字段输入核对实际焦点与 UIKit 命中；查询合同覆盖页面内覆盖层遮挡按钮与输入框。业务按钮通过原生 XCTest 点击。公共查询合同中，SwiftUI 按钮通过公开的 accessibilityActivate 执行控件事件，UIKit 按钮使用实际控件事件，导航栏按钮发送实际 UIBarButtonItem 的 target/action 或实际控件的 UIAction；菜单入口使用 XCTest 短按，共享菜单合同验证原生选项点击，消费页面通过 updateVisibleMenu 取得当前可见菜单的 UIAction，由实际控件发送并收起菜单；系统界面、日期选择器和滚轮保留 XCTest 查询与操作，同页普通字段和按钮使用各自的控件路径，长按、拖动、滑动和缩放保留各自手势。普通业务字段通过原生触摸聚焦，核对实际第一响应者及 UIKit 命中的输入控件，再通过实际 UITextInput 的完整选区和 insertText 更新，随后核对完整字段值和业务结果；公共字段合同比较真实触摸聚焦、键盘完成及聚焦前后的输入绑定。登录、密码、键盘提交及公共 TextView 合同使用系统键盘输入；替换已有文本时点击中心、等待完成按钮附件、设置全文选区，通过系统键盘删除并核对空值，再输入新文本。同一界面状态中的 App 查询按完整查询范围复用结果，平台界面、场景就绪、滚动定位和导航返回共用 XCTest 快照；界面操作与等待轮询刷新属性读取，原生存在性复用当前快照中的目标，快照缺少目标时通过 XCTest 实时查询确认。动态列表按当前查询位置重新定位，导航动作等待目标页面；任意元素查询命中的按钮使用同一查询范围执行控件事件。查询合同与原生 XCTest 比较标识、类型、禁用状态、可触达状态和布局，按钮合同分别验证原生点击与无障碍事件后的真实状态。键盘附件在窗口挂载和焦点建立时安装，工具栏沿输入控件身份复用，各页面点击实际附件按钮收起键盘。背景收键盘手势限定于当前页面内容区域，系统键盘及自动填充建议由系统接收触摸。

共享开关合同分别验证真实触摸和控件事件的数值一致性及持久化；UIKit 开关更新实际 UISwitch 并发送 valueChanged，消费页面继续验证各自绑定与确认流程。开关操作后的存在性和数值从同一份控件快照读取；同一次图片点击复用布局尺寸；大字号导航复用窗口范围，Tab 的选中状态、布局与文案从同一份快照读取。输入助手复用已确认的系统键盘状态，在第三方输入法缺少 XCTest 键盘元素时点击系统“下一个键盘”，等待原生键盘后输入并核对完整字段值。常规场景切换校验原进程持续运行，后台状态激活原进程；专门的冷启动场景结束原进程，并保留隔离账号数据用于启动恢复。前台失败保留截图和元素树，其他 App 状态记录运行状态。运行期间保持 BIT101 前台并暂停手动操作。

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh build ui
Scripts/run-static-audit.sh
```

完整验收要求源码库存中的全部用例实际执行并通过。报告记录构建与运行耗时、包含常规 App 恢复的工作流总耗时、用例耗时合计、最慢十项、App 启动次数、进程 ID、系统交互动作、App 内界面查询、共享原生快照读取、控件无障碍激活、UIKit 控件事件、输入更新、键盘完成动作、场景准备耗时、界面快照请求与阶段耗时估计。动作前观察当前呈现页面的完整无障碍树，按测试场景与导航路径隔离控件，再以标识或类型与文案及同页出现次序记录全部已挂载的按钮、输入、选择、链接和可调整控件；禁用状态单独核对断言。交互库存覆盖 UIAutomationTestCase 登记的全部场景进程；性能用例沿独立启动和测量流程验收。完整批次沿源码交互合同验收已访问控件；挂载实例的待访问和待检查禁用项保留为诊断，禁用分支沿页面业务断言与公共组件合同验收。运行库存记录当次呈现页面，逐页矩阵和业务断言维护页面与分支范围。快照阶段耗时由相邻日志事件估算，可与交互阶段重叠。编译使用 `ui-tests-build.log`，运行使用 `ui-tests.log`，结果使用固定 `test-results.xcresult`、`test-metrics.txt` 和按需导出的 `diagnostics/`；真机初始化阻塞与实际用例失败分别记录。

动画专项场景使用系统默认窗口速度并验证动画启用状态。登录键盘提交与建议草稿往返使用原生触摸和系统键盘；同一进程的场景配置切换会更新所选交互路径。

## 源码交互清单

SwiftSyntax 清点每个源码作用域的控件、输入、滚动和手势声明，并将公共交互组件的页面调用纳入清单。新增页面或交互声明时，同步清单与验收流程；静态审计核对声明种类、数量和有效用例归属。运行库存按用例、导航、弹窗及同名控件出现序号记录实际操作；禁用状态通过成功的显式断言验收。源码清单维护声明与流程归属，刷新、提交、列表删除与移动回调记录各自实际执行动作；发布门禁将源码中的固定交互标识、插值标识模板和标题与对应流程的实际访问记录核对，同名声明按独立控件实例计数；混合专项归属继续核对自动流程，新增条件分支保留独立访问证据。动态文案与控件值域沿用流程中的业务断言。对应流程维护条件分支的操作和业务断言。专项归属由发布证据中的真机检查项承接。

| 源码作用域 | 交互声明 | 验收归属 |
| --- | --- | --- |
| `BIT101-iOS/Login/UITestAccessibilityActions.swift:UITestAccessibilityActions` | `{"UIButton":1}` | `ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract` |
| `BIT101-iOS/BIT101_iOSApp.swift:BIT101_iOSApp` | `{"AppSMSVerificationSheet":1}` | `ServiceInteractionUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation` |
| `BIT101-iOS/Login/LoginViews.swift:AccountRegistrationView` | `{"Button":3,"Picker":1,"SecureField":3,"TextField":2}` | `AccountRegistrationUITests/testRegistrationResetAndCommunityPasswordLogin` |
| `BIT101-iOS/Login/LoginViews.swift:LoginFormView` | `{"Button":1,"NavigationLink":1,"SecureField":1,"TextField":1,"onSubmit":2}` | `AccountRecoveryUITests/testLoginSubmitButtonAndKeyboardScrollDismissal,InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout,ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract,AccountRegistrationUITests/testRegistrationResetAndCommunityPasswordLogin` |
| `BIT101-iOS/Settings/SettingsAccountViews.swift:AccountSettingsPage` | `{"Button":5,"List":1}` | `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout,ScheduleEditingUITests/testCustomSchedulesAreIsolatedBetweenAccounts` |
| `BIT101-iOS/Settings/SettingsAccountViews.swift:SettingsSensitiveValueRow` | `{"Button":1}` | `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` |
| `BIT101-iOS/Settings/SettingsCommunityViews.swift:AboutSettingsPage` | `{"Button":5,"Link":4,"List":1,"NavigationLink":1,"ScrollView":1,"Toggle":1}` | `CommunityPublishingUITests/testAboutLicenseUpdateAndResetConfirmation,CommunityInteractionUITests/testExternalLinksFromAboutAndCourseResources,ServiceInteractionUITests/testManualUpdatePromptAllActionsAndCurrentVersion,InteractionCoverageUITests/testCacheLimitPersistenceClearAndConfirmedReset` |
| `BIT101-iOS/Settings/SettingsCommunityViews.swift:GallerySettingsPage` | `{"Button":1,"List":1,"TextField":2,"Toggle":3,"onSubmit":1}` | `CommunityPublishingUITests/testGallerySettingsValidationTogglesAndPersistence,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,AccountRecoveryUITests/testWebGallerySettingPersistenceScrollingAndNativeReturn,ScheduleNavigationUITests/testNetworkDiagnosisProgressAndReport,InteractionCoverageUITests/testCacheLimitPersistenceClearAndConfirmedReset,ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract` |
| `BIT101-iOS/Settings/SettingsRootView.swift:DeveloperSuggestionPage` | `{"Button":1,"ComposerImageTile":1,"PhotosPicker":1,"ScrollView":1,"TextField":2}` | `CommunityPublishingUITests/testSuggestionDraftRestoreAndDiscard,InteractionCoverageUITests/testSuggestionMissingContactConfirmationAndSubmitFailure,ServiceInteractionUITests/testSuggestionSuccessfulSubmissionAndDiscardSavedDraft,ServiceInteractionUITests/testSuggestionSubmissionProtectsThePendingPayload,ServiceInteractionUITests/testRecoveredSuggestionPreservesContentAndConfirmsANewSubmission,CommunityEditingRecoveryUITests/testSuggestionSaveWaitsForSelectedImageImport` |
| `BIT101-iOS/Settings/SettingsRootView.swift:SettingsIndexPage` | `{"Button":1,"NavigationLink":1,"ScrollView":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` |
| `BIT101-iOS/Settings/SettingsRootView.swift:SettingsRootView` | `{"Button":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` |
| `BIT101-iOS/Settings/SettingsRootView.swift:SettingsStorageNotice` | `{"Button":3}` | `InteractionCoverageUITests/testSettingsRecoveryPreservesScheduleAndAccount` |
| `BIT101-iOS/Settings/SettingsScheduleViews.swift:AppCalendarSettingsPage` | `{"Button":5,"Toggle":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist,CalendarInteractionUITests/testCalendarReminderCloudSwitchesAndLeadTimePersistence` |
| `BIT101-iOS/Settings/SettingsSupportViews.swift:SettingsTextEditSheet` | `{"Button":2,"TextField":1}` | `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` |
| `BIT101-iOS/Shared/Client/AppErrorPresentation.swift:AppErrorReportSheet` | `{"Button":2,"Picker":1,"TextField":2}` | `AccountRecoveryUITests/testErrorReportSanitizedSubmissionAndFailureRecovery,ServiceInteractionUITests/testOfflineRecoveryRetryAndErrorReportEditor` |
| `BIT101-iOS/Shared/Client/AppErrorPresentation.swift:DiagnosticRecoveryActions` | `{"Button":1,"Link":2}` | `ServiceInteractionUITests/testOfflineRecoveryRetryAndErrorReportEditor,AccountRecoveryUITests/testErrorReportSanitizedSubmissionAndFailureRecovery` |
| `BIT101-iOS/Shared/Client/AppUpdateChecker.swift:AppPromptHostModifier` | `{"Button":2,"keyboardShortcut":1}` | `ServiceInteractionUITests/testManualUpdatePromptAllActionsAndCurrentVersion` |
| `BIT101-iOS/Shared/Client/KeyboardDismissSupport.swift:KeyboardBackgroundTapInstaller.Coordinator` | `{"UIButton":1,"UITapGestureRecognizer":1}` | `AccountRecoveryUITests/testLoginSubmitButtonAndKeyboardScrollDismissal,CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `BIT101-iOS/Shell/AppAcademicDestinations.swift:ScoreRootScene` | `{"simultaneousGesture":2}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail,ScheduleNavigationUITests/testCourseHistoryChartSelectionAndHomeSurfaceSwipes` |
| `BIT101-iOS/Shell/AppShellView.swift:AppShellView` | `{"TabView":1}` | `ScheduleEditingUITests/testMainTabsRemainAccessibleAtAccessibilityDynamicType` |
| `BIT101Watch/WatchScheduleRootView.swift:WatchScheduleEmptyStateView` | `{"Button":1}` | `manual:watch` |
| `BIT101Watch/WatchScheduleRootView.swift:WatchScheduleRootView` | `{"Button":4,"ScrollView":1,"TabView":1}` | `manual:watch` |
| `Modules/CommunityUI/Sources/CommunitySubmissionReviewSection.swift:CommunityCommentReviewSection` | `{"Button":1}` | `CommunityRecoveryUITests/testCommentReviewContinuesTheConfirmedSubmission` |
| `Modules/CommunityUI/Sources/CommunitySubmissionReviewSection.swift:CommunityPublicationReviewSection` | `{"Button":1}` | `CommunityPublishingUITests/testGalleryPublicationReviewSurvivesRestartAndDraftRestore,CommunityPublishingUITests/testPaperPublicationReviewSurvivesRestartAndDraftRestore` |
| `Modules/CommunityUI/Sources/CommunityDesignSystem.swift:CommunityCommentSortPicker` | `{"Picker":1}` | `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` |
| `Modules/CommunityUI/Sources/CommunityDesignSystem.swift:CommunityCommentBody` | `{"CommunityLinkedText":1,"CommunityPosterImagesView":1}` | `CommunityEditingRecoveryUITests/testCommentBodiesShareLinksImagesAndNativePreview,CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath` |
| `Modules/CommunityUI/Sources/ComposerImageTile.swift:ComposerImageTile` | `{"AppComposerImageRemoveButton":1,"Button":2}` | `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval,CommunityEditingRecoveryUITests/testUploadedCommentImageCanBePreviewedAndRemoved` |
| `Modules/CommunityUI/Sources/CommunityPaginationFooter.swift:CommunityPaginationFooter` | `{"Button":1}` | `CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail,InteractionCoverageUITests/testBotFeedContinuesAcrossEmptyScanBatches,CommunityRecoveryUITests/testMessagePaginationRetriesAtTheVisibleTail` |
| `Modules/CommunityUI/Sources/CommunityPosterActionMenu.swift:CommunityPosterActionMenu` | `{"Button":4,"Menu":1}` | `CommunityInteractionUITests/testPosterReportSelectionCancellationAndSubmission,MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion,CommunityPublishingUITests/testGalleryComposerTagsSettingsPublishAndDelete,InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval` |
| `Modules/CommunityUI/Sources/CommunityLinkifiedText.swift:CommunityFullTextSheet` | `{"Button":1}` | `CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath` |
| `Modules/CommunityUI/Sources/CommunityLinkifiedText.swift:CommunityFullTextView` | `{"UITextView":1}` | `CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath` |
| `Modules/CommunityUI/Sources/CommunityLinkifiedText.swift:CommunityLinkedText` | `{"Button":1,"CommunityFullTextSheet":1}` | `CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath` |
| `Modules/CommunityUI/Sources/CommunityPosterViews.swift:CommunityPosterCard` | `{"CommunityLinkedText":1,"CommunityPosterActionMenu":1,"CommunityPosterImagesView":1,"ScrollView":1,"onTapGesture":2}` | `CommunityEditingRecoveryUITests/testContentControlsRemainAvailableAtAccessibilityTextSizes,CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/CommunityUI/Sources/CommunityPosterViews.swift:CommunityPosterImagesView` | `{"Button":1}` | `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval` |
| `Modules/CourseFeature/Sources/CourseCommentViews.swift:CourseCommentComposerSheet` | `{"AppCommentComposerContentSection":1,"CommunityCommentReviewSection":1,"Stepper":1,"TextField":1}` | `CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard,CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `Modules/CourseFeature/Sources/CourseCommentViews.swift:CourseCommentRow` | `{"AppCommentActionBar":1,"AppCommentIdentityHeader":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `Modules/CourseFeature/Sources/CourseCommentViews.swift:CourseCommentsSection` | `{"AppFailureState":1,"CommunityPaginationFooter":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare,CommunityEditingRecoveryUITests/testCourseCommentsRecoverWhileHistoryLoadsIndependently` |
| `Modules/CourseFeature/Sources/CourseDetailView.swift:CourseDetailViewScene` | `{"AppDetailCircleButton":2,"AppDetailShareLink":1,"AppEmptyState":1,"AppFailureState":1,"Button":2,"ScrollView":1,"refreshable":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare,CommunityInteractionUITests/testExternalLinksFromAboutAndCourseResources,ScheduleNavigationUITests/testCourseHistoryChartSelectionAndHomeSurfaceSwipes,ScheduleNavigationUITests/testCourseScheduleAcademicRouteAndPosterAuthorProfile,CommunityEditingRecoveryUITests/testCourseCommentsRecoverWhileHistoryLoadsIndependently` |
| `Modules/CourseFeature/Sources/CourseRootView.swift:CourseEvaluationLinkScene` | `{"Button":2}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare,CommunityRecoveryUITests/testCourseLookupFailureKeepsTheSearchIdentity` |
| `Modules/CourseFeature/Sources/CourseRootView.swift:CourseEvaluationScene` | `{"AppEmptyState":1,"AppFailureState":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `Modules/CourseFeature/Sources/CourseRootView.swift:CoursePageContent` | `{"AppEmptyState":2,"AppFailureState":1,"CommunityPaginationFooter":1,"List":1,"NavigationLink":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare,CommunityInteractionUITests/testStableRowsPaginateAgainAfterRefreshingTheSameResults,CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail` |
| `Modules/CourseFeature/Sources/CourseRootView.swift:CourseSearchRow` | `{"Button":1,"TextField":1,"onSubmit":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `Modules/DesignSystemKit/Sources/AppCommentComponents.swift:AppCommentActionBar` | `{"Button":2}` | `InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare,CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,CommunityEditingRecoveryUITests/testCommentBodiesShareLinksImagesAndNativePreview,CommunityEditingRecoveryUITests/testContentControlsRemainAvailableAtAccessibilityTextSizes` |
| `Modules/DesignSystemKit/Sources/AppCommentComponents.swift:AppCommentIdentityHeader` | `{"Button":1}` | `ScheduleNavigationUITests/testCourseScheduleAcademicRouteAndPosterAuthorProfile,CommunityEditingRecoveryUITests/testContentControlsRemainAvailableAtAccessibilityTextSizes` |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift:AppCancelEditingButton` | `{"Button":3}` | `CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard,CommunityEditingRecoveryUITests/testReportEditingAndSubmissionKeepTheirSheet,ScheduleEditingUITests/testScheduleEditorsProtectChangedInput` |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift:AppCommentComposerContentSection` | `{"Toggle":1}` | `CommunityInteractionUITests/testCourseCommentPublishingRepliesRatingsCleaningSearchAndShare` |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift:AppComposerToolbar` | `{"AppCancelEditingButton":1,"Button":1}` | `CommunityPublishingUITests/testGalleryComposerTagsSettingsPublishAndDelete,CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard` |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift:AppComposerImageRemoveButton` | `{"Button":1}` | `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval,CommunityEditingRecoveryUITests/testUploadedCommentImageCanBePreviewedAndRemoved` |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift:AppMultiSelectionList` | `{"Button":3,"List":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete,ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift:AppOrderedSearchBar` | `{"Button":1,"Picker":1,"TextField":1,"onSubmit":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift:AppSegmentedPicker` | `{"Picker":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift:AppTopSegmentedPicker` | `{"AppSegmentedPicker":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift:global` | `{"DragGesture":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/DesignSystemKit/Sources/AppLayoutComponents.swift:AppDetailCircleButton` | `{"Button":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` |
| `Modules/DesignSystemKit/Sources/AppLayoutComponents.swift:AppDetailShareLink` | `{"ShareLink":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` |
| `Modules/DesignSystemKit/Sources/AppLayoutComponents.swift:AppFloatingActionButton` | `{"Button":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/DesignSystemKit/Sources/AppRefreshStatusComponents.swift:AppRefreshStatusRow` | `{"Button":1}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry` |
| `Modules/DesignSystemKit/Sources/AppStateComponents.swift:AppEmptyState` | `{"Button":1}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` |
| `Modules/DesignSystemKit/Sources/AppStateComponents.swift:AppFailureState` | `{"Button":1}` | `ServiceInteractionUITests/testCommunityFailedRequestsRetryToLoadedState,CommunityEditingRecoveryUITests/testPosterCommentsRetryInPlaceAfterInitialFailure` |
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift:AppSMSVerificationSheet` | `{"Button":2}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift:AppSchoolSMSVerificationSheet` | `{"AppSMSVerificationSheet":1}` | `ServiceInteractionUITests/testSchoolSSODDLVerificationCancelAndContinuation` |
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift:VerificationCodeField` | `{"UITextField":1}` | `ServiceInteractionUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation,ScoreInteractionUITests/testTrustedTranscriptSMSRetryPreviewAndCancellation` |
| `Modules/GalleryFeature/Sources/GalleryCommentViews.swift:GalleryCommentComposerSheet` | `{"AppCommentComposerContentSection":1,"ComposerImageTile":1,"CommunityCommentReviewSection":1,"PhotosPicker":1,"ScrollView":1,"TextField":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard,CommunityEditingRecoveryUITests/testUploadedCommentImageCanBePreviewedAndRemoved` |
| `Modules/GalleryFeature/Sources/GalleryCommentViews.swift:GalleryCommentRow` | `{"AppCommentActionBar":1,"AppCommentIdentityHeader":1,"Button":5,"contextMenu":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` |
| `Modules/GalleryFeature/Sources/GalleryCommentViews.swift:GalleryPosterCommentsSection` | `{"AppFailureState":1,"CommunityCommentSortPicker":1,"CommunityPaginationFooter":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,CommunityEditingRecoveryUITests/testPosterCommentsRetryInPlaceAfterInitialFailure` |
| `Modules/GalleryFeature/Sources/GalleryComposerView.swift:GalleryComposerScene` | `{"AppComposerImageRemoveButton":1,"Button":12,"ComposerImageTile":1,"CommunityPublicationReviewSection":1,"PhotosPicker":1,"Picker":1,"TextField":3,"Toggle":2}` | `CommunityPublishingUITests/testGalleryComposerTagsSettingsPublishAndDelete,InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval,CommunityPublishingUITests/testGalleryPublicationReviewSurvivesRestartAndDraftRestore` |
| `Modules/GalleryFeature/Sources/GalleryFeedViews.swift:GalleryFeedView` | `{"AppEmptyState":1,"AppFailureState":1,"CommunityPaginationFooter":1,"CommunityPosterCard":1,"ScrollView":1,"refreshable":1}` | `CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail,InteractionCoverageUITests/testBotFeedContinuesAcrossEmptyScanBatches,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,CommunityRecoveryUITests/testIdenticalFeedRefreshKeepsThePaginationPosition` |
| `Modules/GalleryFeature/Sources/GalleryFeedViews.swift:GallerySubscriptionsView` | `{"AppEmptyState":1,"AppFailureState":1,"Button":3,"List":1,"refreshable":1}` | `CommunityInteractionUITests/testPosterSubscriptionsPersistAndAppearInFavorites,CommunityRecoveryUITests/testMessagesAndFavoritesOpenNativeResources` |
| `Modules/GalleryFeature/Sources/GalleryMessagesView.swift:GalleryMessageRow` | `{"onTapGesture":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` |
| `Modules/GalleryFeature/Sources/GalleryMessagesView.swift:GalleryMessagesView` | `{"AppEmptyState":1,"AppFailureState":1,"Button":6,"CommunityPaginationFooter":1,"List":1,"refreshable":1,"simultaneousGesture":1}` | `CommunityRecoveryUITests/testMessagesAndFavoritesOpenNativeResources,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,CommunityRecoveryUITests/testMessagePaginationRetriesAtTheVisibleTail,CommunityRecoveryUITests/testMessageReadStorageRecoveryKeepsMessagesAvailable` |
| `Modules/GalleryFeature/Sources/GalleryPosterActionViews.swift:GalleryReportSheet` | `{"AppCancelEditingButton":1,"Button":3,"Picker":1,"TextField":1}` | `CommunityInteractionUITests/testPosterReportSelectionCancellationAndSubmission,CommunityEditingRecoveryUITests/testReportEditingAndSubmissionKeepTheirSheet` |
| `Modules/GalleryFeature/Sources/GalleryPosterDetailView.swift:GalleryPosterDetailViewScene` | `{"AppDetailCircleButton":2,"AppDetailShareLink":1,"AppFailureState":1,"Button":6,"CommunityLinkedText":1,"CommunityPosterActionMenu":1,"Menu":1,"ScrollView":2,"refreshable":1}` | `CommunityInteractionUITests/testPosterSubscriptionsPersistAndAppearInFavorites,CommunityPublishingUITests/testGalleryComposerTagsSettingsPublishAndDelete,CommunityRecoveryUITests/testLongPostAndCommentKeepACompleteNativeReadingPath,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetryAndRemoval,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion,CommunityEditingRecoveryUITests/testPosterCommentsRetryInPlaceAfterInitialFailure` |
| `Modules/GalleryFeature/Sources/GalleryRootView.swift:GalleryRootViewScene` | `{"AppFloatingActionButton":4,"TabView":1,"simultaneousGesture":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker,CommunityInteractionUITests/testPosterSubscriptionsPersistAndAppearInFavorites,InteractionCoverageUITests/testPaperSortSurvivesSwitchingToTopicsAndBack` |
| `Modules/GalleryFeature/Sources/GallerySearchView.swift:GallerySearchView` | `{"AppOrderedSearchBar":1,"Button":1}` | `InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testCommunityCommentLikesRepliesSortsAndPhotoPicker` |
| `Modules/MapFeature/Sources/CampusMapScreen.swift:CampusMapScreen` | `{"AppFloatingActionButton":3}` | `LoginAndScheduleUITests/testMapCampusLayerPanAndZoomPersist,ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/MapFeature/Sources/CampusMapScreen.swift:FloatingMapLabelButton` | `{"Button":1}` | `LoginAndScheduleUITests/testMapCampusLayerPanAndZoomPersist` |
| `Modules/MediaKit/Sources/ImagePreview.swift:ImageQuickLookPresenter.Coordinator` | `{"UIBarButtonItem":2}` | `CommunityRecoveryUITests/testLaterPreviewPageRecoversThroughTheNativeRetryButton` |
| `Modules/MineFeature/Sources/MineRootView.swift:MinePosterListView` | `{"AppEmptyState":1,"AppFailureState":2,"Button":2,"CommunityPosterCard":1,"ScrollView":1,"refreshable":1}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` |
| `Modules/MineFeature/Sources/MineRootView.swift:MineProfileCard` | `{"Button":2}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` |
| `Modules/MineFeature/Sources/MineRootView.swift:MineRootViewScene` | `{"AppFailureState":1,"Button":1,"List":1,"refreshable":1}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion,InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` |
| `Modules/MineFeature/Sources/MineRootView.swift:MineStatButton` | `{"Button":1}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion,CommunityEditingRecoveryUITests/testContentControlsRemainAvailableAtAccessibilityTextSizes` |
| `Modules/MineFeature/Sources/MineRootView.swift:MineUserListView` | `{"AppFailureState":2,"Button":1,"List":1,"refreshable":1}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` |
| `Modules/MineFeature/Sources/MineRootView.swift:UserProfileRootViewScene` | `{"AppEmptyState":1,"AppFailureState":3,"CommunityPosterCard":1,"List":1,"refreshable":1}` | `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` |
| `Modules/PaperFeature/Sources/PaperCommentViews.swift:PaperCommentRow` | `{"AppCommentActionBar":1,"AppCommentIdentityHeader":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/PaperFeature/Sources/PaperCommentViews.swift:PaperCommentsSection` | `{"AppFailureState":1,"CommunityCommentSortPicker":1,"CommunityPaginationFooter":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/PaperFeature/Sources/PaperComposerViews.swift:PaperCommentComposerSheet` | `{"AppCommentComposerContentSection":1,"CommunityCommentReviewSection":1,"List":1,"TextField":1}` | `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete,CommunityRecoveryUITests/testCommentReviewContinuesTheConfirmedSubmission,CommunityEditingRecoveryUITests/testCommentEditorsProtectInputUntilConfirmedDiscard` |
| `Modules/PaperFeature/Sources/PaperComposerViews.swift:PaperComposerView` | `{"Button":11,"CommunityPublicationReviewSection":1,"TextField":3,"Toggle":1}` | `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete,CommunityPublishingUITests/testDamagedPaperDraftStorageRecoversAndKeepsCurrentInput,CommunityPublishingUITests/testPaperPublicationReviewSurvivesRestartAndDraftRestore` |
| `Modules/PaperFeature/Sources/PaperDetailView.swift:PaperContentBlockView` | `{"Button":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` |
| `Modules/PaperFeature/Sources/PaperDetailView.swift:PaperDetailViewScene` | `{"AppDetailCircleButton":2,"AppDetailShareLink":1,"AppFailureState":1,"Button":5,"Link":1,"Menu":1,"ScrollView":1,"refreshable":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,CommunityPublishingUITests/testPaperPublishEditCommentAndDelete` |
| `Modules/PaperFeature/Sources/PaperDetailView.swift:PaperRichTextView` | `{"UITextView":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` |
| `Modules/PaperFeature/Sources/PaperDetailView.swift:PaperRichTextView.Coordinator` | `{"UIAction":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` |
| `Modules/PaperFeature/Sources/PaperRootView.swift:PaperRootViewScene` | `{"AppEmptyState":1,"AppFailureState":1,"AppFloatingActionButton":2,"CommunityPaginationFooter":1,"ScrollView":1,"refreshable":1,"simultaneousGesture":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,CommunityInteractionUITests/testStableRowsPaginateAgainAfterRefreshingTheSameResults,CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,InteractionCoverageUITests/testPaperSortSurvivesSwitchingToTopicsAndBack` |
| `Modules/PaperFeature/Sources/PaperSearchViews.swift:PaperSearchScene` | `{"AppEmptyState":2,"AppFailureState":1,"AppOrderedSearchBar":1,"Button":1,"CommunityPaginationFooter":1,"ScrollView":1,"refreshable":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes,CommunityRecoveryUITests/testCommunityPaginationRetriesFromTheVisibleTail` |
| `Modules/PaperFeature/Sources/PaperSummaryViews.swift:PaperSummaryCard` | `{"accessibilityAction":1,"onTapGesture":1}` | `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare,InteractionCoverageUITests/testGalleryFeedAndSurfaceSwipesMessagesAndSearchResultRoutes` |
| `Modules/ScheduleFeature/Sources/CalendarSettingsPage.swift:CalendarSettingsPage` | `{"AppSMSVerificationSheet":1,"Button":22,"List":1,"NavigationLink":1,"Picker":3,"Toggle":5,"onDelete":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist,CalendarInteractionUITests/testCalendarReminderCloudSwitchesAndLeadTimePersistence,LoginAndScheduleUITests/testCalendarOfflineTermFailureAndCancellation,LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete,ScheduleEditingUITests/testImportInvalidCodeReportsErrorAndKeepsEditor,LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch,ScheduleEditingUITests/testLongPressOpensScheduleContextMenuAndImportSheet,ScheduleNavigationUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal,AccountRecoveryUITests/testFutureScheduleImportUpdateCancellationAndLink,ScheduleNavigationUITests/testScheduleWeekStripScrollAndCourseLongPressShare,CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh,CalendarInteractionUITests/testCourseAndExamSystemCalendarActions,CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions,CalendarInteractionUITests/testCalendarImportHistoryRecoveryKeepsImportAvailable` |
| `Modules/ScheduleFeature/Sources/CourseScheduleTabView.swift:CourseScheduleTabView` | `{"AppEmptyState":1,"AppRefreshStatusRow":2,"Button":3,"List":1,"simultaneousGesture":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes,ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete,LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete,LoginAndScheduleUITests/testScheduleDayHolidayAndTransferConfirmationCancellation,ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract,InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout,CalendarInteractionUITests/testCourseAndExamSystemCalendarActions,CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions,ScheduleNavigationUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal,ScheduleNavigationUITests/testHolidayAndTransferConfirmedMutations,ServiceInteractionUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry` |
| `Modules/ScheduleFeature/Sources/CourseScheduleTabViewActions.swift:CourseScheduleTabView` | `{"DragGesture":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes,ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete,LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete,LoginAndScheduleUITests/testScheduleDayHolidayAndTransferConfirmationCancellation,ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract,InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout,CalendarInteractionUITests/testCourseAndExamSystemCalendarActions,CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions,ScheduleNavigationUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal,ScheduleNavigationUITests/testHolidayAndTransferConfirmedMutations,ServiceInteractionUITests/testSchoolSMSCourseSyncValidationCancelAndContinuation,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry` |
| `Modules/ScheduleFeature/Sources/DDLSettingsPage.swift:DDLSettingsNumberPickerSheet` | `{"Button":2,"Picker":1}` | `LoginAndScheduleUITests/testDDLSettingsWheelSaveCancelAndPersistence,ScheduleConflictUITests/testDDLSettingsResumeAfterCacheRecoveryConfirmation` |
| `Modules/ScheduleFeature/Sources/DDLSettingsPage.swift:DDLSettingsPage` | `{"Button":4,"List":1}` | `LoginAndScheduleUITests/testDDLSettingsWheelSaveCancelAndPersistence,CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh,ServiceInteractionUITests/testSchoolSSODDLVerificationCancelAndContinuation,ScheduleConflictUITests/testDDLSettingsResumeAfterCacheRecoveryConfirmation` |
| `Modules/ScheduleFeature/Sources/FreeClassroomViews.swift:ClassroomSectionFilterPage` | `{"AppMultiSelectionList":1}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` |
| `Modules/ScheduleFeature/Sources/FreeClassroomViews.swift:FreeClassroomTabView` | `{"AppEmptyState":1,"AppRefreshStatusRow":1,"List":1,"NavigationLink":1,"Picker":2}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry` |
| `Modules/ScheduleFeature/Sources/ScheduleCalendarViews.swift:CourseScheduleCalendarView` | `{"Button":1,"ScrollView":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` |
| `Modules/ScheduleFeature/Sources/ScheduleCalendarViews.swift:ScheduleBlankContextMenuControl` | `{"UIAction":2,"UITapGestureRecognizer":1}` | `ScheduleEditingUITests/testLongPressOpensScheduleContextMenuAndImportSheet,ScheduleNavigationUITests/testScheduleWeekStripScrollAndCourseLongPressShare` |
| `Modules/ScheduleFeature/Sources/ScheduleDDLViews.swift:DDLEditSheet` | `{"AppCancelEditingButton":1,"Button":1,"DatePicker":1,"TextField":2}` | `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing,ScheduleEditingUITests/testScheduleEditorsProtectChangedInput` |
| `Modules/ScheduleFeature/Sources/ScheduleDDLViews.swift:DDLEventRow` | `{"Button":1,"accessibilityAction":1,"onTapGesture":1}` | `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing,ScheduleEditingUITests/testSchoolDDLSourcesAndCompletionPersistAcrossSceneReload` |
| `Modules/ScheduleFeature/Sources/ScheduleDDLViews.swift:DDLEventDetailSheet` | `{"Button":3,"List":1}` | `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing` |
| `Modules/ScheduleFeature/Sources/ScheduleDDLViews.swift:DDLScheduleTabView` | `{"AppEmptyState":1,"AppFloatingActionButton":1,"AppRefreshStatusRow":1,"List":1}` | `ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry` |
| `Modules/ScheduleFeature/Sources/ScheduleEditingSupport.swift:DayAdjustmentSheet` | `{"AppSegmentedPicker":1,"Button":2,"DatePicker":1}` | `ScheduleNavigationUITests/testHolidayAndTransferConfirmedMutations` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:AddCourseSheet` | `{"AppCancelEditingButton":1,"Button":1,"NavigationLink":1,"Picker":3,"TextField":3}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete,ScheduleLayoutUITests/testRecurringSchedulesUseDisplayedWeekAndRetainSelection,ScheduleEditingUITests/testCourseStartSectionKeepsItsEndValid` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:AddEditCustomScheduleSheet` | `{"AppCancelEditingButton":1,"Button":1,"DatePicker":3,"NavigationLink":1,"TextField":3}` | `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions,ScheduleLayoutUITests/testAccessibilityQueryParityAndNativeButtonContract,InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout,ScheduleEditingUITests/testCustomSchedulesAreIsolatedBetweenAccounts,ScheduleLayoutUITests/testRecurringSchedulesUseDisplayedWeekAndRetainSelection,ScheduleEditingUITests/testScheduleEditorsProtectChangedInput` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:CourseArrangementEditorSheet` | `{"AppCancelEditingButton":1,"Button":1,"NavigationLink":3,"Picker":1,"TextField":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:ScheduleSectionSelectionSheet` | `{"AppMultiSelectionList":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:ScheduleWeekSelectionSheet` | `{"AppMultiSelectionList":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete,ScheduleLayoutUITests/testRecurringSchedulesUseDisplayedWeekAndRetainSelection` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:ScheduleWeekdaySelectionSheet` | `{"Button":1,"List":1}` | `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/ScheduleFeature/Sources/ScheduleEditorViews.swift:TimeTableEditorSheet` | `{"AppCancelEditingButton":1,"Button":1,"TextEditor":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist` |
| `Modules/ScheduleFeature/Sources/ScheduleEntryDetailView.swift:ScheduleEntryDetailSheet` | `{"Button":16,"List":1}` | `CalendarInteractionUITests/testCourseAndExamSystemCalendarActions,CalendarInteractionUITests/testCustomScheduleEmptyTitleDetailsAndCalendarActions,ScheduleNavigationUITests/testMapLocationAndScheduleLocationRoute,ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetailAndDelete` |
| `Modules/ScheduleFeature/Sources/ScheduleLinearCalendarViews.swift:LinearScheduleHeader` | `{"Button":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` |
| `Modules/ScheduleFeature/Sources/ScheduleLinearCalendarViews.swift:LinearTimelineScrollContainer` | `{"UIScrollView":1}` | `LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch` |
| `Modules/ScheduleFeature/Sources/ScheduleLinearCalendarViews.swift:LinearTimelineScrollView` | `{"UIPinchGestureRecognizer":1}` | `LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch` |
| `Modules/ScheduleFeature/Sources/ScheduleRootView.swift:ScheduleRootView` | `{"AppSMSVerificationSheet":1,"DragGesture":1,"simultaneousGesture":1}` | `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` |
| `Modules/ScheduleFeature/Sources/ScheduleRootView.swift:SchedulePersistenceConflictView` | `{"Button":2}` | `ScheduleConflictUITests/testKeepLocalConflictContentPersists,ScheduleConflictUITests/testUseSyncedConflictContentPersists` |
| `Modules/ScheduleFeature/Sources/ScheduleRootView.swift:ScheduleCacheRecoveryView` | `{"Button":5}` | `ScheduleConflictUITests/testRecoveredScheduleRequiresConfirmationAndPersistsSubsequentEdits,ScheduleConflictUITests/testDDLSettingsResumeAfterCacheRecoveryConfirmation,ScheduleConflictUITests/testDamagedRootRebuildRequiresConfirmationAndRestoresEditing` |
| `Modules/ScheduleFeature/Sources/ScheduleSchoolVerification.swift:ScheduleSchoolVerification` | `{"AppSchoolSMSVerificationSheet":1}` | `ServiceInteractionUITests/testSchoolSSODDLVerificationCancelAndContinuation` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:CourseLiveActivityLeadMinutesPickerPage` | `{"Button":2,"Picker":1}` | `CalendarInteractionUITests/testCalendarReminderCloudSwitchesAndLeadTimePersistence` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:ScheduleExportCodeSheet` | `{"Button":3,"ScrollView":1,"ShareLink":1}` | `LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete,ScheduleNavigationUITests/testScheduleWeekStripScrollAndCourseLongPressShare` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:ScheduleImportCodeSheet` | `{"Button":5,"TextEditor":1,"keyboardShortcut":1}` | `LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete,ScheduleNavigationUITests/testEmptyShareAndImportGuideCancellationAndSheetSwipeDismissal,AccountRecoveryUITests/testFutureScheduleImportUpdateCancellationAndLink,ScheduleEditingUITests/testImportInvalidCodeReportsErrorAndKeepsEditor,ScheduleEditingUITests/testLongPressOpensScheduleContextMenuAndImportSheet` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:ScheduleRenameSheet` | `{"Button":2,"TextField":1}` | `LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist,LoginAndScheduleUITests/testSharedScheduleCopyImportRenameCycleAndSwipeDelete` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:ScheduleSemesterStartDatePickerPage` | `{"Button":3,"DatePicker":1}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` |
| `Modules/ScheduleFeature/Sources/ScheduleSettingsSheets.swift:ScheduleTermPickerPage` | `{"AppEmptyState":2,"Button":1,"List":1,"refreshable":1}` | `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefreshAndDDLRefresh` |
| `Modules/ScheduleFeature/Sources/ScheduleWeekSliderView.swift:ScheduleInlineWeekSlider` | `{"Button":2,"DragGesture":1,"ScrollView":1,"simultaneousGesture":1}` | `ScheduleNavigationUITests/testScheduleWeekStripScrollAndCourseLongPressShare` |
| `Modules/ScoreFeature/Sources/ScoreFilterViews.swift:ScoreFilterPage` | `{"AppMultiSelectionList":1}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/ScoreFeature/Sources/ScoreFilterViews.swift:ScoreSortPage` | `{"Button":2,"List":1}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/ScoreFeature/Sources/ScoreRootView.swift:PendingScoreDetailView` | `{"ScrollView":1}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/ScoreFeature/Sources/ScoreRootView.swift:ScoreDetailView` | `{"Button":1,"List":1}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail` |
| `Modules/ScoreFeature/Sources/ScoreRootView.swift:ScoreListPage` | `{"AppEmptyState":1,"AppFailureState":1,"AppRefreshStatusRow":1,"AppSMSVerificationSheet":1,"Button":3,"List":1,"NavigationLink":6}` | `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancelAndPendingDetail,ScoreInteractionUITests/testTrustedTranscriptSMSRetryPreviewAndCancellation,ScoreInteractionUITests/testTrustedTranscriptReapplicationKeepsAvailablePages,ScheduleLayoutUITests/testRefreshStatusRowsUseConsistentNativeGeometry,ScoreInteractionUITests/testScoreStorageRecoveryConfirmationAndPersistence` |
| `Modules/ScoreFeature/Sources/ScoreRootView.swift:TrustedTranscriptPage` | `{"AppEmptyState":1,"AppFailureState":2,"AppSMSVerificationSheet":1,"Button":2,"ScrollView":1}` | `ScoreInteractionUITests/testTrustedTranscriptSMSRetryPreviewAndCancellation,ScoreInteractionUITests/testTrustedTranscriptReapplicationKeepsAvailablePages` |

滚动容器使用稳定身份参与源码与运行证据核对。手势检查与位置恢复沿实际 UIKit 滚动对象定位，页面路径身份用于交互库存归属。UI 用例在操作前验收当前容器：可滚动内容通过原生滑动核对位置变化并恢复起始位置，完整显示的内容核对边界并记录 `scroll-fit`；容器动作与子控件动作分别核对。底栏选中项变化记录 `tab-switch`，用于 TabView 的独立切换证据。

## UI 性能场景

| 用例 | 验收内容 |
| --- | --- |
| `MaintenancePerformanceUITests/testStartupPerformance` | 重置夹具存储，结束 App 进程并启动至课表就绪，采集时钟及 App 物理内存 |
| `CommunityInteractionUITests/testPosterSubscriptionsPersistAndAppearInFavorites` | 话题详情选择收藏、更新和评论订阅，收藏列表重开详情及取消插眼，查看插眼消息分类 |
| `MaintenancePerformanceUITests/testScheduleWeekLayoutPerformance` | 启用动画，课表执行十组前后切周，核对周次及采集布局耗时与 App 物理内存 |
