# BIT101-iOS 架构说明

这份文档聚焦在“整个 App 是怎么串起来的”，适合在下面这些场景阅读：

- 你第一次接手这个仓库
- 你准备改动跨模块行为
- 你需要判断某个状态应该落在哪一层
- 你想知道主 App、widget、Live Activity 是如何协作的

## 1. 系统边界

当前项目可以拆成五个边界明确的系统：

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

维护时最容易犯的错，是把这五层的边界混掉。

## 2. 主 App 的基本流转

主 App 的主链路如下：

1. `BIT101_iOSApp.swift`
   建立 app 级环境，例如主题和屏幕方向。
2. `ContentView.swift`
   根据登录状态决定进入登录模块还是登录后壳层。
3. `Shell/AppShellView.swift`
   进入登录后的 tab 壳层，承接底部栏、深链路由和全局弹层。
4. 各业务模块各自维护：
   - `Service`
   - `ViewModel`
   - `RootView`

当前工程没有一个“大总管”对象负责所有状态，而是由：

- App 入口负责全局环境
- Shell 负责全局路由
- 每个模块自己维护自己的 service / state / view

## 3. 模块分层约定

每个大模块基本都遵守相同的三层结构：

### 3.1 Model

职责：

- 描述数据结构
- 定义分页状态、筛选状态、缓存结构
- 提供纯数据层的辅助方法

不应该承担的职责：

- 直接发请求
- 直接操作 UI

### 3.2 Service

职责：

- 网络请求
- 响应解析
- 接口兼容处理
- 某些需要贴近数据源的过滤或归一化

不应该承担的职责：

- 控制界面状态
- 持有复杂的页面交互逻辑

### 3.3 ViewModel

职责：

- 刷新、分页、预取、错误态
- 本地状态管理
- 页面间状态桥接
- 写回偏好设置或缓存

不应该承担的职责：

- 直接画复杂 UI
- 与具体控件实现深度耦合

### 3.4 RootView

职责：

- 页面布局
- 手势
- 路由跳转
- 弹层与 sheet
- 将 `ViewModel` 状态投影为 UI

不应该承担的职责：

- 复杂网络逻辑
- 大量数据拼接和计算

### 3.5 Shared Infrastructure

跨模块、无业务语义的基础能力放在 `Shared/Infrastructure`，目前包括：

- `AppAlert`：页面提示数据，不再由登录模块反向提供给其它业务。
- `TaskCancellation`：统一识别 Concurrency 与 URLSession 取消错误。
- `AccountScopedCodableStore`：统一账号隔离的 Codable 快照存储键。
- `makeHorizontalSwitchGesture`：保持多个 segmented 页面一致的轻扫阈值。
- `PagedItemsState`：统一页码分页列表的重置、首屏回写、追加和尾部预加载判断。

ViewModel 对 Service 的依赖应优先使用按页面场景划分的协议。例如课程列表不需要知道课程详情的评论接口。协议用于缩小依赖面和支持测试，不要求把所有 Service 合并成一个通用网络层。

当前登录、课程、话廊、文章、我的主页、日程和成绩 ViewModel 都通过场景协议依赖网络层。生产环境仍由原有 Service 实现这些协议；共享层只处理通用 HTTP 和社区 API 规则，请求路径与业务认证状态仍归具体 Service 所有。

### 3.6 Shared Networking

网络传输统一放在 `Shared/Networking`：

- `HTTPClient` 处理 URLSession 传输、HTTP 响应和状态码。
- `CommunityAPIClient` 处理社区 API 的 URL、fake-cookie 和 JSON。
- `NetworkSessionPool` 复用社区、成绩认证和敏感下载会话。

学校 CAS、教学中心和成绩 challenge 只共享 HTTP 传输能力，不共享认证状态。详细边界见 `docs/NETWORKING.md`。

大视图文件按可独立维护的叶子功能拆分：话廊 feed/搜索/消息/详情/评论、日程日历/编辑/DDL、设置各域、文章各场景和课程成绩/评论均有独立文件。拆分只改变源码归属，不改变页面路由和视图层级。登录与日程服务同样把纯解析、存储和 DTO 从业务门面分离。

## 4. 数据来源分类

当前工程里的数据大致来自五种来源：

### 4.1 服务端接口

例如：

- 话廊 feed
- 消息中心
- 我的主页
- 他人主页

这类数据的特点是：

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

这类数据的特点是：

- 链路更脆
- 更容易受学校系统变更影响
- 常常需要额外兼容逻辑

学校业务并不共用一个永久“已登录”布尔值。当前课表、考试与空教室通过 bit-login
建立可失效的教学中心会话；普通成绩和可信成绩单分别使用 `jwb`、`jwb_cjd` challenge。
服务端要求短信验证时，短期 `challenge_id` 与 access token 只停留在内存中。

### 4.3 本地缓存

例如：

- 课表 / DDL / 考试缓存
- 自定义日程
- 图片缓存
- 按账号隔离的基础成绩缓存

