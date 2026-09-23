# BIT101-iOS 源码索引

这份文档维护模块入口和职责地图。新增同模块文件时保持目录归属。

## 应用入口

- `BIT101-iOS/BIT101_iOSApp.swift`：应用入口、全局主题、方向策略。
- `BIT101-iOS/ContentView.swift`：按登录状态切换登录页和主壳层。
- `BIT101-iOS/Shell/AppShellView.swift`：登录后 tab、全局路由、深链和跨模块弹层。
- `BIT101-iOS/Settings/AppSettingsStore.swift`：全局设置、账号隔离和公告状态。

## 共享层

设计规则按 [UI 设计系统](DESIGN_SYSTEM.md) 分层：`DesignPrimitives.swift` 保存跨 target 基础值，`AppDesignSystem.swift` 保存公共视觉令牌，`AppLayoutComponents.swift` 保存公共布局组件，`AppStateComponents.swift` 保存页面状态组件，`ExternalDesignSystem.swift` 保存外部展示规则。课程、日程与话廊的特化规则分别位于各自模块的 `*DesignSystem.swift` 文件。

- `BIT101-iOS/Shared/Client/`：提供网络、提示模型、深链、更新检查、紧急更新、错误报告提交界面、键盘收起、分页、账号存储、手势、任务取消、偏好同步和网络 smoke。
- `BIT101-iOS/Shared/Client/ErrorReportSupport.swift`：负责反馈脱敏、诊断摘要和提交载荷。
- `BIT101-iOS/Shared/Client/AppErrorPresentation.swift`：负责错误队列、原生提示、恢复操作和报告 Sheet。
- `BIT101-iOS/Shared/DesignSystem/`：提供主 App 的颜色、间距、圆角、评论/建议输入组件、搜索/segmented、更新时间、比例列数据行公共控件和系统触感修饰器。
- `BIT101-iOS/Shared/DesignSystem/AppStateComponents.swift`：提供加载、空态、失败与滚动状态组件。
- `BIT101-iOS/Shared/ScheduleShared*.swift`：定义主 App、Widget、Live Activity 和 Watch 共用的课表快照与 occurrence 规范。
- `BIT101-iOS/WatchSync/WatchScheduleSyncManager.swift`：负责 iPhone 与 Apple Watch 的课表镜像同步。
- `BIT101-iOS/CachedRemoteImage.swift`：缓存头像等远程图片，并使用内存与磁盘存储。

## 业务模块

### 登录

目录：`BIT101-iOS/Login/`

`LoginViews.swift` 是表单入口，`LoginViewModel.swift` 管理状态，`LoginService.swift` 协调登录与会话，`BIT101APIClient.swift` 负责学校与 BIT101 网络请求；其余文件负责模型、存储、加密和 CAS 页面解析。

### 话廊与文章

- `BIT101-iOS/Gallery/`：信息流、搜索、消息、帖子详情、评论、图片缓存和发帖。
- `BIT101-iOS/Paper/`：文章列表、详情、评论、编辑、搜索和点赞。

各模块的 `*RootView.swift` 是页面入口，`*Service.swift` 是网络门面，`*ViewModel.swift` 管理页面状态，`*Models.swift` 保存载荷模型。

### 日程

目录：`BIT101-iOS/Schedule/`

- `ScheduleRootView.swift`：日程页容器和页面路由。
- `CourseScheduleTabView.swift`：课表分栏、周次切换、分享和编辑入口。
- `ScheduleCalendarViews.swift`：按周/全学期课表网格、上下文菜单和页面级课表容器。
- `ScheduleLinearCalendarViews.swift`：线性时间轴、缩放滚动容器和时间轴画布。
- `ScheduleCourseCardViews.swift`：课程/考试/自定义日程块、文字适配和背景层。
- `ScheduleCalendarModels.swift`：网格条目、背景层、时间映射和重叠归一化。
- `ScheduleWeekSliderView.swift`：课表顶部周次滑动条。
- `CourseScheduleTabViewActions.swift`：课表分享、导入、编辑抽屉和课程评价操作。
- `ScheduleEntryDetailView.swift`：课程、考试和自定义日程详情。
- `ScheduleEditingSupport.swift`：课程编辑模式与调休/放假表单。
- `ScheduleModels.swift`：日程领域公共通知与模型入口。
- `ScheduleCoreModels.swift`：课程、考试、DDL、自定义日程和空教室模型。
- `ScheduleCacheModels.swift`：缓存、学期快照和分享课表模型。
- `ScheduleDateCodecs.swift`：日程日期、周次和时间表编解码。
- `ScheduleViewModel*.swift`：同步、学期、空教室、编辑、DDL 和偏好分支。
- `ScheduleService*.swift`：教学中心、乐学、认证、传输及响应模型。
- `ScheduleCacheStore.swift`、`ScheduleWidgetSupport.swift`：缓存持久化和 widget 导出。
- `ScheduleSystemCalendarManager.swift`：系统日历权限、课程/考试/自定义日程导入删除。
- `Shared/Client/NetworkDiagnostics.swift`：网络路径提示、诊断探针、请求记录和诊断缓存。
- `Shared/Client/ErrorReportSupport.swift`：错误报告载荷、脱敏和诊断摘要。
- `Shared/Client/AppErrorPresentation.swift`：诊断弹窗、恢复操作和报告 Sheet。
- `Shared/Client/ReleaseNetworkSmoke.swift`、`ReleaseNetworkSmokeModels.swift`：网络 Smoke runner、探针模型和报告存储。
- 其余解析器、策略、日历、分享和编辑文件按职责拆分，按所属目录查找。

