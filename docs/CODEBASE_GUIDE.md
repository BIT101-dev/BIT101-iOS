# BIT101-iOS 代码库导览

这份文档对应当前 iOS 端代码基线，目标不是重复源代码，而是帮助后续维护时快速回答下面几个问题：

- 这个模块的职责是什么
- 数据从哪里来，最后落到哪里
- 哪些行为是平台约束，哪些只是当前实现选择
- 如果要改某个功能，应该先看哪几个文件

## 1. 总体结构

项目由两部分组成：

- `BIT101-iOS`
  主应用 target
- `BIT101ScheduleWidget`
  小组件、锁屏组件、Live Activity / 灵动岛扩展 target
- `BIT101Watch`
  Apple Watch 单 target 应用，包含应用入口、主界面与同步消费逻辑
- `BIT101WatchWidgets`
  Apple Watch Smart Stack 课表组件

主应用的顶层流程非常直接：

1. `BIT101_iOSApp.swift`
   挂载根视图，应用全局主题和屏幕方向策略。
2. `ContentView.swift`
   决定当前进入登录页还是登录后壳层。
3. `Shell/AppShellView.swift`
   登录后负责底部 tab、深链分发、跨模块弹层和全局路由。

当前底部 tab 顺序是：

1. 日程
2. 地图
3. 话廊
4. 成绩
5. 我的

## 2. 横切约束

在读各模块前，先记住这几个全局约束。

### 2.1 账号隔离

下面这些数据已经按学号隔离：

- 课表 / DDL / 考试缓存
- 一部分界面与查询偏好

所以：

- 不能再把账号相关状态写回全局唯一 key
- 退出登录或切号后，相关缓存和设置必须重新定位到当前账号

主要入口：

- `Login/LoginService.swift`
- `Settings/AppSettingsStore.swift`
- `Schedule/ScheduleModels.swift`

### 2.2 主 App 与 Widget / Watch 的边界

Widget、锁屏组件、Apple Watch、Live Activity 不能直接依赖主 App 里复杂的缓存对象。

当前设计是：

- 主 App 负责从课表缓存导出精简快照
- Widget / Watch 只读共享容器里的快照
- Live Activity 也尽量走最小必要状态

主要入口：

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `Shared/ScheduleSharedOccurrence.swift`
- `WatchSync/WatchScheduleSyncManager.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`

### 2.3 图片与头像缓存

项目已经不再只依赖系统默认缓存，而是有一层本地显式头像缓存。维护这部分时要注意：

- 内存缓存和磁盘缓存都在起作用
- 更换头像 URL 规则时，要注意缓存 key 是否仍然稳定
- 图片列表和头像缓存是两类问题，不要混在一起处理

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

登录链路大致分三段：

1. 请求学校 CAS 页面，提取登录所需参数
2. 提交学校账号密码并完成学校侧 cookie 落地
3. 走 BIT101 的登录 / 注册桥接，拿到项目自己的 `fake-cookie`

最终状态分别落在：

- Keychain
  学校账号密码与必要凭据
- 本地 cookie / session
  学校 SSO 与 BIT101 会话
- `AppSettingsStore`
  与账号关联的偏好设置

### 3.3 维护重点

- 冷启动有本地会话时先展示主壳层，后台静默校验；不要用“恢复登录状态”过渡页阻塞课表首屏
- 学校 SSO 有历史上的 `http -> https` 跳转问题，所以 `LoginService` 内有 URL 升级逻辑
- 登录链路只要失败，首先分清是学校登录失败，还是 BIT101 注册 / 登录桥接失败
- 登录态检查要保持“保守清退”：`LoginService.checkLogin()` 只有在远端明确说明凭据无效时才清本地 session，例如 BIT101 `/user/check` 返回 401，或学校 CAS 静默重登明确失败。网络错误、学校登录页结构异常、临时拿不到静默恢复参数、缺少本地恢复凭据等情况应向上抛错，不要删除 `fake-cookie`。
- 切号行为不只是清 cookie，还会触发账号变更通知，影响设置页、日程缓存和话廊规则状态
- `fake-cookie` 会影响共享课表快照里的 `isLoggedIn`，进而影响 widget / Apple Watch 展示；不要把一次不确定的登录检查失败扩散成外部展示层“未登录”。

