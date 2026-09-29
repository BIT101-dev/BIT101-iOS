# UI 设计系统

## 原则

以更少的定义、更浅的依赖和更高的组件复用维护一致界面。优先系统字体、颜色、控件与自适应布局；接受适度视觉变化，保留可读性、触控便利性、动态字体和跨设备适配。

同类规则共享一个入口。派生用于表达必要的几何关系；组件直接使用已有令牌。模块专用参数归所属模块，公共参数归共享层。

客户端网络、存储、解析与并发规范见 [架构说明](ARCHITECTURE.md)。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| `Shared/DesignSystem/DesignPrimitives.swift` | Foundation 基础值：间距、圆角、透明度刻度；定义 `AppDesignSystem` 根命名空间 |
| `Shared/DesignSystem/AppDesignSystem.swift` | 主 App 尺寸、颜色、UIKit 字体桥接与形状工厂 |
| `Shared/DesignSystem/AppLayoutComponents.swift` | 卡片、详情操作、浮动按钮与公共 List 样式 |
| `Shared/DesignSystem/AppStateComponents.swift` | 加载、空态、失败与滚动状态 |
| `Shared/DesignSystem/AppCommentComponents.swift` | 评论结构、头像正文排列与回复缩进 |
| `Shared/DesignSystem/AppContentControlComponents.swift` | 输入提示、分组标题、导航行、选择栏与搜索栏 |
| `Shared/DesignSystem/AppAvatarComponents.swift` | 纯头像容器、占位、裁切与无障碍 |
| `Shared/DesignSystem/AppCommentComposerComponents.swift` | 评论和建议编辑结构 |
| `Shared/DesignSystem/AppFeedComponents.swift` | 信息流行容器与分割线 |
| `Shared/DesignSystem/AppFixedColumnComponents.swift` | 比例列数据行 |
| `Shared/DesignSystem/AppHapticFeedback.swift` | 系统选择与操作触感修饰器 |
| `Shared/DesignSystem/AppRefreshStatusComponents.swift` | 更新时间与刷新入口 |
| `Shared/DesignSystem/AppTagComponents.swift` | 标签展示与选择变体 |
| `Shared/DesignSystem/AppVerificationComponents.swift` | 数据无关的短信验证码输入面板 |
| `Schedule/ScheduleDesignSystem.swift` | 课表网格、周次栏、时间轴、课程块颜色与模块强调色 |
| `Course/CourseDesignSystem.swift` | 课程历史图表、指标样式与课程评价行 |
| `Gallery/GalleryDesignSystem.swift` | 话廊消息标记、覆盖层与模块强调色 |
| `Shared/CommunityUI/CommunityDesignSystem.swift` | 社区卡片、缩略图与身份标签派生参数 |
| `Map/CampusMapScreen.swift` | 地图模块强调色令牌 |
| `Shared/DesignSystem/ExternalDesignSystem.swift` | 主 App、Widget、Watch、Live Activity 共用 SwiftUI 字体、尺寸与缩放 |

以上路径相对于 `BIT101-iOS/`。基础值和外部展示令牌同时加入 App、Widget、Watch App 与 Watch Widget target。课表快照文件负责数据契约。

## 基础刻度

- 间距：`none = 0`、`micro = 2`、`tiny = 4`、`regular = 8`、`content = 12`、`section = 16`。
- 圆角：`small = 8`、`card = 12`、`grouped = 16`。
- 透明度：`subtle`、`surface`、`softOverlay`、`overlay`、`controlOverlay`、`emphasis` 六档；`full` 表示完全不透明。
- 基础字号：`title / body / subheadline / footnote / caption` 五档，全部使用系统动态字体。
- 常规头像：40；资料头像：80。评论共享常规头像尺寸。
- 浮动按钮视觉尺寸与触控区域统一为 44；徽标偏移直接复用基础间距。
- 最小触控区域：`Size.Control.touchTarget`，44。

主 App 与外部展示共同引用基础间距、透明度刻度和五档 SwiftUI 字体。UIKit 富文本桥接位于主 App 扩展，强调和特殊几何从基础角色派生；等宽数字直接从基础字体角色调用 `monospacedDigit()`。

自定义颜色透明度统一从 `AppDesignSystem.Opacity` 派生。系统前景层级通过 `AppDesignSystem.Foreground` 暴露，页面使用设计系统语义入口，基础实现继续交给 SwiftUI 环境适配。

成绩和课程页面共用 `AppDesignSystem.Course.accent` 作为页面强调色。状态色、系统前景色和历史成绩图表的多序列颜色属于独立语义，保留对应令牌。

## 公共组件