这类数据的目标是：

- 让页面秒开
- 让用户在服务端不可用时仍能看到最近一次数据

可信成绩单是例外：学校返回的是短期敏感图片，当前只在内存中预览，不进入通用图片磁盘缓存。

### 4.4 本地偏好

例如：

- 主题模式
- 旋转开关
- 查询筛选
- 普通帖子页面是否隐藏机器人帖子（搜索、推荐、关注、个人主页等；机器人分栏除外）

这类数据要先判断是否按账号隔离。

### 4.5 共享快照

例如：

- 小组件和锁屏组件读取的课表快照
- Apple Watch app / Smart Stack 读取的课表快照

它的目标不是替代主 App 缓存，而是把扩展真正需要的最小信息单独导出。

## 5. 账号隔离在架构中的位置

账号隔离不是某一个模块的功能，而是整个工程的一条横切原则。

目前账号隔离至少影响：

- 课表缓存
- DDL 缓存
- 成绩缓存与筛选偏好
- 教学中心内存会话
- 一部分筛选和偏好

所以判断某个新状态该放哪，建议用下面这套问题：

1. 这个状态是否应该随学号切换而变化
2. 这个状态是否会影响别的账号看到的内容
3. 退出登录后，这个状态是否还应该保留

如果答案偏向“跟账号走”，就不要写成全局唯一状态。

## 6. 话廊为何不是系统 pager

这是当前代码里一个重要的架构选择。

话廊和日程的分栏切换没有用 `TabView(.page)`，而是用了：

- 顶部分栏
- 轻扫手势切换

原因不是“故意造轮子”，而是之前原生 pager 在这个项目里带来了：

- 底部黑边
- 内容不贴底
- tab bar 采样异常

所以现在的实现是围绕“视觉与布局稳定”做出的工程折中。后续如果想改回系统 pager，应该把它当成一次明确的架构调整，而不是小修小补。

## 7. 为什么 widget 不直接读主 App 缓存

因为这会把两个 target 的耦合推高，而且调试成本非常大。

当前结构选择了：

1. 主 App 持有完整课表缓存
2. `ScheduleWidgetSupport` 导出精简快照
3. widget / 锁屏组件 / Live Activity 全部读取快照

这样做的好处是：

- 扩展目标更轻
- 共享数据边界更清晰
- 课表内部结构调整时，有明确的导出层可改

## 8. Apple Watch 为什么也走共享快照

watch app 和 watch widget 当前遵循和桌面 widget 类似的原则：

1. iPhone 主 App 仍然是真相源
2. 主 App 导出 `ScheduleExternalSnapshot`
3. watch 端只负责：
   - 请求最新镜像
   - 落地镜像
   - 读取镜像
   - 展示“当前 / 下一节 / 后续课程”

桌面 Widget、Watch App 和 Watch Widget 统一通过 `ScheduleExternalContentState`
区分“未同步 / 未登录 / 快照无效 / 无课 / 有课”，并通过
`ScheduleTimelineRefreshPlanner` 计算课程切换与跨日刷新时刻。快照磁盘存储和
WatchConnectivity 传输共同使用 `ScheduleExternalSnapshotCodec`，避免日期策略漂移。

这样做的原因是：

- watch 端不需要重复维护“首周 + 周次 + 节次 -> 实际上课时间”的推导
- watch app 与 watch widget 可以共享同一套最小解析逻辑
- 同步问题可以优先收敛到 `WatchConnectivity + shared snapshot` 这条链路上排查
- Watch 同步错误会写入 `WatchScheduleSync` 分类日志，但不会记录课表正文或学生信息

## 9. Live Activity 与 Widget 的区别

虽然它们都依赖课表快照，但设计目标不同：

- Widget
  适合稳定展示“下一节 / 后续几节”
- 锁屏组件
  适合高密度、静态 glance
- Live Activity
  适合短时间内围绕“当前项 / 下一项”的提醒

所以不要把 Live Activity 当成“另一个 widget family”。它本质上是另一套生命周期模型。

## 10. 项目里的几类“工程性折中”

这个仓库不是纯粹理想化的架构，里面存在一些带历史原因的折中。

典型包括：

- 话廊和日程的自定义轻扫切换
- 地图页的 `MKMapView` 桥接与 attribution 处理
- 消息中心基于服务端分类未读数做本地“伪新消息”
- 一些学校系统登录与跳转兼容逻辑
- 话题图片与可信成绩单共用的 `UIScrollView` 全屏缩放桥

维护这些部分时，先理解它们“为什么存在”，再决定是否值得重写。

## 11. 推荐的接手顺序

如果你是第一次系统性阅读这个工程，建议按下面顺序：

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/CODEBASE_GUIDE.md`
4. `docs/STATE_AND_STORAGE.md`
5. `docs/FILE_INDEX.md`
6. 再进入对应模块代码

这样能先建立边界感，再看具体实现细节。