这里要区分两条认证链：`LoginService` 负责 App/BIT101 登录与恢复；课表、成绩、空教室、
可信成绩单使用 `ScheduleService` / `ScoreService` 内的 bit-login challenge。后者的 token
是短期内存状态，不能写进 Keychain，也不能拿普通 `jwb` challenge 去请求 `jwb_cjd`。

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
  短信认证后的同步续接目的
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

日程模块遵循“先快开，再同步”的策略：

1. 先读本地缓存，保证页面秒开
2. 用户再手动发起同步，刷新远端数据
3. 自定义日程与远端课表混合展示，但由本地统一管理

### 4.3 课表 / DDL / 空教室的职责边界

- 课表
  负责课程、考试、自定义日程和课程周视图
- DDL
  负责乐学导入后的截止事项与本地完成状态
- 空教室
  负责校区、教学楼、节次的当前查询

这些能力由日程根视图和各自的分栏视图协作，但状态来源并不一样：

- 课表 / DDL / 考试：依赖课表缓存
- 空教室：依赖查询偏好 + 当前查询结果
- 自定义日程：纯本地 CRUD

### 4.4 近期实现要点

当前日程模块已经加入了几类偏好和自动匹配：

- 学期选择只展示学校接口实际返回的值，不在本地追加未来学期
- 学期选择先独立落盘；课表请求失败只提示错误，不回滚学期。已有快照立即复用，没有快照时展示空课表，避免把旧学期课程误显示到新学期
- 同步指定学期时会同时获取该学期课程、考试和第一周日期；普通刷新保持用户已选学期
- 周视图支持第 1 周之前和课程周数之后的周次，并跳过不存在的第 0 周
- 手动翻页不受课程最后一周限制；冷启动、学期切换、同步和“回到本周”等自动定位会将计算结果限制在第 -12 至 +20 周
- 未发布学期没有课表时按空课表处理，不用错误页挡住页面操作
- 空教室会记住校区偏好
- 空教室会优先用“最近下一节课”去精确匹配教学楼
- 空教室节次会按当前时段块自动匹配
- 课表顶部日期格支持进入调休 / 放假页面，可清空当天课程或将当天课程调至其它日期

这些都意味着：

- 不要轻易把“用户上一次选择”覆盖为默认值
- 但空教室的“最近课程楼匹配”优先级应高于缓存
- 教学中心会话按账号校验并允许失效；业务响应为 401/403、登录页或非 JSON 时才触发有限恢复

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

成绩页现在完全是原生实现，不再依赖历史 WebView。

关键点：

- 查询直接复用已保存的学校账号密码
- 普通成绩通过 bit-login 的 `jwb` 服务查询；由于均分、排名和详情字段只在完整模式返回，列表使用 `detail=true`
- 普通 HTTP 请求超时为 25 秒；完整成绩查询、首次认证与轮询最多等待约 90 秒
- 服务端返回 `202` 时展示原生短信验证码 sheet，并正确处理错误码、过期和重复提交
- 学期筛选与成绩类型筛选支持全选 / 全不选 / 0 选
- 上一次筛选结果与列表排序偏好会按账号保存
- 成绩列表默认按名称排序，并支持按名称、成绩、均分、学分、学期、种类升序 / 降序排序
- 可信成绩单使用独立的 `jwb_cjd` challenge；入口在成绩同步期间禁用
- 成绩单图片使用 ephemeral 会话下载，只保留在内存中，点击后复用话题图片全屏缩放器

维护这块时要注意：

- 筛选状态是 UI 偏好，也是查询结果展示逻辑的一部分
- 不能因为刷新查询结果而直接把用户筛选重置掉
- 排序只影响列表展示顺序，不改变统计摘要的计算口径
- 普通成绩与可信成绩单的 challenge 必须相互独立，退出页面后不持久化 token 或成绩单图片

### 5.3 课程合并入口

“成绩”底部入口内部通过顶部分段控件承载“成绩 / 课程”。课程能力位于 `Course/`，包括：

