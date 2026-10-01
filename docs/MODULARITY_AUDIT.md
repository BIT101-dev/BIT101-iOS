# 模块解耦与模块化审计

审计基线：2026-09-30；修复验收：2026-10-01。本文记录源码边界、消费契约、审计项修复及对应验收证据。

## 当前结论

项目以本地 Swift Package 建立 **25 个生产 target**，App 负责跨 Feature 组装和系统适配。网络、存储、页面导航、媒体解码、保存事件与云同步协调沿实例传递。依赖图为有向无环图，Feature 间组合通过 App 工厂、领域投影和细分端口完成。

本轮将解耦要求转为五组工程约束：

1. 业务操作使用其构造入口选择的服务、账号及存储实例。
2. 公共页面入口显式声明核心状态、媒体和所消费的导航能力。
3. 异步操作捕获账号代际，持久化与平台动作按成功保存顺序执行。
4. 保存订阅按消费者拥有生命周期，变更事件按来源和账号筛选。
5. 模块层级、平台框架准入、独立消费者编译和运行回归共同作为验收门槛。

**A01–A10 为上一阶段验收。本轮 B01–B09 深化模块边界，包级 119 项、Catalyst 235 项、通用 iOS Release 编译及统一静态门槛通过。**

## 方法与证据范围

- 检查 manifest、25 个模块源码根、原生 App / Widget / Watch 产品声明以及直接导入。
- 追踪构造参数到实际读写、解码、页面导航、同步冲突决策和事件消费位置。
- 以真实协调器配合内存文件、可控传输、独立偏好域和异步门闩验证操作归属。
- 使用既有脚本执行 macOS 包级、Catalyst 宿主、通用 iOS Release 及静态审计。
- 源码行数包含注释和空行；依赖边以 manifest 直接声明计算；传递依赖按图可达节点计算。

## 结构指标

| 指标 | 审计基线 | 当前源码 |
| --- | ---: | ---: |
| 生产 target | 23 | 25 |
| 直接依赖边 | 62 | 67 |
| 依赖环 | 0 | 0 |
| Feature → Feature | 0 | 0 |
| Feature → Infrastructure / Persistence / Sync | 0 | 0 |
| 包级测试消费者 target | 1 | 7 |
| 包级 `@Test` 声明 | 94 | 119 |
| Modules Swift 文件 / 行数 | 166 / 37,667 | 166 / 38,929 |
| App Swift 文件 / 行数 | 51 / 12,122 | 50 / 11,440 |

App 占 App 与 Modules 合计源码行数的 22.7%。`ScheduleSync` 承接同步状态投影、协调器和传输契约；`ScheduleActivityContracts` 承接 ActivityKit 属性。`ScheduleContracts` 提供 Foundation / CryptoKit 快照及时间线能力，供领域、Widget 和 Watch 复用。

“出度”为直接依赖数量，“入度”为其他生产模块的直接引用数量，原生 target 和测试另行统计。

| 模块 | 文件 | 行数 | 出度 | 入度 | 传递依赖 |
| --- | ---: | ---: | ---: | ---: | ---: |
| ClientCore | 4 | 617 | 0 | 6 | 0 |
| CommunityCore | 5 | 519 | 0 | 5 | 0 |
| CommunityTransport | 2 | 350 | 1 | 4 | 1 |
| CommunityUI | 5 | 1,347 | 4 | 4 | 5 |
| CourseFeature | 11 | 2,826 | 6 | 0 | 7 |
| DesignSystemKit | 16 | 1,825 | 0 | 9 | 0 |
| GalleryFeature | 17 | 4,962 | 7 | 0 | 7 |
| MapFeature | 5 | 949 | 2 | 0 | 2 |
| MediaKit | 5 | 1,404 | 3 | 5 | 3 |
| MineFeature | 6 | 1,497 | 6 | 0 | 7 |
| PaperFeature | 12 | 2,704 | 6 | 0 | 7 |
| ScheduleActivityContracts | 1 | 37 | 0 | 0 | 0 |
| ScheduleContracts | 2 | 793 | 0 | 4 | 0 |
| ScheduleDomain | 11 | 2,948 | 1 | 5 | 1 |
| ScheduleFeature | 32 | 8,742 | 7 | 0 | 7 |
| ScheduleInfrastructure | 8 | 2,196 | 4 | 0 | 6 |
| SchedulePersistence | 1 | 260 | 2 | 0 | 3 |
| SchedulePorts | 3 | 194 | 3 | 2 | 4 |
| ScheduleSharedStore | 2 | 117 | 2 | 0 | 2 |
| ScheduleSync | 3 | 949 | 2 | 0 | 3 |
| ScoreDomain | 2 | 489 | 2 | 2 | 2 |
| ScoreFeature | 5 | 1,610 | 5 | 0 | 5 |
| ScoreInfrastructure | 1 | 927 | 4 | 0 | 4 |
| StorageCore | 3 | 395 | 0 | 11 | 0 |
| TransportCore | 4 | 272 | 0 | 10 | 0 |

