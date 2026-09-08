# BIT101-iOS 架构说明

本文说明 App 的系统边界、主 App 流转、模块分层、数据来源和扩展协作。以下情况可先阅读本文：

- 首次接手这个仓库
- 准备改动跨模块行为
- 需要判断某个状态所属的层级
- 需要了解主 App、widget、Live Activity 的协作方式

## 1. 系统边界

当前项目由五个边界明确的系统组成：

1. 主 App
   负责登录、页面展示、缓存、设置、用户交互和大部分网络请求。
2. Widget / 锁屏组件扩展
   负责桌面与锁屏的课表展示。
3. Apple Watch App / Smart Stack
   负责手表上的“当前项 / 下一项”查看，以及 watch 本地镜像消费。
4. Live Activity / Dynamic Island
   负责“当前项 / 下一项”的实时提醒。
5. 服务端系统
   包括学校 CAS / 教务 / 乐学，以及 BIT101 自己的后端。

维护时需要区分这五层边界。

## 2. 主 App 的基本流转

主 App 按以下链路运行：

1. `BIT101_iOSApp.swift`
   设置 app 级环境，例如主题和屏幕方向。
2. `ContentView.swift`
   根据登录状态决定进入登录模块还是登录后壳层。
3. `Shell/AppShellView.swift`
   进入登录后的 tab 壳层，管理底部栏、深链路由和全局弹层。
4. 业务模块分别维护：
   - `Service`
   - `ViewModel`
   - `RootView`

状态由以下三部分分别维护：

- App 入口负责全局环境
- Shell 负责全局路由
- 每个模块维护自己的 service / state / view

## 3. 模块分层约定

业务模块按以下职责分层：

### 3.1 Model

职责：

- 描述数据结构
- 定义分页状态、筛选状态、缓存结构
- 提供纯数据层的辅助方法

边界：

- 网络请求由 Service 处理
- UI 操作由 RootView 处理

### 3.2 Service

职责：

- 网络请求
- 响应解析
- 接口兼容处理
- 某些需要贴近数据源的过滤或归一化

边界：

- 界面状态由 ViewModel 管理
- 复杂的页面交互由 RootView 管理

### 3.3 ViewModel

职责：

- 刷新、分页、预取、错误态
- 本地状态管理
- 页面间状态桥接
- 写回偏好设置或缓存

边界：

- 复杂 UI 由 RootView 绘制
- ViewModel 与具体控件实现保持松耦合

### 3.4 RootView

职责：

- 页面布局
- 手势
- 路由跳转
- 弹层与 sheet
- 将 `ViewModel` 状态投影为 UI

边界：

- 复杂网络逻辑由 Service 处理
- 大量数据拼接和计算由 Service 或 ViewModel 处理

### 3.5 Shared Infrastructure

跨模块、无业务语义的基础能力统一放在 `Shared/Infrastructure`，目前包括：

- `AppAlert`：共享层提供页面提示数据，业务模块通过共享层使用。
- `TaskCancellation`：统一识别 Concurrency 与 URLSession 取消错误。
- `AccountScopedCodableStore`：统一账号隔离的 Codable 快照存储键。
- `makeHorizontalSwitchGesture`：为多个 segmented 页面提供一致的轻扫阈值。
- `PagedItemsState`：统一页码分页列表的重置、首屏回写、追加和尾部预加载判断。

ViewModel 优先通过按页面场景划分的协议依赖 Service。例如，课程列表不需要依赖课程详情的评论接口。协议用于缩小依赖面和支持测试；各 Service 按业务场景保留独立职责。

当前登录、课程、话廊、文章、我的主页、日程和成绩 ViewModel 都通过场景协议依赖网络层。生产环境由原有 Service 实现这些协议；共享层处理通用 HTTP 和社区 API 规则，请求路径与业务认证状态由具体 Service 管理。

### 3.6 Shared Networking

网络传输统一放在 `Shared/Networking`：

- `HTTPClient` 处理 URLSession 传输、HTTP 响应和状态码。
- `CommunityAPIClient` 处理社区 API 的 URL、fake-cookie 和 JSON。
- `NetworkSessionPool` 复用社区、成绩认证和敏感下载会话。

学校 CAS、教学中心和成绩 challenge 共享 HTTP 传输能力，各自维护认证状态。详细边界见 `docs/NETWORKING.md`。

大视图文件按可独立维护的功能拆分：话廊 feed/搜索/消息/详情/评论、日程日历/编辑/DDL、设置各域、文章各场景和课程成绩/评论均有独立文件。拆分保持页面路由和视图层级稳定；登录与日程服务也将纯解析、存储和 DTO 从业务门面分离。

## 4. 数据来源分类

当前工程的数据来自五类来源：

### 4.1 服务端接口

例如：

- 话廊 feed
- 消息中心
- 我的主页
- 他人主页

这类数据具备以下特点：

- 可随时刷新
- 以服务端为准
- 本地多为短期 UI 状态

### 4.2 学校系统

例如：

- 登录
- 成绩
- 课表
- 考试
- 空教室
- 可信成绩单

这类数据具备以下特点：

- 链路更脆
- 更容易受学校系统变更影响
- 常常需要额外兼容逻辑