- **容器**：`AppCard` 表达标准、紧凑、分组背景变体；`appGroupedListStyle()` 统一列表边距与 section 间距。
- **操作**：`AppDetailShareLink`、`AppDetailCircleButton`、`AppFloatingActionButton` 与 `AppFloatingActionStack` 统一触控区域、材质和布局。
- **输入与标题**：`AppInputPrompt` 使用正文与系统 placeholder 颜色；`AppListSectionHeader` 使用强调脚注与次级颜色；原生 `Section("标题")` 使用系统样式。
- **内容控制**：顶部 segmented、排序搜索栏和设置导航行共享公共组件。
- **内容展示**：头像、标签、信息流分割线、比例数据行和刷新状态行各有公共实现。
- **评论**：`AppCommentThread` 组合身份、气泡、操作栏与回复；`AppComposerToolbar` 统一取消与提交。
- **验证码**：共用数字清洗、自动填充和输入样式，各认证流程传入掩码手机号与提交行为。
- **状态**：`AppLoadingState`、`AppInlineLoadingState`、`AppEmptyState`、`AppFailureState` 提供加载、空态、失败与恢复操作；诊断操作通过环境注入。
- **触感**：`appSelectionFeedback` 与 `appImpactFeedback` 使用系统反馈能力。

错误分类由客户端基础设施提供，恢复操作通过 `appDiagnosticRecoveryActions()` 注入 `AppFailureState`。业务页面负责内容、状态和操作绑定。

头像容器 `AppAvatarContainer` 接收已加载的 `Image`，远程图片缓存由 App 层的 `AppAvatarView` 适配。设计系统组件保持视图结构与视觉规则，业务和基础设施适配器位于 App 层。

## 自适应

布局依据容器可用空间、safe area、系统动态字体和 SwiftUI 布局协商。固定值用于基础刻度、触控区域及具有明确用途的局部尺寸。iPhone、iPad、Mac 共用布局规则；Widget 与 Watch 使用外部展示令牌。

## 检查职责

| 入口 | 范围 |
| --- | --- |
| `Scripts/check-ui-consistency.sh` | AST 作用域内的视觉令牌、主 App 布局、所有 Swift target 的字体使用、页面角色、公共组件、系统触感、错误报告入口和图片型操作控件的无障碍名称 |
| `Scripts/check-code-quality.sh` | 客户端工程规范：网络、日志、日期解析、取消处理、存储、源码与工程维护 |

`Scripts/run-static-audit.sh` 汇总既有检查入口。每条规则由所属检查维护；必要派生放在规则拥有者内部。测试、静态审计、构建和装机依据用户明确指示执行。

UI 检查器以 SwiftSyntax 调用、成员、绑定和表达式节点作为规则范围；注释与字符串内容不参与视觉规则匹配。公共契约沿渲染表达式、可达 View 辅助方法和 View 调用树递归解析；交互回调闭包从渲染契约搜索中排除，嵌套类型按词法作用域解析。`COMPONENT_CONTRACTS` 中的 View 名称表示页面角色登记项。新增、改名或拆分承载公共 UI 契约的页面时，将角色登记和对应自测纳入 PR 审查项。

图片型 `Button`、`NavigationLink` 和 `Menu` 标签需要提供 `accessibilityLabel`；检查器分别依据控件标签参数/闭包、控件修饰器和标签子树修饰器判定名称。菜单项与操作闭包按各自的控件作用域判定。列表图标的动态 SF Symbol 需由源码中的有限静态字符串集合证明安全；检查器以可静态枚举的符号值集合执行准入。固定几何与图表主题色通过登记的源码契约自动核验。

源码门禁与运行时 UI 自动化共同检查界面：主 Tab 用例在辅助功能大字号和浅色/深色外观下自动验证可见区域、可触达性、名称与窗口边界；失败时 XCTest 保存界面元素树和截图。`Scripts/capture-screenshot-device.sh` 将诊断画面固定写入 `.build/screenshot.png`。

## 当前系统结构

- 间距、圆角与五档基础字号使用上方列出的基础刻度。
- 常规头像尺寸为 40，资料头像尺寸为 80；评论头像复用常规尺寸。
- 课程、课表和话廊的页面专属参数位于各自模块设计文件。
- Widget、Watch 与 Live Activity 引用 `AppDesignSystem.Typography`、`AppDesignSystem.Foreground` 和公共间距，并维护各自的呈现缩放规则。
- 公共颜色和模块颜色从 `AppDesignSystem.Opacity` 派生，页面层保留语义令牌调用。
- UI 一致性检查会审计透明度、前景层级、字体入口、页面主题色和固定几何，并校验业务例外对应的自动契约。

自动契约覆盖课程评论图片的构图变体、话廊标签网格最小列宽、图片导出和时间轴的防零尺寸保护值，以及历史成绩图表的数据系列与语义颜色。检查器输出 `.build/ui-consistency-report.txt` 仅用于超过 1000 行的结果；一般结果直接显示在 terminal。
- 组件读取公共语义令牌；页面组合公共组件与模块组件。
- UI、组件、触感和客户端工程规范由各自检查入口负责，统一审计入口负责编排。