Widget 直接消费 5 个产品：DesignSystemKit、ScheduleContracts、ScheduleActivityContracts、ScheduleSharedStore、StorageCore。Watch App 和 Watch Widget 分别消费 DesignSystemKit、ScheduleContracts、ScheduleSharedStore、StorageCore。

## 分层与所有权

| 层 | 职责和依赖范围 |
| --- | --- |
| Core / Transport | 基础值、账号文件、学校认证、HTTP 和社区身份；消费对应基础层 |
| Contracts / Domain | 外部数据契约及纯业务规则；平台属性集中于 ScheduleActivityContracts |
| Ports | 课程、DDL、教室、成绩和平台动作的消费端协议 |
| Persistence / SharedStore | 注入式文件读写、迁移、版本和快照归属 |
| Infrastructure / Sync | 生产业务服务与同步协调；消费端口、领域和持久化能力 |
| Kit / UI | 设计系统、媒体与公共展示；跨 Feature 能力按消费者拆分 |
| Feature | 场景状态和界面；使用基础能力、领域、端口及公共 UI |
| App | 凭据、系统容器、网络连接池、原生能力和跨 Feature 组合 |

[边界检查器](../Scripts/check-module-boundaries.py) 同时校验精确依赖基线、层级方向、环、源码导入、平台框架以及原生产品声明。基础层准入 Foundation、Combine、Observation、CryptoKit、日志和 CoreFoundation；ActivityKit 的显式准入归 ScheduleActivityContracts。

## A01–A10 审计项验收

### A01：建议页面的草稿与提交归属

[建议依赖与页面](../BIT101-iOS/Settings/SettingsRootView.swift) 显式接收 `DeveloperSuggestionDependencies`。读取、保存、恢复和删除统一使用其 `ComposerDraftStore`，提交使用注入的 delivery 闭包。`submitAndClear` 在成功提交后执行捕获的清理能力。清理按提交前的账号和已保存版本匹配，继续编辑产生的新版本保持原值。话题提交使用同一存储契约。

[App 社区组装](../BIT101-iOS/Shell/AppCommunityDestinations.swift) 从当前 `AppAccountStores` 传递草稿及提交能力，设置页和建议目的地复用同一依赖。

验收：[SuggestionDependencyTests](../BIT101-iOSTests/SuggestionDependencyTests.swift) 准备相同账号、不同存储中的 A / B 草稿，验证页面选择 A、提交清理 A、B 保持原值；提交失败保留 A，跨账号和继续编辑后的清理匹配提交前的保存版本。

### A02：媒体存储、校验与解码链路

[MediaEnvironment](../Modules/MediaKit/Sources/MediaEnvironment.swift) 拥有每个实例的缓存及静态 / 动态解码器。[缓存校验与缩略图解码](../Modules/MediaKit/Sources/RemoteImageCache.swift)、[GIF 解码](../Modules/MediaKit/Sources/RemoteAnimatedImage.swift) 消费注入文件服务返回的 `Data`。解码键使用内容摘要，动态图同时区分 Reduce Motion。

Quick Look 使用显式 `previewFiles`。预览准备把源存储的字节物化到系统可读文件服务，内容相同的本机文件直接复用。源缓存和预览文件使用相同偏好驱动的配额规则；[预览适配](../Modules/MediaKit/Sources/ImagePreview.swift) 持有占位文件身份并按当前请求升级清晰度。