### 成绩与课程

- `BIT101-iOS/Score/`：成绩、筛选、统计、可信成绩单及其独立状态机。
- `BIT101-iOS/Course/`：课程搜索、详情、教师评价、历年成绩和评论。

课程评价入口由 `Course/CourseLookup.swift` 和 `CourseNavigationRequest` 统一承载，
日程课程详情与成绩详情共用检索和跳转逻辑。

`Score` 和 `Course` 均遵循 Models / Service / Servicing / ViewModel / View 的职责划分。

### 地图

目录：`BIT101-iOS/Map/`

`CampusMapScreen.swift` 是地图入口，`CampusNativeMapView.swift` 桥接 MapKit，`CampusMapLocations.swift` 保存校区与教室匹配规则；定位和下一节课解析分别由同目录辅助文件负责。

### 我的与设置

- `BIT101-iOS/Mine/`：个人主页、他人主页、关注关系和帖子列表。
- `BIT101-iOS/Settings/`：账号、外观、课表、DDL、话廊、关于和开发者建议页面；课表设置页与其 sheet 分别位于 `SettingsScheduleViews.swift`、`SettingsScheduleSheets.swift`；建议提交界面在 `SettingsRootView.swift`。

设计一致性检查使用：`Scripts/check-ui-consistency.sh`。
逐份源码质量检查使用：`Scripts/check-code-quality.sh`，结果固定写入 `.build/code-quality-report.txt`。
解释性文案候选报告使用：`Scripts/report-explanatory-text.sh`，结果固定写入 `.build/explanatory-text-report.txt`；扫描范围为 `Section footer` 和 `ContentUnavailableView description`，输出候选报告；文案删除依照用户明确批准执行，白名单收录用户明确批准的文案。

## 自有网页与反馈 API

- `Cloudflare/PrivacyPolicy/`：`privacy.aihelpme.dev` 隐私政策 Pages 源码。
- `Cloudflare/OpenWorker/`：`open.aihelpme.dev` 跳转 Worker 源码。
- `Cloudflare/EmergencyUpdateWorker/`：`update.aihelpme.dev` 紧急更新 Worker 源码。
- `Cloudflare/ErrorReportWorker/`：提供 `feedback.aihelpme.dev` 反馈 API，保存对应 Worker 源码；反馈入口采用 API 形式。

## 扩展 target

- `BIT101ScheduleWidgets/`：桌面/锁屏 widget、Live Activity 和 Dynamic Island。
- `BIT101Watch/`：Apple Watch 主 App。
- `BIT101WatchWidgets/`：Apple Watch Smart Stack widget。

Widget、Watch App 与 Watch Widget 的代码分别归属 `BIT101ScheduleWidgets/`、`BIT101Watch/` 和 `BIT101WatchWidgets/`。

## 维护提示

- 课表 UI 按容器、课表分栏、网格、详情和编辑职责拆分，页面层级分别由对应文件承载。
- 新文件归入已有模块目录，业务实现按模块集中维护。
- 网络请求统一由对应 Service 处理，View 通过 Service 发起网络操作。

## 生成完整文件清单

逐文件职责表容易过时，完整文件清单使用下方命令生成：

```sh
find BIT101-iOS BIT101ScheduleWidgets BIT101Watch BIT101WatchWidgets \
  -type f -name '*.swift' | sort
```
