# Swift 源码审查结论

更新时间：2026-09-22

## 审查范围

审查覆盖主 App、Widget、Watch App、Watch Widget 与测试 target 的 Swift 源码，逐文件阅读实现与注释，重点核对：

- 死代码、重复流程和与当前实现脱节的说明。
- SwiftUI/UIKit/WebKit/MapKit/WidgetKit/WatchConnectivity 的职责边界。
- 设计系统令牌、公共组件、动态字体与跨设备布局。
- 网络、认证、缓存、账号切换、任务取消和跨 target 数据传输。
- 无障碍语义、错误状态与现有测试覆盖。

## 结论

### UI 与平台实现

- 页面以 SwiftUI 原生视图组合为主。
- UIKit 桥接对应系统菜单定位、线性课表缩放、动态字体测量、系统分享、富文本编辑和键盘处理。
- MapKit 提供地图相机、定位和 overlay；Quick Look 提供图片预览；ImageIO 解码 GIF。
- 话廊原生入口与可选 WKWebView 入口分别保留明确页面职责。
- 主 App 公共令牌集中在 `Shared/DesignSystem/AppDesignSystem.swift`；基础刻度位于 `DesignPrimitives.swift`；模块特化参数位于 Course、Schedule、Gallery 目录。

### 客户端工程结构

- `Shared/Client` 集中 HTTP、社区 API、账号存储、取消识别、日期、诊断和错误呈现入口。
- 业务 Service 维护认证上下文与接口规则，ViewModel 管理页面状态，View 承载交互和呈现。
- 账号切换路径按账号代际隔离异步任务、缓存和弹窗。
- Widget、Watch 与 Live Activity 通过共享课表快照和稳定编解码协议读取数据。

### 主要回归覆盖

- 成绩刷新、空数据、缓存复用和验证码续接。
- 课表同步、学期偏移、课程编辑、日历导入和空教室筛选。
- CAS 登录页面解析、Challenge 状态和认证错误分类。
- 社区分页、评论、图像缓存、用户过滤和刷新取消。
- CloudKit 账号隔离、共享快照编解码、Widget/Watch 时间线与 Live Activity 状态。
- 错误报告脱敏、日期格式化、公共组件和代码质量契约。

## 维护入口

- 视觉、组件、触感与错误报告入口：`docs/DESIGN_SYSTEM.md`、`Scripts/check-ui-consistency.sh`。
- 客户端基础能力：`docs/ARCHITECTURE.md`、`docs/NETWORKING.md`、`docs/STATE_AND_STORAGE.md`。
- 全量 Swift 源码维护：`Scripts/check-code-quality.sh`。
- 自动化测试：`docs/TESTING.md` 与 `Scripts/run-extended-tests.sh`。
- 当前文件职责：`docs/FILE_INDEX.md`。

## 2026-09-24 字体令牌逐文件审查

### 审查记录

本轮逐一阅读主 App、Widget、Watch App、Watch Widget 与测试 target 的 195 份 Swift 文件，结合字体构造、`.font` 修饰符、字体权重、UIKit 字体入口和 WebKit fallback 内容复核。字体令牌来源集中在 `AppDesignSystem.Typography`；跨 target 的固定字号来源集中在 `AppDesignSystem.Primitives.FontSize`。

主 App 中的 SwiftUI 字体调用均指向 `AppDesignSystem.Typography`。课表卡片与文章富文本的 UIKit 字体入口均接收 `AppDesignSystem.Typography.ui*`。测试 target 未出现字体构造调用。

以下位置登记为待整改项。当前轮次保持代码原样。

#### Widget：`BIT101ScheduleWidgets/BIT101ScheduleWidgets.swift`

- L25：`.font(.caption)`，Live Activity 锁屏提醒类型。
- L31：`.font(.caption2)`，Live Activity 倒计时。
- L36：`.font(.headline)`，Live Activity 标题。
- L40：`.font(.subheadline)`，Live Activity 地点或教师。
- L58：`.font(.caption)`，Dynamic Island 展开态提醒类型。
- L73：`.font(.headline)`，Dynamic Island 展开态标题。
- L79：`.font(.headline)`，Dynamic Island 展开态摘要。
- L85：`.font(.caption)`，Dynamic Island 紧凑态提醒类型。
- L135：`.font(.title3.monospacedDigit())`，Live Activity 大号倒计时。
- L136：`.fontWeight(.semibold)`，Live Activity 大号倒计时权重。
- L141：`.font(.caption2)`，Live Activity 展开态倒计时。
- L148：`.font(.caption2)`，Live Activity 紧凑态倒计时。
- L296：`.font(.caption)`，Widget 顶部状态。
- L302：`.font(.caption2.weight(.medium))`，Widget 顶部相对日期。
- L315：`.font(.headline)`，小号 Widget 课程名。
- L320：`.font(.subheadline.weight(.medium))`，小号 Widget 时间范围。
- L326：`.font(.caption)`，小号 Widget 教室。
- L346：`.font(.caption2)`，锁屏长条顶部状态。
- L352：`.font(.caption2)`，锁屏长条顶部相对日期。
- L357：`.font(.subheadline.weight(.semibold))`，锁屏长条课程名。
- L361：`.font(.caption2)`，锁屏长条元数据。
- L367：`.font(.caption)`，锁屏长条空态。
- L392：`.font(.caption2)`，锁屏圆形图标。
- L394：`.font(.system(size: AppDesignSystem.Primitives.FontSize.compact, weight: .semibold, design: .rounded))`，锁屏圆形倒计时。
- L401：`.font(.caption2)`，锁屏圆形空态图标。
- L403：`.font(.system(size: AppDesignSystem.Primitives.FontSize.compact, weight: .medium, design: .rounded))`，锁屏圆形空态文字。
- L417：`.font(.headline)`，中号 Widget 主课程名。
- L422：`.font(.subheadline)`，中号 Widget 主课程元数据。
- L429：`.font(.caption)`，中号 Widget“后续”标题。
- L436：`.font(.subheadline.weight(.medium))`，中号 Widget 后续课程名。
- L443：`.font(.caption)`，中号 Widget 后续课程元数据。
- L452：`.font(.caption2)`，中号 Widget 后续课程时间。
- L473：`.font(.title3)`，大号 Widget 主课程名。
- L478：`.font(.headline.weight(.medium))`，大号 Widget 主课程时间。
- L484：`.font(.subheadline)`，大号 Widget 主课程元数据。
- L492：`.font(.caption)`，大号 Widget“后续”标题。
- L500：`.font(.subheadline.weight(.medium))`，大号 Widget 后续课程名。
- L507：`.font(.caption)`，大号 Widget 后续课程元数据。
- L516：`.font(.caption.weight(.medium))`，大号 Widget 后续课程时间。
- L563：`.font(.subheadline.weight(.medium))`，Widget 空态主文案。
- L566：`.font(.caption)`，同步提示补充文案。
- L571：`.font(.caption)`，重新同步提示补充文案。
- L576：`.font(.caption)`，登录提示补充文案。