验收：[MediaDependencyTests](../BIT101-iOSTests/MediaDependencyTests.swift) 覆盖纯内存下载、二次缓存命中、相同逻辑路径的不同图片、同路径内容变化、预览字节归属、GIF 多帧和 Reduce Motion。

### A03：课表、DDL、教室的统一仓库

[ScheduleViewModel](../Modules/ScheduleFeature/Sources/ScheduleViewModel.swift) 接收一个 `ScheduleRepository` 以及三类服务，并由入口构造 DDL 和教室子场景。三个场景共享写入队列、账号、代际和场景投影。

验收：[ScheduleFeatureTests](../ModuleTests/Schedule/ScheduleFeatureTests.swift) 的 `publicAssemblyOwnsOneRepositoryAcrossAllSubscenes` 核对仓库身份及重置代际。既有仓库边界测试继续覆盖迟到加载、同步结果、保存排队、失败和继续编辑。

### A04：生产同步协调与平台适配

[ScheduleCloudSyncManager](../Modules/ScheduleSync/Sources/ScheduleCloudSyncManager.swift) 为独立 actor，通过 [ScheduleCloudTransport / LocalStore](../Modules/ScheduleSync/Sources/ScheduleCloudTransport.swift) 接收账号快照、加载、比较保存、云端读写和冲突呈现。账号包含登录代际；记录标识和学号共同验证远端归属；冲突签名包含代际，繁忙期间的刷新请求在当前操作结束后按最新账号继续协调。

[App CloudKit 适配](../BIT101-iOS/Schedule/ScheduleCloudSyncManager.swift) 选择 CKContainer、传递 CloudKit system fields、映射乐观锁错误和组装提示动作。App 本地保存入口在排队写入前复核捕获的账号代际。同步用户状态通过 [ScheduleCloudSyncState](../Modules/ScheduleSync/Sources/ScheduleCloudSyncState.swift) 投影，学校抓取数据归本机持久化。

[提醒上下文](../BIT101-iOS/Schedule/ScheduleLiveActivityManager.swift) 注入账号、代际和按会话读取缓存的能力；通知中心由 [App 平台组装](../BIT101-iOS/Shell/AppScheduleCacheEffects.swift) 选择。系统日历继续接收 EventKit store、UserDefaults 及精简课程 / 事件草稿。

验收：[ScheduleSyncTests](../ModuleTests/Sync/ScheduleSyncTests.swift) 通过生产协调器验证远端合并、切号代际、云端保存期间继续编辑、乐观锁冲突、用户决策、版本和身份、保存失败、繁忙期间的切号刷新及 provider lock token；[ReminderContextTests](../BIT101-iOSTests/ReminderContextTests.swift) 验证缓存读取期间的代际变化和账号分区；[CloudPromptTests](../BIT101-iOSTests/CloudPromptTests.swift) 验证同一冲突在稍后处理后可再次呈现。

### A05：跨层输入和保存顺序

[SchedulePlatformActions](../Modules/SchedulePorts/Sources/SchedulePlatformActions.swift) 的云同步启用动作消费 `AppStorageSession`。实际同步状态由同步模块的本地所有者加载。日历、地图、成绩和扩展分别消费课程快照、位置请求、成绩课程摘要和外部快照。

[开关处理](../Modules/ScheduleFeature/Sources/ScheduleViewModel+Preferences.swift) 先完成 `.localWithoutCloudPush` 保存，再核对账号、代际、开关及任务状态，随后调用平台动作。启用任务由 ViewModel 持有，切号和开关变化管理其生命周期。

验收：`cloudEnableWaitsForTheOwnedSaveAndHonorsSaveFailure` 覆盖成功保存与失败；`platformActionsReceiveTheRepositorySessionAfterPersistence` 覆盖账号及动作投影。场景写入测试验证 DDL、教室与云端基线的字段归属。

### A06：页面入口与导航能力

[公共社区导航](../Modules/CommunityUI/Sources/CommunityDestinations.swift) 分成 Profile、Poster、Paper、Settings 四组能力。[AppCommunityDestinations](../BIT101-iOS/Shell/AppCommunityDestinations.swift) 负责跨场景组合，Feature 持有其消费的能力。

