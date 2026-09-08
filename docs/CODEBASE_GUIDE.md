# BIT101-iOS 代码库导览

这份文档对应当前项目代码基线，侧重维护入口、数据流和实现边界，帮助后续维护时快速回答下面几个问题：

- 这个模块的职责是什么
- 数据来源与最终存储位置
- 哪些行为是平台约束，哪些只是当前实现选择
- 如果要改某个功能，应该先看哪几个文件

## 1. 总体结构

项目包含以下四个 target：

- `BIT101-iOS`
  主应用 target
- `BIT101ScheduleWidgets`
  小组件、锁屏组件、Live Activity / 灵动岛扩展 target
- `BIT101Watch`
  Apple Watch 单 target 应用，包含应用入口、主界面与同步消费逻辑
- `BIT101WatchWidgets`
  Apple Watch Smart Stack 课表组件

主应用的顶层流程如下：

1. `BIT101_iOSApp.swift`
   挂载根视图，应用全局主题和屏幕方向策略。
2. `ContentView.swift`
   决定当前进入登录页还是登录后壳层。
3. `Shell/AppShellView.swift`
   登录后负责底部 tab、深链分发、跨模块弹层和全局路由。

当前底部 tab 顺序如下：

1. 日程
2. 地图
3. 话廊
4. 成绩
5. 我的

## 2. 横切约束

各模块共享以下全局约束。

### 2.1 账号隔离

以下数据按学号隔离：

- 课表 / DDL / 考试缓存
- 一部分界面与查询偏好

维护时使用以下规则：

- 账号相关状态写入账号作用域的 key
- 退出登录或切号后，相关缓存和设置重新定位到当前账号

主要入口：

- `Login/LoginService.swift`
- `Settings/AppSettingsStore.swift`
- `Schedule/ScheduleModels.swift`

### 2.2 主 App 与 Widget / Watch 的边界

Widget、锁屏组件、Apple Watch、Live Activity 通过共享快照和最小必要状态获取数据，主 App 的复杂缓存对象留在主 App 内部。

边界分工如下：

- 主 App 负责从课表缓存导出精简快照
- Widget / Watch 读取共享容器里的快照
- Live Activity 使用最小必要状态

主要入口：

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `Shared/ScheduleSharedOccurrence.swift`
- `WatchSync/WatchScheduleSyncManager.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgets.swift`

### 2.3 图片与头像缓存

项目在系统默认缓存之外维护本地显式头像缓存。维护时同时检查：

- 内存缓存和磁盘缓存都在起作用
- 头像 URL 规则变化时，缓存 key 保持稳定
- 图片列表和头像缓存分开处理

主要文件：

- `CachedRemoteImage.swift`
- `Gallery/GalleryRootView.swift`
- `Mine/MineRootView.swift`

## 3. 登录模块

### 3.1 组成文件

- `Login/LoginViews.swift`
  登录页与启动检查 UI
- `Login/LoginViewModel.swift`
  登录状态机
- `Login/LoginService.swift`
  CAS、SSO、BIT101 登录与凭据恢复

### 3.2 数据流

登录链路分为三段：

1. 请求学校 CAS 页面，提取登录所需参数
2. 提交学校账号密码并写入学校侧 cookie
3. 通过 BIT101 的登录 / 注册桥接获取项目自己的 `fake-cookie`

状态分别保存于：

- Keychain
  学校账号密码与必要凭据
- 本地 cookie / session
  学校 SSO 与 BIT101 会话
- `AppSettingsStore`
  与账号关联的偏好设置

### 3.3 维护重点

- 冷启动有本地会话时先展示主壳层并进行 BIT101 会话的保守校验；学校/WebVPN 数据按需请求，课表首屏沿用主壳层加载路径
- 学校 SSO 存在历史 `http -> https` 跳转问题，`LoginService` 内置 URL 升级逻辑
- 排查登录链路时先区分学校登录失败与 BIT101 注册 / 登录桥接失败
- 登录态检查采用“保守清退”：`LoginService.checkLogin()` 仅在远端明确说明凭据无效时清除本地 session，例如 BIT101 `/user/check` 返回 401，或学校 CAS 静默重登明确失败。网络错误、学校登录页结构异常、临时拿不到静默恢复参数、缺少本地恢复凭据等情况向上抛错，`fake-cookie` 保持不变。
- 切号行为清除 cookie、触发账号变更通知，并影响设置页、日程缓存和话廊规则状态
- `fake-cookie` 会影响共享课表快照里的 `isLoggedIn`，进而影响 widget / Apple Watch 展示；外部展示层依据明确的登录失效结果显示“未登录”，登录检查结果不确定时沿用当前登录状态。

