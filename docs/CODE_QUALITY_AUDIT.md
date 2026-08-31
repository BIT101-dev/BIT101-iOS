# BIT101-iOS 代码质量审计说明

这份文档记录的是当前 iOS 代码库在“可维护性、重复实现、桥接实现、清理方向”上的状态。

它不试图替代源码注释，也不试图做一次性的“大重构计划”。
它的目标只有两个：

1. 让后续维护者快速知道：哪些地方已经收过，哪些地方还故意保留着。
2. 当你准备继续清理某个大文件时，先知道哪些代码是“桥接必需”，哪些只是历史上为了赶进度留下的实现。

## 1. 2026 年 8 月重构结果

本轮在 Xcode 27 Beta 下建立基线后，完成了以下工作：

- 修复 unsigned test host 中 CloudKit 过早初始化导致的崩溃，以及 watch 状态模型的并发警告。
- 按叶子功能拆分 Gallery、Schedule、Settings、Paper、Course 的巨型视图；根视图只保留布局、路由和弹层协调。
- 将课程草稿校验/周次编解码与空教室展示计算从 `ScheduleViewModel` 提取为纯组件。
- 将登录服务拆成会话、Keychain 存储、密码变换、CAS HTML 解析、API 客户端和业务门面。
- 将日程服务的 ICS 解析、学校接口 DTO 和字符串解析分离。
- 自动化测试现有 71 项，覆盖账号隔离、分页、取消/失败状态、登录兼容向量、ICS、课程编辑、空教室和列表状态机。
- 每个结构性提交都通过 `build-for-testing`；最终同时通过模拟器全测和 iPhone 17 真机构建、安装与启动。

本轮刻意不修改学校请求路径、认证语义、页面路由和既有手势行为，避免把结构整理扩大成产品行为变化。

## 2. 当前仍然保留的“非原生”或桥接实现

这部分不是忘了改，而是有意先保留。后续继续动手时，应先理解它们为什么存在。

### 2.1 AppShell 的通知权限提示

文件：

- `BIT101-iOS/Shell/AppShellView.swift`

当前实现：

- 使用 `UIAlertController`
- 通过 `topViewController()` 手动找到当前最顶层控制器并弹窗

为什么没直接改回 SwiftUI `.alert`：

- 壳层本身同时承载启动公告、深链、登录切换等全局弹层
- 之前已经遇到过多个 SwiftUI alert 互相抢占，导致状态算出来了但界面没弹出的情况

结论：

- 这是“明确的 UIKit 绕路实现”
- 如果未来要回收，应先统一壳层弹窗路由，而不是只把这一条硬改回 `.alert`

### 2.2 话廊首页与消息页的左右滑动切换

文件：

- `BIT101-iOS/Gallery/GalleryRootView.swift`

当前实现：

- 顶部 `Picker(.segmented)`
- 正文区再叠一层手写 `DragGesture`

为什么算“非原生”：

- 它不是系统 pager
- 更像 Android / 网页时期交互的一种迁移式适配

为什么暂时保留：

- 这条交互目前已经和刷新保位、悬浮按钮、顶部 segmented 的布局绑定在一起
- 一次性改成系统分页容器，风险会明显大于当前这轮清理的目标

### 2.3 地图页的 `MKMapView` 桥接

文件：

- `BIT101-iOS/Map/CampusMapScreen.swift`

当前实现：

- `UIViewRepresentable + MKMapView`

它属于：

- 桥接实现
- 但不是“坏味道”本身

原因：

- 地图页需要更细的相机控制、定位回调和瓦片/overlay 能力
- 纯 SwiftUI `Map` 很难完全覆盖现在这页的需求

结论：

- 这是功能型桥接，优先级低于真正的重复和死代码清理

### 2.4 通用全屏图片查看器的 `UIScrollView` 缩放

文件：

- `BIT101-iOS/Gallery/GalleryImageViewer.swift`

当前实现：

- `UIViewRepresentable + UIScrollView + UIImageView`
- 同一缩放容器同时支持远程 URL 和内存 `UIImage`

原因：

- 需要稳定的双指缩放、居中和大图浏览体验
- 可信成绩单属于敏感临时图片，必须复用缩放 UI，但不能复用话题图片的磁盘下载缓存

结论：

- 这同样属于功能型桥接
- 后续可以优化实现细节，但不建议把它简单定义为“应尽快删掉的非原生代码”

## 3. 2026 年 8 月后续定点重构

