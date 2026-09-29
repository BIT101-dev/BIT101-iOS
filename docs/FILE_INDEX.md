# BIT101-iOS 源码索引

这份文档维护模块入口和职责地图。新增同模块文件时保持目录归属。

## 应用入口

- `BIT101-iOS/BIT101_iOSApp.swift`：应用入口、全局主题、方向策略。
- `BIT101-iOS/ContentView.swift`：按登录状态切换登录页和主壳层。
- `BIT101-iOS/Shell/AppShellView.swift`：登录后 tab、全局路由、深链和跨模块弹层。
- `BIT101-iOS/Shell/ScheduleMapAdapter.swift`：将课表缓存转换为地图消费的下一节课地点快照。
- `BIT101-iOS/Shell/AppNetworkClients.swift`：组装应用网络提示、诊断记录和会话连接池。
- `BIT101-iOS/Shell/AppAccountStores.swift`：为基础账号仓库注入当前会话、偏好容器与存储路径。
- `BIT101-iOS/Shell/AppCommunityDestinations.swift`：组装用户主页、帖子详情、文章入口和删除帖子动作。
- `BIT101-iOS/Shell/AppScheduleCacheEffects.swift`：连接日程持久化、共享展示导出与云同步。
- `BIT101-iOS/Shell/NetworkDiagnosisRunner.swift`：协调各业务服务的用户主动诊断。
- `BIT101-iOS/Shell/ExperimentalPreferenceCloudSync.swift`：协调设置、成绩和消息已读状态的实验性偏好同步。
- `BIT101-iOS/Settings/AppSettingsStore.swift`：全局设置、账号隔离和公告状态。

## 共享层

设计规则按 [UI 设计系统](DESIGN_SYSTEM.md) 分层：`DesignPrimitives.swift` 保存跨 target 基础值和透明度刻度，`ExternalDesignSystem.swift` 保存跨 target 的 SwiftUI 字体、前景层级和外部展示规则，`AppDesignSystem.swift` 保存主 App 尺寸、颜色和平台桥接，`Shared/DesignSystem/*Components.swift` 保存主 App 公共组件。课程、日程、话廊和地图的特化规则分别位于所属模块文件。

- `Package.swift`：声明 `ClientCore`、`ScheduleContracts`、`CommunityCore` 和 `DesignSystemKit` 的源码归属及编译依赖。
- `ModuleTests/`：独立模块的内存传输、账号存储、社区模型、共享快照与时间线契约测试。
- `BIT101-iOS/Shared/CommunityCore/`：跨业务共用的图片、用户、帖子摘要、评论和点赞模型及评论分页状态。
- `BIT101-iOS/Shared/CommunityUI/`：社区帖子卡片、图片网格、缩略图、菜单与链接文本展示。
- `BIT101-iOS/Shared/CommunityDestinations.swift`：跨社区页面的目标与动作接口。
- `BIT101-iOS/Shared/Media/`：Quick Look 图片预览、远程动图、静态图片与头像缓存。
- `BIT101-iOS/Shared/Client/AppStorageSession.swift`：账号摘要、稳定存储键和历史目录映射。
- `BIT101-iOS/Shared/Client/`：提供网络、提示模型、深链、更新检查、紧急更新、错误报告提交界面、键盘收起、分页、账号存储、手势、任务取消和网络 smoke。
- `BIT101-iOS/Shared/AppFileService.swift`：提供 App、Widget 与 Watch 共用的文件服务接口和本机实现。
- `BIT101-iOS/Shared/Client/AppFileDirectories.swift`：统一当前账号存储会话与应用、账号、缓存和共享容器路径。
- `BIT101-iOS/Shared/Client/ErrorReportSupport.swift`：负责反馈脱敏、诊断摘要和提交载荷。
- `BIT101-iOS/Shared/Client/AppErrorPresentation.swift`：负责错误队列、原生提示、恢复操作和报告 Sheet。
- `BIT101-iOS/Shared/DesignSystem/`：提供主 App 的颜色、间距、圆角、头像容器、评论/建议输入组件、搜索/segmented、更新时间、比例列数据行公共控件和系统触感修饰器；组件通过回调和环境接入 App 基础设施。
- `BIT101-iOS/Shared/DesignSystem/AppStateComponents.swift`：提供加载、空态、失败与滚动状态组件。
- `BIT101-iOS/Shared/ScheduleShared*.swift`：定义主 App、Widget、Live Activity 和 Watch 共用的课表快照与 occurrence 规范。
- `BIT101-iOS/WatchSync/WatchScheduleSyncManager.swift`：负责 iPhone 与 Apple Watch 的课表镜像同步。
- `BIT101-iOS/Shared/Media/CachedRemoteImage.swift`：缓存头像等远程图片，并使用内存与磁盘存储；`AppAvatarView` 负责远程图片到 `AppAvatarContainer` 的适配。

