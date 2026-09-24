# UI 设计系统

## 原则

以更少的定义、更浅的依赖和更高的组件复用维护一致界面。优先系统字体、颜色、控件与自适应布局；接受适度视觉变化，保留可读性、触控便利性、动态字体和跨设备适配。

同类规则共享一个入口。派生用于表达必要的几何关系；组件直接使用已有令牌。模块专用参数归所属模块，公共参数归共享层。

客户端网络、存储、解析与并发规范见 [架构说明](ARCHITECTURE.md)。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| `Shared/DesignSystem/DesignPrimitives.swift` | Foundation 基础值：间距、圆角；定义 `AppDesignSystem` 根命名空间 |
| `Shared/DesignSystem/AppDesignSystem.swift` | 主 App 公共尺寸、系统语义字体与颜色 |
| `Shared/DesignSystem/AppLayoutComponents.swift` | 卡片、详情操作、浮动按钮与公共 List 样式 |
| `Shared/DesignSystem/AppStateComponents.swift` | 加载、空态、失败与滚动状态 |
| `Shared/DesignSystem/AppCommentComponents.swift` | 评论结构、头像正文排列与回复缩进 |
| `Shared/DesignSystem/AppContentControlComponents.swift` | 输入提示、分组标题、导航行、选择栏与搜索栏 |
| `Schedule/ScheduleDesignSystem.swift` | 课表网格、周次栏、时间轴与课程块颜色 |
| `Course/CourseDesignSystem.swift` | 课程历史图表尺寸 |
| `Gallery/GalleryDesignSystem.swift` | 话廊缩略图、消息标记与覆盖层 |
| `Shared/DesignSystem/ExternalDesignSystem.swift` | Widget、Watch、Live Activity 共用字体、尺寸与缩放 |

以上路径相对于 `BIT101-iOS/`。基础值和外部展示令牌同时加入 App、Widget、Watch App 与 Watch Widget target。课表快照文件负责数据契约。

## 基础刻度

- 间距：`none = 0`、`micro = 2`、`tiny = 4`、`regular = 8`、`content = 12`、`section = 16`。
- 圆角：`small = 8`、`card = 12`、`grouped = 16`。
- 基础字号：`title / body / subheadline / footnote / caption` 五档，全部使用系统动态字体。
- 常规头像：40；资料头像：80。评论共享常规头像尺寸。
- 浮动按钮视觉尺寸与触控区域统一为 44；徽标偏移直接复用基础间距。
- 最小触控区域：`Size.Control.touchTarget`，44。

主 App 与外部展示共同引用基础间距和五档字体。强调、等宽数字和平台桥接均从基础字号派生，特殊几何以用途命名。

## 公共组件

- **容器**：`AppCard` 表达标准、紧凑、分组背景变体；`appGroupedListStyle()` 统一列表边距与 section 间距。
- **操作**：`AppDetailShareLink`、`AppDetailCircleButton`、`AppFloatingActionButton` 与 `AppFloatingActionStack` 统一触控区域、材质和布局。
- **输入与标题**：`AppInputPrompt` 使用正文与系统 placeholder 颜色；`AppListSectionHeader` 使用强调脚注与次级颜色；原生 `Section("标题")` 使用系统样式。
- **内容控制**：顶部 segmented、排序搜索栏和设置导航行共享公共组件。
- **内容展示**：头像、标签、信息流分割线、比例数据行和刷新状态行各有公共实现。
- **评论**：`AppCommentThread` 组合身份、气泡、操作栏与回复；`AppComposerToolbar` 统一取消与提交。
- **验证码**：共用数字清洗、自动填充和输入样式，各认证流程传入提交行为。
- **状态**：`AppLoadingState`、`AppInlineLoadingState`、`AppEmptyState`、`AppFailureState` 提供加载、空态、失败与恢复操作。
- **触感**：`appSelectionFeedback` 与 `appImpactFeedback` 使用系统反馈能力。

错误分类由客户端基础设施提供，提示组件依据分类展示操作。业务页面负责内容、状态和操作绑定。

## 自适应

布局依据容器可用空间、safe area、系统动态字体和 SwiftUI 布局协商。固定值用于基础刻度、触控区域及具有明确用途的局部尺寸。iPhone、iPad、Mac 共用布局规则；Widget 与 Watch 使用外部展示令牌。

## 检查职责

| 入口 | 范围 |
| --- | --- |
| `Scripts/check-ui-consistency.sh` | 视觉令牌、主 App 布局、所有 Swift target 的字体使用、页面角色、公共组件、系统触感和错误报告入口 |
| `Scripts/check-code-quality.sh` | 客户端工程规范：网络、日志、日期解析、取消处理、存储、源码与工程维护 |

`Scripts/run-static-audit.sh` 汇总既有检查入口。每条规则由所属检查维护；必要派生放在规则拥有者内部。测试、静态审计、构建和装机依据用户明确指示执行。

## 当前系统结构

- 间距、圆角与五档基础字号使用上方列出的基础刻度。
- 常规头像尺寸为 40，资料头像尺寸为 80；评论头像复用常规尺寸。
- 课程、课表和话廊的页面专属参数位于各自模块设计文件。
- Widget、Watch 与 Live Activity 引用 `External.Typography` 和公共间距，并维护各自的呈现缩放规则。
- 组件读取公共语义令牌；页面组合公共组件与模块组件。
- UI、组件、触感和客户端工程规范由各自检查入口负责，统一审计入口负责编排。