- `ScheduleModels.swift` 已只保留领域模型和日期/周次编解码；本地存储与 CloudKit 分别迁至 `ScheduleCacheStore.swift`、`ScheduleCloudSyncManager.swift`。
- 缓存旧格式迁移与云端时间戳冲突决策已增加回归测试，CloudKit 决策本身不再依赖签名容器才能验证。
- 空教室请求代次、单次预热、元数据 single-flight 和超时归入 `ScheduleClassroomCoordinator`。
- 课表短信验证后的续接目的归入 `ScheduleCourseSyncCoordinator`，避免学期列表与指定学期同步互相串线。
- Gallery 推荐页后台预取归入 `GalleryRecommendPrefetchCoordinator`；前台分页与后台预取复用同一个源页任务，避免竞态重复请求。

## 4. 重构后的剩余热点

当前已没有同时承载整套子页面的千行级 RootView。剩余较长文件主要是状态机和数据模型：

- `ScheduleViewModel.swift`：仍是日程页面的主状态机，但表单计算、空教室请求生命周期与短信续接状态已移出。后续只在出现新的独立生命周期时继续拆，不按行数机械切割。
- `ScheduleRootView.swift`：剩余的是三分栏容器和页面协调；日历、编辑器与 DDL 子页已经独立。
- `GalleryViewModel.swift`：推荐预取任务已独立；普通 feed、搜索和消息状态仍在同文件中，但属于不同类型，暂不为缩短文件继续拆分。
- `MineRootView.swift`、`ScoreRootView.swift`：约 700 行，但目前以单域原生页面组合为主，没有发现必须立即拆分的高风险耦合。

因此不再按“行数超过某阈值”机械拆文件；优先以可独立测试的职责和真实修改频率判断。

## 5. 代码清理时要守住的边界

继续清理这个项目时，最容易出问题的不是“删少了”，而是“把行为约束一起删掉了”。

### 4.1 先分清“桥接必需”和“历史绕路”

优先不要轻易动的：

- `MKMapView` 桥接
- 图片查看器桥接
- Live Activity / widget target 边界

优先可以继续动的：

- 自定义手势的重复判断
- 分页状态重置 / 成功回写的重复代码
- 同一类错误对象的重复构造
- 无效的 UI 补丁代码

### 4.2 不要为了“更纯”把当前稳定行为改坏

例如：

- AppShell 的 UIKit alert
- 话廊 feed 的 segmented + 手势切换

它们都不够“纯”，但目前行为是稳定的。
如果未来要动，应先在交互层重新设计，而不是只做表面替换。

### 4.3 服务层优先收重复 helper，不要轻易改接口语义

这一轮服务层的清理策略已经证明比较稳：

- 不碰请求路径
- 不碰参数语义
- 只收：
  - fake-cookie 判空
  - JSON 解码器
  - 本地错误构造
  - 纯工具级 helper

后续继续服务层清理时，也建议优先按这个边界来。

学校接口是例外中的高风险区域。当前 `ScheduleService` 和 `ScoreService` 已显式承载
bit-login challenge、短信状态、会话失效识别与有限重试。重构时不能重新引入永久
`didAuthenticate` 布尔值，也不能把 `jwb`、`jwb_cjd` 或教学中心 session 合并成一个全局状态。

## 6. 下一轮建议顺序

1. 为学校接口响应增加脱敏 fixture，重点覆盖认证失效、DNS 路由切换与空响应兼容。
2. 按认证、访问路由、教学中心 API 和乐学日历拆分 `ScheduleService`；保持 `ScheduleService` 为业务门面。
3. 观察空教室协调器和推荐预取协调器的真实修改频率，再决定是否继续扩大职责。
4. 只有在 Mine 或 Score 页面继续增长时，再按独立导航目的地拆分其 RootView。

不建议为了压缩行数优先改 `ScheduleLiveActivityManager.swift` 或 widget：它们牵涉 ActivityKit、后台时序和系统扩展，回归更隐蔽。

## 7. 维护时的一个简单判断法

当你看到一段代码时，可以先问自己三个问题：

1. 这是平台桥接，还是纯业务逻辑？
2. 这段重复是否真的影响了维护成本？
3. 如果现在删掉/收口，是否会立刻影响当前稳定交互？

如果答案分别是：

- 平台桥接
- 影响不大
- 可能打坏当前稳定行为

那这段代码就不该是当前轮次的优先目标。

如果答案是：

- 纯业务逻辑
- 重复明显
- 行为边界清楚

那就应该优先收掉。