## 业务模块

### 登录

目录：`BIT101-iOS/Login/`

`LoginViews.swift` 是表单入口，`LoginViewModel.swift` 管理状态，`LoginService.swift` 协调登录与会话，`BIT101APIClient.swift` 负责学校与 BIT101 网络请求；其余文件负责模型、存储、加密和 CAS 页面解析。

`CommunitySessionSupport.swift` 为社区客户端注入登录存储和合并并发请求的会话恢复动作。

### 话廊与文章

- `BIT101-iOS/Gallery/`：信息流、搜索、消息、帖子详情、评论和发帖。
- `BIT101-iOS/Gallery/GalleryViewModel.swift`：话廊信息流与搜索状态。
- `BIT101-iOS/Gallery/GalleryMessageViewModel.swift`：消息中心、未读状态与账号隔离的本地已读快照。
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
- `ScheduleCloudSyncManager.swift`：CloudKit 同步编排、冲突协调与账号上下文。
- `ScheduleRepository.swift`：当前账号数据源、加载代际与本机修订控制。
- `ScheduleDDLViewModel.swift`：DDL 请求、短信验证与编辑状态。
- `ScheduleClassroomViewModel.swift`：空教室目录、筛选与请求状态。
- `ScheduleNotice.swift`：日程子功能共享的错误与恢复提示。
- `ScheduleSchoolVerification.swift`：观察 DDL 短信状态并呈现验证表单。
- `ScheduleCacheEffects.swift`：持久化后副作用接口。
- `ScheduleCloudSyncSupport.swift`：云同步载荷、可测试的冲突策略与缓存合并。
- `ScheduleSystemCalendarManager.swift`：系统日历权限、课程/考试/自定义日程导入删除。
- `Shared/Client/NetworkDiagnostics.swift`：网络路径提示、请求记录和诊断缓存。
- `Shared/Client/ErrorReportSupport.swift`：错误报告载荷、脱敏和诊断摘要。
- `Shared/Client/AppErrorPresentation.swift`：诊断弹窗、恢复操作和报告 Sheet。
- `Shared/Client/ReleaseNetworkSmoke.swift`、`ReleaseNetworkSmokeModels.swift`：网络 Smoke runner、探针模型和报告存储。
- 其余解析器、策略、日历、分享和编辑文件按职责拆分，按所属目录查找。

### 成绩与课程

- `BIT101-iOS/Score/`：成绩、筛选、统计、可信成绩单及其独立状态机。
- `BIT101-iOS/Score/ScoreViewModels.swift`：成绩列表加载、筛选与排序状态。
- `BIT101-iOS/Score/TrustedTranscriptViewModel.swift`：可信成绩单与独立短信验证状态。
- `BIT101-iOS/Course/`：课程搜索、详情、教师评价、历年成绩和评论。

课程评价入口由 `Course/CourseLookup.swift` 和 `CourseNavigationRequest` 统一承载，
日程课程详情与成绩详情共用检索和跳转逻辑。

`Score` 和 `Course` 均遵循 Models / Service / Servicing / ViewModel / View 的职责划分。

### 地图

目录：`BIT101-iOS/Map/`

`CampusMapScreen.swift` 是地图入口，`CampusNativeMapView.swift` 桥接 MapKit，`CampusMapLocations.swift` 保存校区与教室匹配规则；`UpcomingCourseMapResolver.swift` 定义地点快照，`Shell/ScheduleMapAdapter.swift` 负责课表数据到该快照的适配。

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
