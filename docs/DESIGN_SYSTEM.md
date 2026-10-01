# UI 设计系统

## 原则

以更少的定义、更浅的依赖和更高的组件复用维护一致界面。优先系统字体、颜色、控件与自适应布局；接受适度视觉变化，保留可读性、触控便利性、动态字体和跨设备适配。

同类规则共享一个入口。派生用于表达必要的几何关系；组件直接使用已有令牌。模块专用参数归所属模块，公共参数归共享层。

客户端网络、存储、解析与并发规范见 [架构说明](ARCHITECTURE.md)。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| `Modules/DesignSystemKit/Sources/DesignPrimitives.swift` | Foundation 基础值：间距、圆角、透明度刻度；定义 `AppDesignSystem` 根命名空间 |
| `Modules/DesignSystemKit/Sources/AppDesignSystem.swift` | 主 App 尺寸、颜色、UIKit 字体桥接与形状工厂 |
| `Modules/DesignSystemKit/Sources/AppLayoutComponents.swift` | 卡片、详情操作、浮动按钮与公共 List 样式 |
| `Modules/DesignSystemKit/Sources/AppStateComponents.swift` | 加载、空态、失败与滚动状态 |
| `Modules/DesignSystemKit/Sources/AppCommentComponents.swift` | 评论结构、头像正文排列与回复缩进 |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift` | 输入提示、分组标题、导航行、选择栏与搜索栏 |
| `Modules/DesignSystemKit/Sources/AppAvatarComponents.swift` | 纯头像容器、占位、裁切与无障碍 |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift` | 评论和建议编辑结构 |
| `Modules/DesignSystemKit/Sources/AppFeedComponents.swift` | 信息流行容器、分割线与课程评价行；课程令牌由 `AppDesignSystem.Course` 提供 |
| `Modules/DesignSystemKit/Sources/AppDiagnosticComponents.swift` | 提示模型、恢复动作描述、诊断协议和注入式提示修饰器 |
| `Modules/DesignSystemKit/Sources/AppFixedColumnComponents.swift` | 比例列数据行 |
| `Modules/DesignSystemKit/Sources/AppHapticFeedback.swift` | 系统选择与操作触感修饰器 |
| `Modules/DesignSystemKit/Sources/AppRefreshStatusComponents.swift` | 更新时间与刷新入口 |
| `Modules/DesignSystemKit/Sources/AppTagComponents.swift` | 标签展示与选择变体 |
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift` | 数据无关的短信验证码输入面板 |
| `Modules/ScheduleFeature/Sources/ScheduleDesignSystem.swift` | 课表网格、周次栏、时间轴、课程块颜色与模块强调色 |
| `Modules/GalleryFeature/Sources/GalleryDesignSystem.swift` | 话廊消息标记与模块强调色 |
| `Modules/CommunityUI/Sources/CommunityDesignSystem.swift` | 社区卡片令牌、公共图片编辑条目与共享草稿能力 |
| `Modules/MapFeature/Sources/CampusMapScreen.swift` | 地图模块强调色令牌 |
| `Modules/DesignSystemKit/Sources/ExternalDesignSystem.swift` | 主 App、Widget、Watch、Live Activity 共用 SwiftUI 字体、尺寸与缩放 |

以上路径相对于仓库根目录。基础值和外部展示令牌同时加入 App、Widget、Watch App 与 Watch Widget target。课表快照文件负责数据契约。

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

头像容器 `AppAvatarContainer` 接收已加载的 `Image`，远程图片展示和缓存由 `MediaKit` 适配。设计系统维护视图结构与视觉规则，业务依赖在 App 组装入口连接。

## 自适应

布局依据容器可用空间、safe area、系统动态字体和 SwiftUI 布局协商。社区缩略图使用容器与既有横向比例协商尺寸，图片编辑条目共用 `ComposerImageTile`。打开系统设置由 App 适配恢复动作描述。固定值用于基础刻度、触控区域及具有明确用途的局部尺寸。iPhone、iPad、Mac 共用布局规则；Widget 与 Watch 使用外部展示令牌。

## 检查职责

| 入口 | 范围 |
| --- | --- |
| `Scripts/check-ui-consistency.sh` | AST 作用域内的视觉令牌、主 App 布局、所有 Swift target 的字体使用、页面角色、公共组件、系统触感、错误报告入口和图片型操作控件的无障碍名称 |
| `Scripts/check-code-quality.sh` | 客户端工程规范：网络、日志、日期解析、取消处理、存储、源码与工程维护 |

`Scripts/run-static-audit.sh` 汇总既有检查入口。每条规则由所属检查维护，派生放在规则拥有者内部；执行范围依据用户明确指示。

UI 检查器基于 SwiftSyntax 作用域解析渲染表达式和 View 调用树。`COMPONENT_CONTRACTS` 登记页面角色；新增、改名或拆分相关页面时，同步角色登记和对应自测。固定几何、图表语义颜色及模块例外通过所属源码契约维护。

图片型 `Button`、`NavigationLink` 和 `Menu` 标签提供 `accessibilityLabel`。动态 SF Symbol 使用源码可枚举的有限字符串集合，菜单和操作按控件作用域判定。

主 Tab UI 用例在辅助功能大字号及浅色、深色外观下验证可见区域、触达性、名称和窗口边界，失败时保存元素树与截图。设备截图覆盖 `.build/screenshot.png`；较长静态结果覆盖 `.build/ui-consistency-report.txt`。流程见 [构建与测试](TESTING.md)。
