# UI 交互覆盖

## 验收约定

用户要求 UI 自动化覆盖每一个可点击、可滑动和可交互部位。维护范围按控件与操作行为清点：点击、文本输入与键盘提交、选择与开关、列表滚动与下拉刷新、分区横滑、课表周次拖动、长按菜单、双指缩放、Sheet 下滑关闭，以及确认、取消、成功、失败和重试分支。日期、周次、评分等值域由控件类型与业务状态断言验证。

- 用例分布在 [日程与社区流程](../BIT101-iOSUITests/LoginAndScheduleUITests.swift) 、[社区发布流程](../BIT101-iOSUITests/CommunityPublishingUITests.swift) 和 [综合交互流程](../BIT101-iOSUITests/InteractionCoverageUITests.swift)，共用 `UIAutomationTestCase`；[性能场景](../BIT101-iOSUITests/MaintenancePerformanceUITests.swift) 独立测量 App 启动与切周布局。
- 完整批次顺序执行，各用例独立启动并结束 App 宿主，单个流程内复用进程并校验同一进程 ID；话廊偏好、学校 DDL 完成状态和自定义日程场景结束旧进程，以新进程恢复会话和磁盘数据。
- 同页操作复用创建、导航和编辑过程，下表保留逐控件与业务分支的映射；同一流程可以对应多行。
- 业务交互采用原生触摸与滚动，字段通过实际输入控件更新，公共键盘规范采用系统键盘；公共查询规范显式验收快速查询及控件动作与原生状态的一致性。
- 运行耗时与操作类型从真机运行的固定指标文件读取。

## 设备与窗口规范

- 静态规则核对一级分组的公共背景样式及公共浏览行的选择归属。
- 浏览导航复验覆盖冷启动后多轮切换成绩、话廊、日程入口，要求分区栏可点击并使用主导航下方的标准内容间距。
- `testScheduleChromeSurvivesRotations` 从设置详情进入日程，保持日程选中并连续六次切换方向，逐次核对刷新行位于主导航下方、竖屏分区栏可操作及选中周次。
- `testMineSettingsFillAvailableDetailWidth` 逐一进入账号、日历、DDL、话廊和关于设置，确认实际选中目标后，要求右侧列表或滚动区域达到可用详情宽度的 95%。
- `testClassroomLoadingKeepsThePageBackground` 保持首次空教室查询进行中，比较左右区域的实际背景像素并采样截图。
- 截图先从活跃屏幕选择含可见内容的图像，Duo 内外屏通过同一流程采样。
- 空成绩行与刷新行比较实际背景像素，并核对分组行两端的背景；iPad 与 Mac 的详情滚动后继续核对原生标题栏的遮蔽底色，iPhone 与 Duo 验收系统导航行为，成绩与课程行共同验收整行点击和浅色选中背景。

`LandscapeLayoutUITests` 在支持宽幅布局的设备上核对实际横屏姿态，再验收空教室和个人页分栏、话题与文章及成绩和课程的列表与详情分栏、课表与单列 DDL 并排、地图工具、表单草稿及辅助功能字号；同时比较各页侧栏宽度、主导航周围及刷新/统计/搜索行的实际背景像素，并核对选中行背景、悬浮按钮竖向排列与列表边缘、详情分组单元格的分栏边缘。旋转流程验证详情回到竖屏列表、重新进入全宽详情，以及分区栏和主导航的范围。Duo 横屏验收前由 Device Hub 设置实际姿态。普通 iPhone 与 Duo 外屏核对竖屏方向限制，Duo 内屏和 iPad 核对横竖切换。原生 UI 操作按实际窗口边缘核对键盘工具栏，系统照片选择器按系统元素身份识别并完成取消。UI 流程按设备导入选图样本，设备偏好记录导入状态并随设备抹除重置。

- `testCompactWindowKeepsSystemBars` 核对紧凑窗口内的系统主导航、分组行水平范围、顶部标准间距与竖屏课表底部间距，并保存列表及课表截图，再核对节次筛选整页导航及返回。
- `testWindowChangesKeepInsets` 在系统提供分隔区域的窗口执行连续展开、折叠和重新展开；Device Hub 按逐行写入的 `Layout phase: close` / `Layout phase: open` 日志切换姿态，分别验收紧凑列表和恢复后的系统分隔位置。
- 几何记录包含当前窗口、场景、安全区和分隔区域。
- 横屏按内容末端与系统安全区对照核验，竖屏按课表及悬浮操作的模块间距核验。
- `testLandscapeDetailBackUseRightPanePane` 验收右栏返回键的位置、成绩排序返回占位、节次筛选右栏呈现及选择后的结果恢复。
- 分栏宽度通过同一检查核对真实列表行的左右标准边距和滚动区边缘，左栏及右栏详情共用该规范。