认证链分为两条：`LoginService` 负责 App/BIT101 登录与恢复；课表、成绩、空教室、
可信成绩单使用 `ScheduleService` / `ScoreService` 内的 bit-login challenge。后者的 token
保存在短期内存状态中；请求 `jwb_cjd` 时使用独立的 `jwb_cjd` challenge，普通 `jwb` challenge
沿用普通成绩链路。

## 4. 日程模块

### 4.1 组成文件

- `Schedule/ScheduleModels.swift`
  课表、考试、DDL、空教室、缓存快照和时间表模型
- `Schedule/ScheduleCacheStore.swift`
  按账号隔离的本地缓存读写
- `Schedule/ScheduleCloudSyncManager.swift`
  CloudKit 同步与冲突决策
- `Schedule/ScheduleClassroomCoordinator.swift`
  空教室请求生命周期与超时
- `Schedule/ScheduleCourseSyncCoordinator.swift`
  协调短信认证后的同步续接
- `Schedule/ScheduleService.swift`
  教务、乐学、空教室相关的网络请求与数据解析
- `Schedule/ScheduleViewModel.swift`
  日程主状态机
- `Schedule/ScheduleRootView.swift`
  课表 / DDL / 空教室 UI
- `Schedule/ScheduleWidgetSupport.swift`
  共享快照导出
- `Schedule/ScheduleLiveActivityManager.swift`
  课程提醒 Live Activity

### 4.2 数据优先级

日程模块先读取本地缓存，再按用户操作同步远端数据：

1. 先读本地缓存，页面优先展示本地数据
2. 用户再手动发起同步，刷新远端数据
3. 自定义日程与远端课表混合展示，由本地统一管理

### 4.3 课表 / DDL / 空教室的职责边界

- 课表
  负责课程、考试、自定义日程和课程周视图
- DDL
  负责乐学导入后的截止事项与本地完成状态
- 空教室
  负责校区、教学楼、节次的当前查询

这些能力由日程根视图和各自的分栏视图协作，状态来源如下：

- 课表 / DDL / 考试：依赖课表缓存
- 空教室：依赖查询偏好 + 当前查询结果
- 自定义日程：纯本地 CRUD

### 4.4 近期实现要点

日程模块包含以下偏好和本地匹配规则：

- 学期选择展示学校接口实际返回的值，本地学期列表保持接口范围
- 学期选择先独立落盘；课表请求失败时提示错误并保留已选学期。已有快照立即复用；缺少快照时展示空课表，旧学期课程与新学期选择保持隔离
- 同步指定学期时会同时获取该学期课程、考试和第一周日期；普通刷新保持用户已选学期
- 周视图支持第 1 周之前和课程周数之后的周次，并跳过不存在的第 0 周
- 手动翻页覆盖课程最后一周；冷启动、学期切换、同步和“回到本周”等自动定位将计算结果限制在第 -12 至 +20 周
- 未发布学期无课表时按空课表处理，页面保持可操作
- 空教室会记住校区偏好
- 空教室优先使用“最近下一节课”匹配教学楼
- 用户主动刷新空教室时会按当前时段块匹配节次
- 课表顶部日期格支持进入调休 / 放假页面，可清空当天课程或将当天课程调至其它日期

维护日程模块时保留以下行为：

- “用户上一次选择”保留为当前值，默认值在缺少用户选择时生效
- 空教室的“最近课程楼匹配”优先级高于缓存
- 教学中心会话按账号校验并处理失效状态；业务响应为 401/403、登录页或非 JSON 时触发有限恢复

## 5. 成绩模块

### 5.1 组成文件

- `Score/ScoreModels.swift`
  成绩模型、筛选模型、统计模型
- `Score/ScoreService.swift`
  普通成绩、可信成绩单、短信 challenge、临时图片下载与响应解析
- `Score/ScoreCacheStore.swift`
  按账号保存基础成绩列表
- `Score/ScoreRootView.swift`
  成绩页、筛选页、统计页 UI

### 5.2 当前设计

成绩页采用原生实现，查询、展示和筛选均由原生页面承载，历史 WebView 保持独立。

关键点：

- 查询直接复用已保存的学校账号密码
- 普通成绩通过 bit-login 的 `jwb` 服务查询；完整模式返回均分、排名和详情字段，列表使用 `detail=true`
- 普通 HTTP 请求超时为 25 秒；完整成绩查询、首次认证与轮询最多等待约 90 秒
- 服务端返回 `202` 时展示原生短信验证码 sheet，并处理错误码、过期和重复提交
- 课表、成绩和可信成绩单共用 `AppSMSVerificationSheet`，认证状态仍由各自 ViewModel 管理
- 学期筛选与成绩类型筛选支持全选 / 全不选 / 0 选
- 上一次筛选结果与列表排序偏好会按账号保存
- 成绩列表默认按名称排序，并支持按名称、成绩、均分、学分、学期、种类升序 / 降序排序
- 可信成绩单使用独立的 `jwb_cjd` challenge；入口在成绩同步期间禁用
- 成绩单图片使用 ephemeral 会话下载，保存在内存中，点击后复用话题图片全屏缩放器