公共页面的核心构造契约：

| 页面 | 构造依赖 |
| --- | --- |
| ScheduleRootView | ScheduleViewModel、分栏绑定、ScheduleDestinations |
| GalleryRootView | GalleryDependencies、MediaEnvironment、Profile / Paper 能力、深链绑定 |
| GalleryPosterDetailView | GalleryDependencies、MediaEnvironment、Profile 能力、帖子及删除回调 |
| PaperRootView | PaperDependencies、MediaEnvironment、深链绑定与返回话题回调 |
| MineRootView | MineDependencies、MediaEnvironment、Poster / Settings 能力、账号及退出回调 |
| UserProfileRootView | MineDependencies、MediaEnvironment、Poster 能力、用户标识 |
| CoursePageContent | CourseListViewModel、CourseDependencies、MediaEnvironment、Profile 能力 |
| CourseDetailView / CourseEvaluationDestination | CourseDependencies、MediaEnvironment、Profile 能力、课程或请求 |
| CourseEvaluationLink | CourseDependencies、解析请求和结果回调 |

入口集中安装内部状态环境，导航目的地携带同一依赖。文章详情和搜索入口显式持有媒体及服务；SwiftUI 导航目的地在独立宿主中验证其依赖归属。公共图片组件消费页面入口安装的 MediaEnvironment；系统主题、dismiss、openURL 和 scenePhase 继续沿 SwiftUI 宿主管理。

验收：[FeatureCompositionTests](../BIT101-iOSTests/FeatureCompositionTests.swift) 用异构外围环境宿主覆盖课程、Gallery → Paper 深链、Paper、Mine、Profile 和 Schedule。选择的服务产生请求，外围服务保持原读取次数。

### A07：保存订阅的生命周期

成绩缓存、筛选、设置和消息仓库通过 typed `localSaves` publisher 发布账号会话。[ExperimentalPreferenceCloudSync](../BIT101-iOS/Shell/ExperimentalPreferenceCloudSync.swift) 在构造时拥有自己的可取消订阅，并通过弱引用处理保存事件。

验收：[ScoreFeatureTests](../ModuleTests/Score/ScoreFeatureTests.swift) 验证同一保存向两个订阅者分发以及单个订阅取消；[ExperimentalPreferenceCloudSyncTests](../BIT101-iOSTests/InfrastructureTests.swift) 验证两个协调器复用同一仓库时各自收到保存。账号变化后，迟到的成绩保存事件由会话筛选。

### A08：架构规则

[检查器](../Scripts/check-module-boundaries.py) 按 Core、Transport、Kit、UI、Contracts、Domain、Ports、Persistence、SharedStore、Infrastructure、Sync、Feature 设置准入。平台导入单独校验。导入扫描屏蔽嵌套注释、普通 / 多行 / raw 字符串，支持带可见性、测试属性和符号种类的 import。

验收：自测覆盖基础层 → Feature、Feature → Feature、Infrastructure → Feature、依赖环、领域 UIKit、ActivityKit 准入、嵌套注释和 raw 多行字符串。完整扫描校验 25 个生产根、7 个测试消费者及原生产品声明。

### A09：独立消费者与平台证据

[Package.swift](../Package.swift) 声明 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个测试消费者，分别拥有源码根及实际导入的直接依赖。测试用内存文件服务归 `BIT101TestSupport`，其生产依赖为 StorageCore。学校解析 fixture 沿用 App 测试资产固定路径。

[共享快照](../Modules/ScheduleContracts/Sources/ScheduleSharedSnapshot.swift) 为展示性字段提供缺省值，课程身份与调度时间维持必需字段。[契约测试](../ModuleTests/Contracts/ScheduleContractsTests.swift) 使用固定早期载荷，经 Watch 字段和统一 codec 验证缺省字段、未来扩展字段、往返及缺少调度字段的解码结果。

包级测试证明领域、服务、存储、同步和状态；Catalyst 宿主证明 iOS 页面组合及 UIKit 媒体行为；通用 iOS Release 编译证明 App、Widget、Watch 与 ActivityKit 的平台代码。真机系统权限、实际云端冲突和跨设备传输属于设备流程。