#### Watch App：`BIT101Watch/WatchScheduleRootView.swift`

- L49：`.font(.caption)`，当前状态。
- L55：`.font(.caption)`，相对日期。
- L60：`.font(.title2)`，当前课程名。
- L64：`.font(.title2)`，当前时间范围。
- L68：`.font(.title2)`，当前教室。
- L79：`.font(.caption.weight(.semibold))`，后续课程标题。
- L92：`.font(.caption2.weight(.medium))`，后续课程日期。
- L98：`.font(.caption2.weight(.medium))`，后续课程时间。
- L103：`.font(.subheadline.weight(.medium))`，后续课程名。
- L108：`.font(.subheadline.weight(.medium))`，后续课程教室。
- L148：`.font(.headline)`，操作页标题。
- L158：`.font(.caption)`，操作反馈。
- L181：`.font(.headline)`，手表空态主文案。
- L192：`.font(.caption)`，手表空态反馈。

#### Watch Widget：`BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`

- L220：`.font(.system(size: AppDesignSystem.Primitives.FontSize.emphasis, weight: .semibold, design: .rounded))`，圆形表盘楼宇。
- L225：`.font(.system(size: AppDesignSystem.Primitives.FontSize.prominent, weight: .bold, design: .rounded))`，圆形表盘房间。
- L232：`.font(.system(size: AppDesignSystem.Primitives.FontSize.emphasis, weight: .semibold, design: .rounded))`，圆形表盘空态。
- L244：`.font(.system(size: AppDesignSystem.Primitives.FontSize.emphasis, weight: .semibold, design: .rounded))`，角标表盘地点。
- L253：`.font(.system(size: AppDesignSystem.Primitives.FontSize.emphasis, weight: .semibold, design: .rounded))`，角标表盘空态。
- L280：`.font(.caption)`，矩形表盘状态。
- L286：`.font(.caption)`，矩形表盘日期。
- L291：`.font(.headline.weight(.semibold))`，矩形表盘课程名。
- L297：`.font(.headline.weight(.semibold))`，矩形表盘时间。
- L304：`.font(.headline.weight(.semibold))`，矩形表盘地点。
- L312：`.font(.headline)`，矩形表盘空态。
- L316：`.font(.caption)`，矩形表盘同步提示。

#### 其他字体入口

- `BIT101-iOS/Settings/SettingsScheduleSheets.swift:30`：`.fontWeight(.semibold)` 直接写在系统符号上，权重缺少设计系统语义入口。
- `BIT101-iOS/Shared/Client/AppErrorPresentation.swift:388`：`.bold()` 直接写在提示文案组合上，当前基础字号来自 `Typography.footnote`，强调权重绕过 `Typography.footnoteEmphasis`。
- `BIT101-iOS/Shared/Client/AppErrorPresentation.swift:397`：`.bold()` 直接写在提示文案组合上，强调权重绕过设计系统语义入口。
- `BIT101-iOS/Shared/Client/AppErrorPresentation.swift:400`：`.bold()` 直接写在提示文案组合上，强调权重绕过设计系统语义入口。
- `BIT101-iOS/Gallery/GalleryRootView.swift:177`：WKWebView 失败 fallback HTML 直接写入 CSS `font: -apple-system-body`，WebKit fallback 缺少设计系统字体语义入口。

### 结构结论

- `Shared/DesignSystem/ExternalDesignSystem.swift` 当前提供外部 target 的尺寸与缩放令牌，Typography 命名空间尚未建立；Widget、Watch App、Watch Widget 的上述调用因此分散在页面代码中。
- `AppDesignSystem.Primitives.FontSize` 已被外部 target 使用，当前调用仍在页面内直接组合字重与字体设计；后续可收敛为 External Typography 语义令牌。
- `SettingsScheduleSheets` 与 `AppErrorPresentation` 的权重入口属于主 App 字体审查范围，适合与现有 `Typography.*Emphasis` 统一。
- WebKit 话廊主体属于外部网页渲染，失败 fallback 仍由客户端维护，适合补充 WebKit fallback 的字体语义令牌。