学校业务按链路维护可失效会话。当前课表、考试与空教室通过 bit-login
建立可失效的教学中心会话；普通成绩和可信成绩单分别使用 `jwb`、`jwb_cjd` challenge。
服务端要求短信验证时，短期 `challenge_id` 与 access token 只停留在内存中。

### 4.3 本地缓存

例如：

- 课表 / DDL / 考试缓存
- 自定义日程
- 图片缓存
- 按账号隔离的基础成绩缓存

本地缓存用于：

- 支持页面快速打开
- 服务端不可用时，页面仍显示最近一次数据

可信成绩单单独处理：学校返回的是短期敏感图片，当前保存在内存中预览，通用图片磁盘缓存保持独立。

### 4.4 本地偏好

例如：

- 主题模式
- 旋转开关
- 查询筛选
- 普通帖子页面是否隐藏机器人帖子（搜索、推荐、关注、个人主页等；机器人分栏除外）

写入这类数据前，先确定是否按账号隔离。

### 4.5 共享快照

例如：

- 小组件和锁屏组件读取的课表快照
- Apple Watch app / Smart Stack 读取的课表快照

共享快照向扩展导出所需的最小信息，主 App 缓存继续由主 App 管理。

## 5. 账号隔离在架构中的位置

账号隔离是整个工程的横切原则。

目前账号隔离至少影响：

- 课表缓存
- DDL 缓存
- 成绩缓存与筛选偏好
- 教学中心内存会话
- 一部分筛选和偏好

判断新状态的存放层级时，依次回答：

1. 这个状态是否应该随学号切换而变化
2. 这个状态是否会影响别的账号看到的内容
3. 退出登录后，这个状态是否还应该保留

如果状态随账号变化，就按账号隔离。

## 6. 为什么话廊和日程不用系统 pager

当前代码采用自定义分栏切换。

话廊和日程的分栏切换使用以下实现，未使用 `TabView(.page)`：

- 顶部分栏
- 轻扫手势切换

项目曾使用原生 pager，出现了以下问题：

- 底部黑边
- 内容不贴底
- tab bar 采样异常

当前实现优先保证视觉与布局稳定。改回系统 pager 需要按明确的架构调整处理。

## 7. 为什么 widget 不直接读主 App 缓存

两个 target 直接读取主 App 缓存会增加耦合和调试成本。

当前结构采用以下数据链路：

1. 主 App 持有完整课表缓存
2. `ScheduleWidgetSupport` 导出精简快照
3. widget / 锁屏组件 / Live Activity 全部读取快照

该链路带来以下结果：

- 扩展目标更轻
- 共享数据边界更清晰
- 课表内部结构调整时，有明确的导出层可改

## 8. Apple Watch 为什么也走共享快照

watch app 和 watch widget 遵循与桌面 widget 相同的共享快照原则：

1. iPhone 主 App 是真相源
2. 主 App 导出 `ScheduleExternalSnapshot`
3. watch 端负责以下工作：
   - 请求最新镜像
   - 落地镜像
   - 读取镜像
   - 展示“当前 / 下一节 / 后续课程”

桌面 Widget、Watch App 和 Watch Widget 统一通过 `ScheduleExternalContentState`
区分“未同步 / 未登录 / 快照无效 / 无课 / 有课”，并通过
`ScheduleTimelineRefreshPlanner` 计算课程切换与跨日刷新时刻。快照磁盘存储和
WatchConnectivity 传输共同使用 `ScheduleExternalSnapshotCodec`，避免日期策略漂移。

共享快照带来以下结果：

- “首周 + 周次 + 节次 -> 实际上课时间”的推导在主 App 侧完成，watch 端直接使用推导结果
- watch app 与 watch widget 可以共享同一套最小解析逻辑
- 同步问题沿 `WatchConnectivity + shared snapshot` 链路排查
- Watch 同步错误写入 `WatchScheduleSync` 分类日志；该日志不记录课表正文或学生信息

## 9. Live Activity 与 Widget 的区别

Widget、锁屏组件和 Live Activity 都依赖课表快照，各自的设计目标不同：

- Widget
  适合稳定展示“下一节 / 后续几节”
- 锁屏组件
  适合高密度、静态 glance
- Live Activity
  适合短时间内围绕“当前项 / 下一项”的提醒

Live Activity 使用独立的生命周期模型，与 widget family 分开维护。

## 10. 项目里的几类“工程性折中”

仓库包含一些受历史原因影响的工程折中。

典型折中包括：

- 话廊和日程的自定义轻扫切换
- 地图页的 `MKMapView` 桥接与 attribution 处理
- 消息中心基于服务端分类未读数做本地“伪新消息”
- 一些学校系统登录与跳转兼容逻辑
- 话题图片与可信成绩单共用的 `UIScrollView` 全屏缩放桥

维护这些部分时，先确认它们的存在原因，再评估是否重写。

## 11. 推荐的接手顺序

首次系统性阅读这个工程时，按下面顺序：

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/CODEBASE_GUIDE.md`
4. `docs/STATE_AND_STORAGE.md`
5. `docs/FILE_INDEX.md`
6. 再进入对应模块代码

该顺序先介绍项目边界，再进入具体实现细节。