`simulator build-ui` 构建共享 UI 宿主；类型切换保留已准备设备的应用容器，并关闭上一台活跃项目设备；`BIT101_SIMULATOR_DEVICE_TYPE` 选择目标类型。本地 `simulator preview` 构建并打开隔离样例界面，供 Device Hub 中持续观察姿态与布局；`simulator merge` 归集 CI 分片。测试结束后恢复常规 Release；预览结束后执行 `simulator restore`，`simulator inspect` 读取安装身份与实际屏幕。恢复结果核对进程、会话和活跃场景。

## 公共组件验收归属

公共组件的每类交互规范明确验收流程，相同交互集中验证一次；每个使用页面验证入口、绑定参数和业务结果。同一控件的布局或事件实现独立时，各自保留完整验收。测试归属静态明确，关键词运行直接执行所选流程。

| 公共实现 | 完整交互规范 | 页面接入验证 |
| --- | --- | --- |
| `AppVerificationSheet` | 图形验证覆盖图片、大小写、手动提交、阶段续接与拒绝后的重新发起；成绩流程验证空提交禁用、系统键盘逐位输入及手动验证、整段填入自动验证、错误提示、修改重试、取消和成功；验证码清洗、长度范围及自动提交策略由模块测试覆盖 | 课表、学校 DDL 和可信成绩单验证各自取消后的恢复、提交文案及自动验证后业务继续；课表与成绩单的错误保留 challenge、修改后继续和持久化由行为测试验收；SSO 面板复用同一输入实现 |
| `ScoreFilterPage` | 学期筛选验证全选 / 清空和逐项切换 | 学期及类型分别验证绑定状态和成绩过滤结果 |
| `CommunityCommentSortPicker` | 话题评论验证最新 / 高赞 / 最旧全部选项 | 文章评论验证排序入口、选择绑定及加载结果 |
| `CommunityPaginationFooter` | 机器人分页验证继续加载，分页恢复验证失败原因、原位重试和后续内容 | 话题、文章、课程及评论保留各自分页游标和列表内容 |
| 确认框控件查询 | 公共查询规范与原生 XCTest 比较控件属性，并通过真实点击验证关闭后恢复 | 各页面保留自身确认 / 取消与业务结果 |
| 原生日期时间选择器 | DDL 流程验证翻月、年月选择、日期选择及逐列时间滚轮 | 自定义日程逐个打开日期 / 开始 / 结束入口，验证时间绑定、保存和重新读取 |
| `AppCommentComposerContentSection` | 课程评论验证匿名开关，并与评分和发布结果一起验收 | 话题及文章保留各自评论 / 回复提交和取消；匿名发布属于各自编辑器规范 |
| `KeyboardDismissSupport` | 课程评论通过系统键盘输入并实际点击完成按钮，登录验证空白点按、滚动收起及键盘提交 | 各页面验证完整字段值、实际控件绑定及业务结果 |
| `systemImagePreview` | 可信成绩单验证多页切换和关闭，话题流程验证打开预览时的场景销毁 | 卡片、正文、评论、头像和成绩单第二页分别验证来源入口及返回页面 |

文章搜索、点赞、发布和编辑分别归入已有连续页面流程；课程搜索、点赞、评分、发布与回复在同一详情中连续验收。文本表单通过实际输入控件连续填写，公共键盘规范集中验证聚焦、输入与收起，重新读取后的设置状态完成断言后交由下一场景的隔离重置清理。

UIKit 控件按构造类型、继承或别名进入源码清单，运行门禁核对输入、滚动、手势与菜单回调的实际证据。静态辅助功能标识通过对应变量或原生控件类型解析；目标动作和菜单闭包通过交互观察器记录实际执行。只读富文本核对正文点按及链接动作，滚动载体与其原生手势分别核对动作类型。

完整覆盖以源码控件、动作类型和归属用例为单位，每项对应已观察实例上的实际动作。同一原生控件的无障碍包装按相同标识及几何合并，祖先行保留业务身份。挂载库存记录各次弹窗、日期值和禁用状态的观察与待访问项，供定位覆盖缺口；值域与互斥分支由所属行为断言和公共组件规范验收。

## 日程、登录和地图

下表列出完整测试选择参数，例如 `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes`。