测试脚本按实际测试数量验收筛选结果，失败摘要按原因归并。Swift Testing 方法筛选使用带 `()` 的标识；suite 筛选验证整组用例。

### A10：事件来源与账号作用域

日程仓库通过注入的 `AnyPublisher<AppStorageSession, Never>` 消费所属源的变更，随后核对账号和代际。App 生命周期与成绩课表投影同样消费 typed 日程变更流。

成绩筛选、成绩缓存及消息的通知携带源仓库和账号；消费者按仓库身份和会话筛选。异步成绩重载捕获页面代际。订阅在构造时就绪，由消费者持有取消句柄。

验收：`scopedChangeStreamReloadsItsAccountOwner` 使用同一变更流驱动不同账号；`sharedNotificationCenterKeepsPreferenceSourcesScoped` 使用相同通知中心和相同账号的两套仓库验证来源隔离及迟到账号事件。生命周期隔离测试验证同一实例的设置、账号切换和外部刷新。

## B01–B09 深化修复

### B01：完整清理能力与偏好域归属

[AppLocalDataService](../BIT101-iOS/Shell/AppLocalDataService.swift) 接收文件后端及 `AppLocalDataActions`：登录、日程、共享快照、报告、偏好、URLCache、WebKit、媒体和设置重置逐项注入。清理成功汇总包含日程删除结果；目录按 URL 去重，回收字节按唯一目录统计。生产资源由 App 工厂绑定，测试通过内存后端和动作替身验收操作顺序、失败汇总及 A / B 隔离。

偏好容器和 `defaultsDomain` 配对选择，UI 自动化使用所属 suite。回归使用独立测试后端和测试偏好域。

### B02：设置与成绩课程源的选择闭环

`SettingsDependencies` 同时携带设置、日程、媒体、账号及清理能力；设置根入口安装所选环境。账号网络服务接收社区会话及验证闭包，页面捕获完整账号代际，认证续期沿同一身份接续结果。

`AppAccountLifecycle` 的社区、成绩服务、媒体、清理、日程变更及课程加载为显式输入；成绩适配器转发所选课程源。`SettingsDependencyOwnershipTests` 验证媒体 A / B、账号凭据、登录验证和清理归属；`lifecycleForwardsItsSelectedCourseSourceToScores` 验证相同流中的账号过滤及课程加载来源。

### B03：公共草稿能力与独立运行

草稿模型、`ComposerDraftStore`、`ComposerImageDraft`、`ComposerImageTile` 及图片准备策略归 [CommunityUI](../Modules/CommunityUI/Sources/CommunityDesignSystem.swift)。话题和建议页面消费同一公共契约。存储通过注入的图片准备闭包工作，UIKit / ImageIO 适配采用平台条件编译；图片上限在原子写入边界校验。

`ComposerPublicContractTests` 采用常规 `import CommunityUI`，在 macOS 内存文件后端验证准备字节、保护写入、写入失败、账号清理、继续编辑版本与图片上限。账号目录、元数据 schema 和资产提交关系保持同一持久化契约。

### B04：成绩领域与存储端口

[ScoreDomain](../Modules/ScoreDomain/Sources/ScoreServicing.swift) 定义 `ScoreCaching`、`ScoreFilterPreferencesStoring` 及缓存 / 筛选快照；[领域模型](../Modules/ScoreDomain/Sources/ScoreModels.swift) 提供公开的刷新决策、排序及统计规则。

[ScoreInfrastructure](../Modules/ScoreInfrastructure/Sources/ScoreService.swift) 实现成绩缓存 actor 仓库及账号筛选存储。`ScoreViewModel` 消费领域端口，App 选择生产实现。`ScorePublicContractTests` 通过常规 `import ScoreFeature` 构造独立缓存和筛选替身，验证相同通知中心中的仓库身份、账号及公共领域规则。

### B05：时间规则归领域

`ScheduleCacheTimestamp` 归 `ScheduleDomain`，同步模块直接消费单调版本和云端恢复规则。同步的直接依赖收敛为 `ScheduleDomain`、`StorageCore`；`ScheduleTimestampPublicContractTests` 覆盖回拨时间、版本递增、服务端日期及载荷日期匹配。

### B06：SwiftUI 场景生命周期