- 课程浏览、搜索与分页
- 课程详情、教师信息和历年成绩统计
- 点赞、评分、评论及评论图片预览

课程列表与详情各自拥有 Service / ViewModel，不应塞进 `ScoreViewModel`。左右滑动只负责切换
一级内容，不应触发成绩筛选或可信成绩单状态变化。

## 6. 地图模块

### 6.1 组成文件

- `Map/CampusMapScreen.swift`

### 6.2 当前设计

地图页使用 `MKMapView` 桥接，而不是纯 SwiftUI `Map`。

原因是：

- 需要更细的地图层控制
- 需要做校园底图与自定义跳转
- 需要兼容中国区 provider attribution 的处理

### 6.3 维护重点

地图页里有一部分是平台桥接，一部分是工程 hack：

- `UIViewRepresentable + MKMapView`
  这是合理桥接
- attribution/legal label 的隐藏处理
  这是更脆弱的内部视图层级 hack

后续如果地图出现系统版本兼容问题，优先先看 attribution 那块，而不是怀疑全部地图逻辑都坏了。

## 7. 话廊模块

### 7.1 组成文件

- `Gallery/GalleryModels.swift`
  帖子、评论、搜索、消息、用户等模型
- `Gallery/CommunityModeration.swift`
  本地敏感词和屏蔽规则
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

### 7.2 当前用户视角能力

话廊当前已经包含：

- `关注 / 推荐 / 最新 / 最热 / 机器人` feed
- 搜索
- 发帖
- 评论
- 本地屏蔽
- 消息中心
- 帖子详情跳他人主页

### 7.3 关键约束

#### 7.3.1 feed 切换

为了避免此前 `TabView(.page)` 带来的底部黑边与布局问题，feed 切换采用了轻扫手势方案，而不是系统 pager。

这意味着：

- 横向切换体验是刻意保留的
- 如果后续想回退到原生 pager，需要重新验证底部覆盖和 tab bar 采样问题

#### 7.3.2 推荐流

推荐流是目前最特殊的一条链路。

原因：

- 后端推荐链路本身更重
- 可能需要随机补帖
- 本地还会对帖子做屏蔽或机器人过滤

所以维护推荐流时要同时留意：

- 分页触发点
- 本地可见列表与原始列表的关系
- 预取与真实 append 的时机
- 去重

#### 7.3.3 消息中心

消息中心的已读语义当前不是服务端逐条已读，而是：

- 服务端提供分类未读数
- 客户端基于当前分类未读数做“伪新消息”表现

所以：

- 这套已读状态不是跨设备强一致
- 只能作为本地 UI 体验优化，而不是服务端真实消息状态

### 7.4 屏蔽与敏感词

当前敏感词与本地屏蔽有多层：

1. 发帖前本地校验
2. 展示前本地过滤
3. 机器人相关显示策略

维护这部分时不要混淆：

- “服务端不返回”
- “客户端不展示”
- “搜索仍允许展示”

这三者是不同层面的策略。

### 7.5 文章合并入口

“话廊”底部入口内部通过顶部分段控件承载“话题 / 文章”。文章代码位于 `Paper/`，
负责列表、搜索、发布、编辑、详情、点赞和评论。文章正文使用本地模型解析与原生渲染，
未知正文块静默忽略，不为阅读能力回退到 WebView。

文章与话题会复用用户、评论和全屏图片查看器等基础能力，但分别维护分页与详情状态；
从深链打开文章时由 `AppShellView` 先切到话廊，再把文章 ID 交给 `PaperRootView`。

## 8. 我的模块

### 8.1 组成文件

- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`

### 8.2 当前设计

“我的”页承担三件事：

- 个人资料总览
- 粉丝 / 关注 / 帖子入口
- 设置与关于入口

另外它也是“他人主页”的宿主模块。当前已经支持：

- 从帖子详情进入他人主页
- 从评论作者进入他人主页
- 在他人主页继续浏览其帖子

### 8.3 维护重点

- 我的帖子与话廊帖子卡片尽量复用一套 UI，不要分叉
- 资料页里的账号信息与“账号设置”里的账号信息不要重复堆叠

## 9. 设置模块

### 9.1 组成文件

- `Settings/AppSettingsStore.swift`
  全局设置快照、账号隔离设置、读写桥接
- `Settings/SettingsServices.swift`
  设置页复用的网络辅助
- `Settings/SettingsRootView.swift`
  设置页与关于页

### 9.2 当前设计

设置页不是“杂项回收站”，而是当前项目很多运行时行为的总入口，包括：

- 外观模式
- 屏幕旋转
- 话廊相关设置
- 课表与灵动岛提醒设置
- 关于页与开源说明

### 9.3 当前注意事项

- 一部分设置是全局的
- 一部分设置按账号隔离
- 修改设置后，很多页面要求即时生效

所以维护设置时要先判断：

- 这是纯显示偏好，还是账号态数据
- 改完后是否需要通知其它模块立即刷新

## 10. 小组件、Apple Watch 与灵动岛

### 10.1 组成文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidgetBundle.swift`
- `BIT101Watch/BIT101WatchApp.swift`
- `BIT101Watch/WatchScheduleRootView.swift`
- `BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`
- `BIT101WatchWidgets/BIT101WatchWidgetsBundle.swift`

### 10.2 当前能力

当前已经支持：

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

小组件和 Live Activity 的深链统一走：

- `bit101://...`

目前课程类入口统一落到：

- `bit101://schedule/courses`

#### 10.3.3 灵动岛显示策略

当前灵动岛提醒不是永久常驻，而受“提前显示阈值”控制。

维护时要区分：

- 小组件
- 锁屏组件
- Live Activity
- Dynamic Island

它们虽然共享同一批课表快照，但显示策略和平台约束并不一样。

#### 10.3.4 watch 端逻辑收口

工程已经迁移到新版 Xcode 的单 Watch App target 结构：应用入口和主界面位于
`BIT101Watch/`，Smart Stack 仍由 `BIT101WatchWidgets` 扩展提供。不要重新创建旧式
`BIT101WatchExtension` target。

watch app 与 watch widget 当前都不再各自维护一套“读快照 -> 算下一节课”的流程，而是统一复用：

- `Shared/ScheduleSharedOccurrence.swift`
  负责共享快照到 `ScheduleExternalOccurrence` 的解析、内容状态判定和时间线刷新规划
- `Shared/ScheduleSharedSnapshot.swift`
  负责快照存储、统一 ISO8601 编解码以及 WatchConnectivity 字段协议
- `WatchSync/WatchScheduleSyncManager.swift`
  负责 iPhone 与 watch 间的镜像同步，并记录不包含课表内容的结构化错误日志
- `BIT101Watch/WatchScheduleStatusModel.swift`
  负责 Watch 页面状态协调；系统时间、快照读取和同步入口均通过依赖边界注入

这意味着维护手表相关问题时，建议优先按下面顺序看：

1. 主 App 是否成功导出了 `ScheduleExternalSnapshot`
2. `WatchConnectivity` 是否把镜像送到了 watch
3. watch 侧是否成功落地共享快照
4. `contentState` 是否正确区分未同步、未登录、无效快照和确实无课
5. watch app / widget 是否只是消费了解析结果

已同步但 `courses` 为空是“空学期”的有效结果，应显示“暂无后续课程”；只有首周日期无法解析，或在有课程时缺失节次表，才属于无效快照。

## 11. 文件级入口建议

如果你是第一次接手项目，建议按下面顺序进入：

1. `README.md`
2. `docs/CODEBASE_GUIDE.md`
3. `docs/FILE_INDEX.md`
4. `Shell/AppShellView.swift`
5. 你正在修改的模块的 `Service -> ViewModel -> RootView`

## 12. 当前维护约定

- 复杂网络链路优先在 service 层写清“为什么这样做”
- 状态机文件优先说明刷新、缓存恢复、取消态处理
- 视图文件优先说明页面层级、路由、弹层、手势关系
- 大改用户可见行为后，要同步更新：
  - 代码注释
  - `README`
  - `docs/CODEBASE_GUIDE.md`
  - 相关维护文档