| 用例 | 操作与结果 |
| --- | --- |
| `ScheduleLayoutUITests/testAccessibilityQueryParity` | 实时查询与原生 XCTest 比较标识、类型、禁用状态、可触达状态和布局；原生点击 / 无障碍激活后的状态一致，真实触摸聚焦、聚焦前后字段绑定、键盘完成、导航返回、确认框控件、场景标识 / 窗口坐标与取消恢复 |
| `AccountRecoveryUITests/testLoginSubmitButton` | 学号 / 密码、必填禁用、键盘焦点、进入日程；键盘提交由账号退出后重新登录流程验证 |
| `AccountRecoveryUITests/testLoginSubmitButton` | 输入、滚动收键盘、登录按钮提交、进入主界面 |
| `ScheduleEditingUITests/testMainTabsRemainType` | 五个 Tab、离线提示关闭、选中状态 |
| `ScheduleEditingUITests/testMainTabsRemainType` | 浅 / 深色大字号、Tab 点击、主要内容可见与可触达 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetails` | 添加日程、保存、重新装载恢复 |
| `ScheduleEditingUITests/testCustomSchedulesAreIsolatedAccounts` | 退出、改账号登录、账号日程隔离 |
| `LoginAndScheduleUITests/testScheduleWeekButtonsAndSectionSwipes` | 上 / 下一周、指定周、课表 / DDL / 空教室横滑与点击 |
| `ScheduleLayoutUITests/testScheduleKeepsWeek` | 横竖屏切换保留周次、课表内容、操作入口及主导航 |
| `ScheduleLayoutUITests/testWeeklyHeaderKeepsItsCompactDateRow` | 26 点日期行及 44 点周次触控高度 |
| `ScheduleLayoutUITests/testSideToolbarUsesSpaceAboveNavigation` | 地图、话题、文章、课表及 DDL 的原生侧方工具栏边缘、竖向排列，以及系统更多菜单中的完整标题与可触达状态 |
| `LandscapeLayoutUITests/testWindowUsesAdaptivePanes` | 当前窗口的资料 / 空教室分栏、话题 / 文章 / 成绩 / 课程列表与详情分栏、公共侧栏宽度、导航背景像素与刷新行边缘、课表与单列 DDL 并排、地图图层切换、编辑草稿与键盘收起、辅助功能字号单列 |
| `LandscapeLayoutUITests/testAcademicBrowsersKeepTheSharedChrome` | 成绩 / 课程原生入口、列表与详情分栏、切页详情保留、与日程 / 话题 / 文章共享侧栏宽度及顶部背景 |
| `LandscapeLayoutUITests/testGallerySurfaceChangesNavigation` | 话题与文章反复切换后的主导航与分区栏间距、当前操作入口及实际截图 |
| `LandscapeLayoutUITests/testMineSettingsFillAvailableDetailWidth` | 逐一选中账号 / 日历 / DDL / 话廊 / 关于设置，核对右侧列表或滚动区域占满可用详情宽度 |
| `LandscapeLayoutUITests/testScheduleChromeSurvivesRotations` | 从设置详情进入日程并保持选中，连续六次横竖旋转，核对刷新行与主导航边缘、竖屏分区入口及当前周次 |
| `CommunityRecoveryUITests/testArticleCountersUpdateVisibleListDetail` | 文章详情点赞与评论后的卡片计数、横屏同屏展示与紧凑窗口返回列表 |
| `LandscapeLayoutUITests/testSchoolCaptchaCanBeCancelled` | 图形验证图片、大小写、手动提交、取消重试、切换短信阶段清空输入及原课表查询继续 |
| `LandscapeLayoutUITests/testRejectedSchoolCaptchaRequiresChallenge` | 图形验证码失败后结束挑战、保留拒绝提示与重新发起 |
| `LandscapeLayoutUITests/testClassroomSmsUsesNativeDestination` | 空教室入口触发短信验证、当前页面承载验证、验证后续接查询与分区保持 |
| `LandscapeLayoutUITests/testClassroomLoadingKeepsThePageBackground` | 宽幅空教室首次查询期间，比较侧栏和空结果区域的实际背景像素并记录截图 |
| `LandscapeLayoutUITests/testLandscapeEdgesAndColumnBoundaries` | 横屏课表及悬浮按钮的底部安全区边缘、各页统一分栏位置、Duo 系统分隔位置与顶部标准间距，iPad 双横屏方向复验 |
| `LandscapeLayoutUITests/testCompactWindowKeepsSystemBars` | 紧凑窗口原生主导航及分组行边缘、顶部标准间距、竖屏课表及悬浮操作底部间距与实际截图；课表 / DDL / 空教室切换时核对可见列表刷新行与时间文字的顶部边缘，空教室节次筛选整页进入及返回后再次核对 |
| `LandscapeLayoutUITests/testWindowChangesKeepInsets` | 连续展开、折叠及重新展开，紧凑列表安全范围及宽幅浏览列表按系统分隔位置恢复 |
| `LandscapeLayoutUITests/testLandscapeDetailBackUseRightPanePane` | 右栏左上侧返回键、成绩排序返回占位、空教室节次筛选右栏呈现、选择、横竖屏导航续接及返回查询结果 |
| `LoginAndScheduleUITests/testScheduleDayHolidayCancel` | 每日表头、放假 / 调休选择、确认取消、窗口取消 |
| `ScheduleNavigationUITests/testHolidayAndTransferConfirmedMutations` | 放假确认、调休日期控件、调休确认、原日期和目标日期课程变更 |
| `LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch` | 线性时间轴上下滚动、双指放大 / 缩小、缩放值更新及画布左边缘对齐 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersToggles` | 时间轴、显示方式、内容选择、周末 / 考试开关、主课表改名与重新装载恢复 |
| `LoginAndScheduleUITests/testCalendarOfflineTermFailureAndCancel` | 学期入口、学校离线提示、关闭失败提示和返回设置 |
| `CalendarInteractionUITests/testCalendarReminderCloudSwitches` | 两类云开关、提醒确认取消 / 开启、阈值滚轮保存 / 取消、重新装载状态、当前及其他账号的云端偏好清理确认 / 取消 / 结果与同步暂停 |
| `LoginAndScheduleUITests/testCalendarSettingsPickersToggles` | 时间表非法输入、有效保存、取消保留、课表改名取消 |
| `ScheduleConflictUITests/testRecoveredScheduleRequiresConfirmation` | 日程恢复核对、读取重试、明确确认、后续编辑与冷启动重载 |
| `ScheduleConflictUITests/testDamagedRootRebuildRequiresConfirmation` | 损坏根文件的所属日程重建、取消 / 确认、编辑恢复与冷启动重载 |
| `ScheduleConflictUITests/testDdlSettingsResume` | DDL 设置恢复核对、读取重试、编辑状态、确认后的滚轮保存与冷启动重载 |
| `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefresh` | 学期下拉刷新 / 切换、日期滚轮取消、手动日期按首周周一保存 / 重新装载恢复 / 学校日期、校区 / 教学楼 / 教室刷新、订阅及学校 DDL 刷新 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetails` | 日程详情、编辑保存、删除、新增取消 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetails` | 空标题提示与草稿保留、地点 / 描述编辑、详情、单项日历导入 / 移除 |
| `CalendarInteractionUITests/testCustomScheduleEmptyTitleDetails` | 日期 / 开始时间 / 结束时间选择器、开始 / 结束时间绑定、线性轴显示任意时间、编辑取消保留 |
| `ScheduleLayoutUITests/testRecurringSchedulesUseDisplayedWeek` | 上下间距一致、课程及日程默认显示周次、日程多周点选、整组编辑 / 删除与进程重启恢复 |
| `ScheduleEditingUITests/testCourseEditorFieldsPickersSaveDetail` | 课程名称 / 教师 / 教室、周次点选、星期 / 起止节次、保存、调课入口、删除确认 / 取消 |
| `CalendarInteractionUITests/testCourseAndExamSystemCalendarActions` | 单节及整门编辑模式、楼宇 / 房间号、周次 / 星期 / 节次多选、保存结果、单节删除确认 / 取消 |
| `CalendarInteractionUITests/testCourseAndExamSystemCalendarActions` | 单节 / 整门 / 考试日历导入与移除、重复移除结果、整学期导入及删除确认 |
| `CalendarInteractionUITests/testCalendarImportHistoryKeepsAvailable` | 导入索引受损提示、重建确认 / 取消、重建结果与恢复后的学期导入 |
| `CommunityRecoveryUITests/testPreviewPageRecoversNativeRetryButton` | Quick Look 后续页故障、原生重试控件、原位恢复与关闭 |
| `ServiceInteractionUITests/testSchoolSmsCourseSyncValidationCancel` | 学校课表刷新、短信取消、验证继续和课程保存 |
| `LoginAndScheduleUITests/testScheduleCopyImportRenameCycle` | 分享编码复制、剪贴板粘贴、导入、改名、课表上下滑循环、分享课表左滑删除 |
| `ScheduleEditingUITests/testLongPressOpensScheduleContextMenu` | 空白区长按、导入菜单、输入 Sheet |
| `ScheduleEditingUITests/testImportInvalidCodeReportsError` | 无效编码、错误提示、保留输入、取消 |
| `AccountRecoveryUITests/testFutureScheduleImportUpdateCancel` | 新版本编码、更新提示取消、App Store 目标地址 |
| `ScheduleNavigationUITests/testEmptyShareAndImportGuideCancel` | 空分享取消、导入说明取消、新增 Sheet 下滑关闭 |
| `ScheduleNavigationUITests/testScheduleWeekStripScroll` | 周次栏拖动、课程长按分享、空白区长按分享、课表系统分享面板 |
| `ScheduleNavigationUITests/testDdlEditorDetailsCancelEditingEditing` | 手动待办新增 / 编辑、完成状态、详情、删除、取消 |
| `ScheduleNavigationUITests/testDdlEditorDetailsCancelEditingEditing` | 空标题校验、详情输入、日历翻月 / 年月滚轮 / 日期选择、逐列时间滚轮、取消修改 |
| `LoginAndScheduleUITests/testDdlSettingsWheelSaveCancel` | 滞留天数滚轮、保存 / 取消、重新装载恢复 |
| `ScheduleEditingUITests/testSchoolDdlSources` | 两类学校日程、详情来源、完成按钮、重新装载恢复 |
| `ScheduleLayoutUITests/testDeadlineWidgetLinkOpensTheDDLSection` | DDL 小组件链接、当前账号待办、课表小组件链接 |
| `ScheduleLayoutUITests/testDeadlineWidgetAppearsInSystemGallery` | 系统小组件库、DDL 扩展真实预览 |
| `ScheduleEditingUITests/testDdlEmptyStateExplainsRetentionWindow` | 过期日程与滞留范围说明 |
| `ServiceInteractionUITests/testSchoolSsoddlVerifyCancel` | 学校 DDL 刷新、SSO 短信取消、验证继续、刷新结果 |
| `CalendarInteractionUITests/testSchoolTermsClassroomPickersRefresh` | 空结果刷新、节次单选、全选 / 全不选、清除筛选与状态 |
| `LoginAndScheduleUITests/testMapCampusLayerPanAndZoomPersist` | 三个校区、图层、地图平移 / 双指缩放、重新装载恢复、公共按钮边缘及系统更多菜单操作 |
| `ScheduleNavigationUITests/testMapLocationAndScheduleLocationRoute` | 课程地点进入地图、定位 / 单次权限、下一节课导航到 Maps、返回 |