Gallery 根页 / 详情、Paper 根页 / 搜索 / 详情、Mine / Profile、课程详情和课程深链目的地使用依赖、媒体及资源身份绑定内部场景。依赖替换重建 `StateObject` 与加载任务，导航闭包随构造输入更新。课程解析在返回时检查任务取消。

`FeatureCompositionTests` 在同一 `UIHostingController` 中替换 Paper、Gallery 和课程深链依赖，验证新来源接续请求及旧来源的读取次数。公共构造参数维持稳定。

### B07：布局与系统动作边界

社区图片尺寸从容器和现有比例令牌推导，布局选择归当前宿主。`AppRecoveryAction` 提供动作描述，打开系统设置由 App 提示适配器执行。模块扫描同时验证系统资源访问归属。

### B08：保存排队的代际与取消

公共 `SchedulePersistenceCoordinator` 持有串行队列；任务进入操作前复核取消与捕获身份，队列完成后复核返回资格。App 保存包装器在安排任务时捕获登录代际。已进入提交的写入按原事务完成，排队的失效工作按当前身份筛选。

`SchedulePersistenceCoordinatorTests` 覆盖账号 A → B → A 代际、排队取消、提交期间取消及后续保存。生产 App 适配使用相同协调器。

`preciseDiskVersionsRoundTripAndRejectAnEarlierCompareToken` 复现了 ISO 8601 秒级落盘造成的比较保存失败。日期写入采用 Foundation 默认的完整精度编码，读取按 JSON 值类型支持既有 ISO 8601 文本和标准日期数值；回归验证精度往返、后续版本递增、过期比较令牌及既有日期读取。

### B09：架构门槛与数据事务

边界检查器增加模块全局资源访问、成绩 Feature 的具体存储引用，以及设置 / 清理服务的资源归属规则；自测覆盖带空白成员访问、注释和 raw 字符串。

日程继续以统一文件和版本提交数据，场景投影拥有各自字段。新增 `malformedAggregateSectionsPreserveTheCompleteDiskTransaction` 验证课程、学期缓存、DDL、自定义日程、教室筛选和时间表字段损坏时的完整文件保留与写入门槛。

源码组织沿用现有文件，共享草稿和成绩持久化按所属模块迁移。大型文件的细分粒度继续作为人工审查项，由独立生命周期和文件创建约定共同约束。

## 验证记录

| 门槛 | 入口 | 当前证据 |
| --- | --- | --- |
| 包级运行 | `Scripts/run-extended-tests.sh modules` | 7 个消费者，119 项通过 |
| iOS 宿主运行 | `Scripts/run-extended-tests.sh catalyst` | 235 项通过，包含版本精度修复后的全量运行 |
| App 与扩展编译 | `Scripts/build-install-device.sh --compile-only --generic` | App、Widget、Watch App / Widget Release 编译通过 |
| 统一静态门槛 | `Scripts/run-static-audit.sh` | 全部门槛通过 |

Catalyst 干净构建输出包含 Swift module dependency-scan 警告。逐项核对 manifest 与 Xcode 生成的 PIF：对应直接依赖和传递依赖均已声明，PIF 同时生成 static / dynamic product 变体。警告归工具链构建图诊断记录；本次编译与运行结果由实际通过的门槛证明。

测试产物覆盖 `.build/extended-automation/`，通用编译覆盖 `build/DeviceInstall/`，静态审计覆盖 `.build/static-audit/`。

## 保持的工程取舍

- 日程磁盘记录采用统一版本及串行写入，场景投影维护字段写权限；同步采用精简用户状态契约。
- 社区 Feature 按业务纵向组织界面、状态和服务，消费者使用细分 Servicing。跨 Feature 组装归 App。
- 本地 Package 统一维护版本及默认 MainActor 隔离，后台 actor 和 Sendable 值显式声明隔离。
- 系统容器、ActivityKit、EventKit、Quick Look 和真实跨进程通信归平台适配与设备验收。
- 高入度公共基础层继续通过稳定契约复用；依赖调整同时更新准入规则、独立消费者测试和原生产品声明。

以上取舍由明确所有权、编译边界与运行证据支撑。后续变更沿同一门槛验收。