维护时检查：

- 筛选状态是 UI 偏好，也是查询结果展示逻辑的一部分
- 刷新查询结果时保留用户筛选
- 排序影响列表展示顺序，统计摘要沿用原有计算口径
- 普通成绩与可信成绩单的 challenge 保持独立；token 与成绩单图片限定在页面会话内，退出页面后释放

### 5.3 课程合并入口

“成绩”底部入口内部通过顶部分段控件承载“成绩 / 课程”。课程能力位于 `Course/`，包括：

- 课程浏览、搜索与分页
- 课程详情、教师信息和历年成绩统计
- 点赞、评分、评论及评论图片预览

课程号/课程名/教师消歧集中在 `Course/CourseLookup.swift`。日程课程详情和成绩详情的
“查看课程评价”都通过 `CourseNavigationRequest` 进入 `CoursePageContent`，共用课程详情与评论实现。

课程列表与详情各自维护 Service / ViewModel，`ScoreViewModel` 保持成绩职责。左右滑动触发
一级内容切换，成绩筛选与可信成绩单状态由各自流程管理。

## 6. 地图模块

### 6.1 组成文件

- `Map/CampusMapScreen.swift`

### 6.2 当前设计

地图页通过 `MKMapView` 桥接实现，地图层控制由 MapKit 承担。

该实现支持更细的地图层控制、校园底图与自定义跳转，并兼容中国区 provider attribution 的处理。

### 6.3 维护重点

地图页同时包含平台桥接和工程 hack：

- `UIViewRepresentable + MKMapView`
  负责平台桥接
- attribution/legal label 的隐藏处理
  依赖内部视图层级，兼容性风险更高

地图出现系统版本兼容问题时，先检查 attribution 处理，再检查其余地图逻辑。

## 7. 话廊模块

### 7.1 组成文件

- `Gallery/GalleryModels.swift`
  帖子、评论、搜索、消息、用户等模型
- `Gallery/GalleryComposerView.swift`
  发帖页
- `Gallery/GalleryPosterDetailViewModel.swift`
  帖子详情页状态机
- `Gallery/GalleryService.swift`
  feed、搜索、消息相关请求
- `Gallery/GalleryViewModel.swift`
  feed 与消息的状态机
- `Gallery/GalleryRootView.swift`
  首页、消息页、搜索页、帖子详情、图片查看器等 UI

### 7.2 当前功能

话廊当前包含：

- `关注 / 推荐 / 最新 / 最热 / 机器人` feed
- 搜索
- 发帖
- 评论
- 消息中心
- 帖子详情跳他人主页

### 7.3 关键约束

#### 7.3.1 feed 切换

`TabView(.page)` 曾带来底部黑边与布局问题，feed 切换当前采用轻扫手势方案。

维护 feed 切换时：

- 横向切换体验保持不变
- 回退到原生 pager 前重新验证底部覆盖和 tab bar 采样问题

#### 7.3.2 推荐流

推荐流包含以下处理：

- 后端推荐链路本身更重
- 可能需要随机补帖
- 机器人流会按服务端标签筛选

维护推荐流时检查：

- 分页触发点
- 本地可见列表与原始列表的关系
- 预取与真实 append 的时机
- 去重

#### 7.3.3 消息中心

消息中心的已读表现由以下两层组成：

- 服务端提供分类未读数
- 客户端基于当前分类未读数生成本地“伪新消息”表现

这套已读状态服务于本地 UI 体验；跨设备强一致性和服务端逐条已读状态保持独立。

### 7.4 文章合并入口

“话廊”底部入口内部通过顶部分段控件承载“话题 / 文章”。文章代码位于 `Paper/`，
负责列表、搜索、发布、编辑、详情、点赞和评论。文章正文使用本地模型解析与原生渲染，
未知正文块静默忽略，文章阅读保持原生渲染路径。

文章与话题复用用户、评论和全屏图片查看器等基础能力，分页与详情状态分别维护；
从深链打开文章时由 `AppShellView` 先切到话廊，再把文章 ID 交给 `PaperRootView`。

## 8. 我的模块

### 8.1 组成文件

- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`

### 8.2 当前设计

“我的”页包含三类入口：

- 个人资料总览
- 粉丝 / 关注 / 帖子入口
- 设置与关于入口

“我的”页同时承载“他人主页”。当前支持：

- 从帖子详情进入他人主页
- 从评论作者进入他人主页
- 在他人主页继续浏览其帖子

### 8.3 维护重点

- 我的帖子与话廊帖子卡片优先复用一套 UI
- 资料页里的账号信息与“账号设置”里的账号信息保持单一展示来源

## 9. 设置模块

### 9.1 组成文件

- `Settings/AppSettingsStore.swift`
  全局设置快照、账号隔离设置、读写桥接
- `Settings/SettingsServices.swift`
  设置页复用的网络辅助
- `Settings/SettingsRootView.swift`
  设置页与关于页

### 9.2 当前设计

设置页是当前项目运行时行为的总入口，覆盖：

- 外观模式
- 屏幕旋转
- 话廊相关设置
- 课表与灵动岛提醒设置
- 关于页与开源说明

### 9.3 当前注意事项

- 一部分设置是全局的
- 一部分设置按账号隔离
- 修改设置后，许多页面要求即时生效

维护设置时区分：

- 纯显示偏好与账号态数据
- 修改后需要通知其他模块立即刷新的设置

## 10. 小组件、Apple Watch 与灵动岛

### 10.1 组成文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgets.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgetsBundle.swift`
- `BIT101Watch/BIT101WatchApp.swift`
- `BIT101Watch/WatchScheduleRootView.swift`
- `BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`
- `BIT101WatchWidgets/BIT101WatchWidgetsBundle.swift`

### 10.2 当前能力

当前支持：

- 桌面课表 widget
- 锁屏组件
- Apple Watch 课表页
- Apple Watch Smart Stack 组件
- Live Activity / 灵动岛课程提醒

### 10.3 关键约束

#### 10.3.1 共享容器

主 App 与扩展通过同一个 App Group 共享数据：

- `group.BIT101-dev.BIT101-iOS.shared`

#### 10.3.2 深链

小组件和 Live Activity 的深链统一使用：

- `bit101://...`

课程类入口统一指向：

- `bit101://schedule/courses`

#### 10.3.3 灵动岛显示策略

当前灵动岛提醒按“提前显示阈值”控制显示时段。

维护时要区分：

- 小组件
- 锁屏组件
- Live Activity
- Dynamic Island

它们共享同一批课表快照，各自采用对应的显示策略和平台约束。

#### 10.3.4 watch 端逻辑分工

工程采用单 Watch App target 结构：应用入口和主界面位于
`BIT101Watch/`，Smart Stack 仍由 `BIT101WatchWidgets` 扩展提供；
`BIT101WatchExtension` target 属于旧式 target 结构。

watch app 与 watch widget 共用“读快照 -> 算下一节课”的流程，具体逻辑统一位于：

- `Shared/ScheduleSharedOccurrence.swift`
  负责共享快照到 `ScheduleExternalOccurrence` 的解析、内容状态判定和时间线刷新规划
- `Shared/ScheduleSharedSnapshot.swift`
  负责快照存储、统一 ISO8601 编解码以及 WatchConnectivity 字段协议
- `WatchSync/WatchScheduleSyncManager.swift`
  负责 iPhone 与 watch 间的镜像同步，并记录不包含课表内容的结构化错误日志
- `BIT101Watch/WatchScheduleStatusModel.swift`
  负责 Watch 页面状态协调；系统时间、快照读取和同步入口均通过依赖边界注入

维护手表相关问题时按以下顺序检查：

1. 主 App 成功导出 `ScheduleExternalSnapshot`
2. `WatchConnectivity` 将镜像送到 watch
3. watch 侧成功写入共享快照
4. `contentState` 正确区分未同步、未登录、无效快照和确实无课
5. watch app / widget 消费解析结果

已同步且 `courses` 为空时按“空学期”处理并显示“暂无后续课程”。无效快照条件包括：首周日期无法解析；存在课程时缺失节次表。

## 11. 文件级入口

首次接手项目时按以下顺序阅读：

1. `README.md`
2. `docs/CODEBASE_GUIDE.md`
3. `docs/FILE_INDEX.md`
4. `Shell/AppShellView.swift`
5. 你正在修改的模块的 `Service -> ViewModel -> RootView`

## 12. 当前维护约定

- 复杂网络链路优先在 service 层写清“为什么这样做”
- 状态机文件优先说明刷新、缓存恢复、取消态处理
- 视图文件优先说明页面层级、路由、弹层、手势关系
- 用户可见行为发生较大变化时，同步更新：
  - 代码注释
  - `README`
  - `docs/CODEBASE_GUIDE.md`
  - 相关维护文档