## 成绩与课程

| 用例 | 操作与结果 |
| --- | --- |
| `ScoreInteractionUITests/testScoreDetailFollowsDetailedRefresh` | 横屏双栏中打开简略成绩，详细字段到达后原位更新详情 |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancel` | 查询、短信输入、验证继续、成绩展示 |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancel` | 空 / 错误 / 正确验证码、公共筛选页全选和清空、学期 / 类型独立绑定、六种排序、方向、成绩详情 |
| `ScoreInteractionUITests/testScoreIndividualFiltersRefreshCancel` | 查询取消、逐项筛选、已有成绩刷新、未出分详情、成绩到课程评价路由 |
| `ScoreInteractionUITests/testTrustedTranscriptSmsRetryPreview` | 申请、短信取消、申请重试、验证成功、部分分页保留与重试、两页点击与 Quick Look 左右滑动 / 关闭 |
| `ScoreInteractionUITests/testTrustedTranscriptKeepsAvailablePages` | 部分报告保留、重新申请与完整分页展示 |
| `ScoreInteractionUITests/testScoreStorageRecoveryConfirmation` | 账号内成绩存储恢复、取消、确认及重新装载 |
| `CommunityInteractionUITests/testCourseCommentPublishSearch` | 课程搜索、详情、历史成绩、课程点赞 / 取消、评分评论发布 |
| `CommunityInteractionUITests/testCourseCommentPublishSearch` | 清除搜索、数据清洗开关、原生半星评分增减 / 归零、匿名 / 取消、评论点赞 / 图片 / 回复、课程分享 |
| `ScheduleNavigationUITests/testCourseHistoryChartSelection` | 成绩 / 课程横滑、历史图双向拖动和学期选中值 |
| `CommunityInteractionUITests/testStableRowsPaginateAgain` | 课程与文章列表滚动续页、下拉刷新相同对象、再次滚动续页 |
| `ScheduleNavigationUITests/testCourseScheduleAcademicRoute` | 学校课程进入匹配评价、帖子作者及评论昵称进入公开主页 |

## 话廊、文章与消息

| 用例 | 操作与结果 |
| --- | --- |
| `CommunityRecoveryUITests/testLongPost` | 长帖与长评论完整阅读、原生文本末尾与返回页面 |
| `InteractionCoverageUITests/testGalleryFeed` | 五类话题、搜索 / 清除、四类消息 / 全部已读 |
| `CommunityInteractionUITests/testGalleryBlockingUpdatesLoadedFeeds` | 已加载列表屏蔽作者、过滤状态更新、解除屏蔽后恢复内容 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSorts` | 帖子详情、帖子点赞 / 取消、评论发送、编辑入口 |
| `CommunityPublishingUITests/testGalleryComposerTagsSettingsPublish` | 发布校验、系统下拉关闭保护、编辑中后台返回、草稿保存 / 加载 / 丢弃、标准 / 自定义标签、删除标签、匿名 / 公开、发布、删除确认 / 取消 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSorts` | 帖子标题 / 正文保存、声明选择、保存后详情和列表同步 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSorts` | 评论长按复制 / 举报 / 删除、原因输入、提交、删除取消 / 确认 |
| `CommunityInteractionUITests/testPosterReportSelectionCancel` | 卡片及详情举报、分类失败 / 重试、类型选择、取消、说明提交、成功返回 |
| `InteractionCoverageUITests/testCommunityCommentLikesRepliesSorts` | 评论排序、点赞 / 取消、回复、评论照片选择器取消 |
| `InteractionCoverageUITests/testGalleryFeed` | 话题及消息双向横滑、消息关联详情、两类搜索结果进入详情、文章排序 |
| `InteractionCoverageUITests/testCommunityMediaPreviewsDraftRetry` | 卡片 / 帖子 / 评论图片预览、预览打开时切换场景并恢复原进程页面、原有图片移除及取消、新图上传失败 / 重试 / 成功 / 移除、照片选择器取消、建议图片移除 / 放弃草稿 |
| `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete` | 文章标题 / 简介 / 正文发布、评论发布、编辑保存、取消后继续编辑 / 确认放弃、再编辑、删除确认 / 取消 |
| `InteractionCoverageUITests/testGalleryFeed` | 文章搜索 / 清除、搜索结果及详情路由 |
| `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` | 顶部及页尾点赞 / 取消、文章评论回复、评论取消 |
| `CommunityPublishingUITests/testPaperPublishEditCommentAndDelete` | 编辑器字段、空发布校验、匿名发布、编辑取消 |
| `CommunityPublishingUITests/testDamagedPaperDraftStorageRecovers` | 草稿存储恢复取消 / 确认、当前输入保留、恢复后暂存及再次读取 |
| `CommunityInteractionUITests/testPaperImagePreviewCommentsSortAndShare` | 正文链接、正文图片预览、页尾点赞及顶部同步、评论排序绑定、文章分享、评论取消 |
| `InteractionCoverageUITests/testGalleryFeed` | 话题及文章搜索排序、搜索刷新、文章列表双向排序横滑 |
| `InteractionCoverageUITests/testGalleryFeed` | 话题 / 文章列表及详情、消息、文章搜索下拉刷新；竖向刷新保留分类；首尾分类向外横滑在话题 / 文章之间切换、隐藏机器人开关与顶部分栏同步、隐藏当前机器人分栏后回到推荐 |
| `InteractionCoverageUITests/testBotFeedContinuesAcrossEmptyScanBatches` | 机器人首屏与续页按批结束空扫描；继续入口按源游标查找后续帖子 |
| `CommunityRecoveryUITests/testCommunityPaginationRetriesVisibleTail` | 课程、文章列表及搜索、话题分页故障保留当前位置，页尾重试从原游标继续展示内容 |
| `CommunityRecoveryUITests/testIdenticalFeedRefreshKeepsPosition` | 相同首屏下拉刷新、受控分页与列表位置保留 |
| `CommunityEditingRecoveryUITests/testReportEditing` | 举报说明下滑保护、放弃确认、提交期间载荷保护与回执 |
| `CommunityEditingRecoveryUITests/testContentControlsRemainSizes` | 浅色及深色的大字号课程卡片、评论操作、头像统计、长标签横滑与分区切换 |
| `ScheduleEditingUITests/testScheduleEditorsProtectChangedInput` | 自定义日程及 DDL 输入保留、下滑保护、继续编辑与明确放弃 |
| `ScheduleEditingUITests/testCourseStartSectionKeepsItsEndValid` | 提高课程开始节次、关闭保护与有效节次保存 |
| `CommunityRecoveryUITests/testCourseLookupFailureKeepsSearchIdentity` | 两路检索故障后转入原生课程搜索，保留课程名称并展示可选择的结果 |
| `CommunityRecoveryUITests/testDuplicatePagesKeepVisibleTailLoading` | 课程、文章与个人帖子跳过重复页后自动继续，保留实际行任务生命周期 |
| `CommunityRecoveryUITests/testMessagePaginationRetriesAtVisibleTail` | 消息后续页故障提示、页尾原位重试与已加载消息保留 |
| `CommunityRecoveryUITests/testMessageReadStorageKeepsAvailable` | 消息已读存储受损时保留正文、读取重试、恢复取消与确认、恢复后继续展示 |
| `CommunityEditingRecoveryUITests/testCommentEditorsProtectDiscard` | 三类评论输入的下滑关闭保护、继续编辑与明确放弃 |
| `CommunityEditingRecoveryUITests/testCommentBodiesShareLinksImages` | 话题、课程和文章评论统一展示链接、图片并进入系统预览 |
| `CommunityEditingRecoveryUITests/testPosterImageWhitespaceOpensDetails` | 单图右侧空白打开帖子详情，图片独立进入原生预览 |
| `CommunityEditingRecoveryUITests/testCourseCommentsRecover` | 慢评论期间展示历史成绩、评论首屏故障原位重试、详情下拉刷新 |
| `CommunityEditingRecoveryUITests/testFailedPaperSortKeepsDisplayedVisible` | 排序故障保留已有文章、标明结果实际条件、新条件成功后更新提示 |
| `CommunityEditingRecoveryUITests/testUploadedCommentImageCanBePreviewed` | 系统照片选择、上传故障后重新选择、预览和移除图片、文字保留 |
| `CommunityEditingRecoveryUITests/testSuggestionSaveWaitsSelectedImageImport` | 系统照片选择、导入期间保存等待、已选图片与文字重载 |
| `CommunityRecoveryUITests/testCommentReviewContinuesSubmission` | 评论结果待确认、人工核对确认 / 取消、同一内容再次发送 |
| `CommunityRecoveryUITests/testMessages` | 文章与课程消息打开各自原生详情，课程收藏进入原生课程页 |
| `ServiceInteractionUITests/testOfflineRecoveryRetry` | 离线重试、诊断编辑、原始模式、复现 / 联系方式、确认取消 / 确认、提交失败保留、关闭 |
| `ServiceInteractionUITests/testCommunityFailedRequestsRetryState` | 课程 / 话题 / 文章首次失败、重试到加载成功 |
| `AccountRecoveryUITests/testErrorReportSanitizedSubmission` | 报告打开时切换场景并清理全局呈现器、报告原始 / 脱敏切换、缺少联系方式继续提交、受理后响应丢失保留完整载荷并重试、提交成功关闭、列表重试恢复 |
| `AccountRecoveryUITests/testWebGallerySettingReturn` | 网页开关、WebKit 上下滑动、重新装载保留、切回原生列表 |

## 我的、设置与反馈

| 用例 | 操作与结果 |
| --- | --- |
| `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` | 个人统计入口、用户行进入公开主页、关注成功 |
| `MineInteractionUITests/testMinePublicProfileFollowAndPostDeletion` | 粉丝 / 关注 / 帖子列表刷新、公开主页关注状态、头像预览、统计显示 / 刷新、公开帖子详情 / 下滑关闭、个人帖子详情、删除取消 / 确认 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 学号 / UID 显示和隐藏、昵称 / 签名编辑取消、头像选择器取消 |
| `InteractionCoverageUITests/testAccountProfileSaveLoginCheckAndLogout` | 昵称 / 签名保存及重新加载、学校密码更新、登录检查、社区安全密码输入与取消、认证失败重试、退出、重新登录 |
| `CommunityPublishingUITests/testGallerySettingsValidationToggles` | 机器人 / 匿名 / 网页开关及持久化状态、屏蔽 UID 校验 / 键盘提交 / 保存 / 重新装载 |
| `CommunityPublishingUITests/testSuggestionDraftRestoreAndDiscard` | 建议 / 联系方式输入、空提交禁用、下滑关闭保护、草稿保存 / 加载 / 丢弃 |
| `InteractionCoverageUITests/testSuggestionMissingContactSubmitFailure` | 图片选择器取消、缺少联系信息返回补充 / 继续、提交失败保留、草稿丢弃 |
| `ServiceInteractionUITests/testSuggestionSuccessfulDiscardSavedDraft` | 草稿放弃加载、提交确认、受理后响应丢失保留完整载荷并重试、成功关闭、草稿清理 |
| `ServiceInteractionUITests/testSuggestionSubmissionProtectsPayload` | 提交期间正文 / 联系方式 / 附件与关闭控件禁用、下滑关闭保护、原请求完成后关闭 |
| `ServiceInteractionUITests/testRecoveredSuggestionPreservesContent` | 待确认建议附件部分恢复、文字 / 联系方式 / 可用图片保留、新建议身份确认 / 返回核对、保存重载与提交 |
| `InteractionCoverageUITests/testCacheLimitPersistenceReset` | 缓存上限输入 / 重新装载保留、缓存清理、文稿删除确认、返回登录、测试日程清理 |
| `InteractionCoverageUITests/testSettingsRecoveryPreservesSchedule` | 设置快照恢复入口、取消 / 确认、偏好重新保存与加载、账号及已有日程保留 |
| `CommunityPublishingUITests/testAboutLicenseUpdateAndResetConfirmation` | 开源声明滚动、自动更新开关、离线检查提示、重置取消 |
| `ServiceInteractionUITests/testManualUpdatePromptAllActions` | 新版本本次忽略 / 忽略此版本 / App Store、当前版本提示 |
| `CommunityInteractionUITests/testExternalLinksAbout` | 关于页备案、仓库、QQ、邮件、课程共享资料目标 URL |
| `ScheduleNavigationUITests/testNetworkDiagnosisProgressAndReport` | 网络诊断触发、八步汇总、结束后恢复按钮 |

## 测试数据与平台动作

| 配置 | 场景 |
| --- | --- |
| `BIT101_UI_TEST_CONTENT=1` | 内存 HTTP 响应，经过生产社区 Service 解码；维护发布、编辑、删除、点赞、评论、关注和资料变更；反馈提交返回合成成功响应 |
| `BIT101_UI_TEST_SCHOOL=1` | 当前周起始日期、学校课程 / 考试、两个学期、两个校区 / 楼宇、空教室和学校 DDL 固定响应 |
| `BIT101_UI_TEST_SCHOOL_CAPTCHA=1` | 课表先显示图形验证码，`aB12` 进入短信阶段，`123456` 继续查询；错误图形码结束挑战 |
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

所有测试凭据、文件、偏好和媒体缓存归隔离会话与测试目录。系统日历确认通过内存 `SchedulePlatformActions` 验收，偏好云同步使用内存 `PreferenceCloudStoring`。外部链接通过 UI 宿主接收页面实际 URL，并展示完整目标供断言。地图导航交给 Maps。测试清理场景使用隔离文件和偏好清理动作。常规 Release 由测试脚本恢复。

真机专项范围包括系统凭据及短信建议的实际自动填充、照片库真实选择与读取、系统日历 / 通知授权与实际日历写入、浏览器 / 邮件 / App Store 的系统交接、网页自身交互、Widget 与 Watch 界面。专项验收记录对应设备、系统权限和运行证据。

## 执行流程

学校短信复用 `AppSchoolSMSVerificationSheet` 的原生输入规范；`LoginLogicTests` 验证 UIKit 认证入口的面板组装、等待既有提示、取消与整段输入续接。

`Scripts/check-ui-consistency.py` 读取 `Scripts/ui-interactions.json`，核对源码控件数量及负责验证的测试。静态库存覆盖 App、Modules、Watch 和两种 Widget 中的 SwiftUI、UIKit 控件及回调；完整运行按独立实例核对点击、输入、选择、长按、滑动、刷新和键盘提交证据。动态文案使用稳定标识，禁用分支由页面断言与公共组件规范共同验收。

页面流程使用原生 XCTest 触摸、滚动与手势，验证入口、参数绑定、业务结果和持久化重载。共享查询规范对照 App 渲染状态与 XCTest 原生状态，覆盖标识、类型、禁用状态、可触达性、布局及覆盖层遮挡。同一界面状态复用查询与快照；操作和状态等待刷新读取结果。导航按稳定控件身份定位，适配系统底栏和侧栏。

公共更新时间行验收同时核对日程分区栏的窗口安全距离，并按窗口几何比较课表、DDL 和空教室顶部位置。课表底部验收根据实际系统导航栏位置计算：底栏窗口保留操作间距，侧栏与顶部导航窗口利用完整底部内容空间。

字段通过原生触摸聚焦，核对第一响应者、命中控件及完整输入值。登录、密码、键盘提交和公共 TextView 规范使用系统键盘；公共字段规范比较键盘输入与控件输入后的绑定和业务结果。键盘附件验证实际按钮和焦点切换，背景收键盘操作遵循当前页面内容区域及系统键盘的触摸范围。

公共按钮、开关和菜单规范对照原生操作与实际控件事件，核对最终状态和持久化结果。系统照片、日期和预览界面通过 XCTest 定位与操作；取消和返回确认目标页面或弹窗已经关闭。滚动、分页、拖动和缩放由实际手势触发，业务断言完成后验收当前滚动容器。系统通知横幅由共享短按路径处理，业务提示由所属页面流程断言。

完整批次串行执行，各用例独立启动并结束宿主。单个流程内复用进程，重建页面及模型，并按场景重置隔离数据、提示队列和迟到任务；冷启动专项保留账号数据，核对新进程和磁盘恢复结果。场景回复与界面快照共同核对进程、页面版本及初始状态。连续编辑、短信重试、媒体预览和多层弹窗场景采用系统动画，其余场景按对应运行配置执行。

开发复验将受影响的类名或方法关键词合并为一次调用，完整验收运行整个 UI 组。运行期间保持 BIT101 前台并暂停手动操作。失败现场保留 App 状态、原始结果包、截图和元素树；真机验收结束后统一恢复常规 Release App。

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh build ui
Scripts/run-static-audit.sh
```

完整验收核对源码库存中的全部用例、参数实例和交互规范。运行库存按场景、导航路径与稳定控件身份维护，挂载实例中的待访问项用于诊断；页面矩阵和业务断言维护页面及分支范围。性能用例采用独立的启动和测量流程。

报告记录构建、执行、恢复和工作流总耗时，以及用例耗时、最慢项、进程身份和交互统计。查询与快照的阶段耗时用于定位开销，原始日志保留各阶段的重叠采样。编译保存到 `ui-tests-build.log`，执行保存到 `ui-tests.log`；原始结果和指标使用固定的 `test-results.xcresult`、`test-metrics.txt`，诊断附件按需导出到 `diagnostics/`。

## UI 性能场景

| 用例 | 验收内容 |
| --- | --- |
| `MaintenancePerformanceUITests/testStartupPerformance` | 重置测试存储，结束 App 进程并启动至课表就绪，采集时钟及 App 物理内存 |
| `CommunityInteractionUITests/testPosterSubscriptionsPersist` | 话题详情选择收藏、更新和评论订阅，收藏列表重开详情及取消插眼，查看插眼消息分类 |
| `MaintenancePerformanceUITests/testScheduleWeekLayoutPerformance` | 启用动画，课表执行十组前后切周，核对周次及采集布局耗时与 App 物理内存 |
