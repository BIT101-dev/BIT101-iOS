# UI 设计系统

跨功能复用的视觉令牌和控件归 `DesignSystemKit`；课程等多个页面与扩展共用的业务令牌由公共设计系统维护。话廊、地图等单一功能的专属令牌归所属功能模块，共享页面通过同一声明使用。社区呈现与编辑器组件归 `CommunityUI`，媒体编码、读取和预览算法归 `MediaKit`，图片草稿容量策略归社区领域模型。

## 原则

以更少的定义、更浅的依赖和更高的组件复用维护一致界面。优先系统字体、颜色、控件与自适应布局；接受适度视觉变化，保留可读性、触控便利性、动态字体和跨设备适配。

同类规则共享一个入口。派生用于表达必要的几何关系；组件直接使用已有令牌。模块专用参数归所属模块，公共参数归共享层。

`AppDesignSystem.Motion` 按选择变化和页面切换提供系统默认动画。页面读取 `accessibilityReduceMotion`，通过同一入口选择动画；系统导航和控件使用原生时序。触觉反馈归 `AppHapticFeedback`，选择或操作变化时通过 UIKit 系统生成器触发。加载、空态和失败展示归 `AppStateComponents`，尺寸与间距使用已有设计令牌。

客户端网络、存储、解析与并发规范见 [架构说明](ARCHITECTURE.md)。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| `Modules/DesignSystemKit/Sources/DesignPrimitives.swift` | Foundation 基础值：间距、圆角、透明度刻度；定义 `AppDesignSystem` 根命名空间 |
| `Modules/DesignSystemKit/Sources/AppDesignSystem.swift` | 主 App 尺寸、颜色、交互动画、UIKit 字体桥接与形状工厂 |
| `Modules/DesignSystemKit/Sources/AppLayoutComponents.swift` | 卡片、详情操作、浮动按钮与公共 List 样式 |
| `Modules/DesignSystemKit/Sources/AppStateComponents.swift` | 加载、空态、失败与滚动状态 |
| `Modules/DesignSystemKit/Sources/AppCommentComponents.swift` | 评论结构、头像正文排列与回复缩进 |
| `Modules/DesignSystemKit/Sources/AppContentControlComponents.swift` | 输入提示、分组标题、导航行、选择栏与搜索栏 |
| `Modules/DesignSystemKit/Sources/AppAvatarComponents.swift` | 纯头像容器、占位、裁切与无障碍 |
| `Modules/DesignSystemKit/Sources/AppCommentComposerComponents.swift` | 评论和建议编辑结构 |
| `Modules/DesignSystemKit/Sources/AppFeedComponents.swift` | 信息流行容器、分割线与课程评价行；课程令牌由 `AppDesignSystem.Course` 提供 |
| `Modules/DesignSystemKit/Sources/AppDiagnosticComponents.swift` | 共享提示模型、原始错误上下文、恢复动作与注入式提示修饰器；日程和地图复用同一模型 |
| `Modules/DesignSystemKit/Sources/AppFixedColumnComponents.swift` | 比例列数据行 |
| `Modules/DesignSystemKit/Sources/AppHapticFeedback.swift` | 系统选择与操作触感修饰器 |
| `Modules/DesignSystemKit/Sources/AppRefreshStatusComponents.swift` | 更新时间与刷新入口 |
| `Modules/DesignSystemKit/Sources/AppTagComponents.swift` | 标签展示与选择变体 |
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift` | 数据无关的图形与短信验证码输入面板 |
| `Modules/ScheduleFeature/Sources/ScheduleDesignSystem.swift` | 课表网格、周次栏、时间轴、课程块颜色与模块强调色 |
| `Modules/GalleryFeature/Sources/GalleryDesignSystem.swift` | 话廊消息标记与模块强调色 |
| `Modules/CommunityUI/Sources/CommunityDesignSystem.swift` | 社区卡片令牌与公共图片编辑条目 |
| `Modules/MapFeature/Sources/CampusMapScreen.swift` | 地图模块强调色令牌 |
| `Modules/DesignSystemKit/Sources/ExternalDesignSystem.swift` | 主 App、Widget、Watch、Live Activity 共用 SwiftUI 字体、尺寸与缩放 |

以上路径相对于仓库根目录。基础值和外部展示令牌同时加入 App、Widget、Watch App 与 Watch Widget target。课表快照文件负责数据契约。

## 基础刻度

- 间距：`none = 0`、`micro = 2`、`tiny = 4`、`regular = 8`、`content = 12`、`section = 16`。
- 圆角：`small = 8`、`card = 12`、`grouped = 16`。
- 透明度：`selection = 0.06` 用于选中行底色；`subtle`、`surface`、`softOverlay`、`overlay`、`controlOverlay`、`emphasis` 表达其他层级；`full` 表示不透明。
- 基础字号：`title / body / subheadline / footnote / caption` 五档，全部使用系统动态字体。
- 常规头像：40；资料头像：80。评论共享常规头像尺寸。
- 浮动按钮视觉尺寸与触控区域统一为 44；徽标偏移直接复用基础间距。
- 最小触控区域：`Size.Control.touchTarget`，44。

主 App 与外部展示共同引用基础间距、透明度刻度和五档 SwiftUI 字体。UIKit 富文本桥接位于主 App 扩展，强调和特殊几何从基础角色派生；等宽数字直接从基础字体角色调用 `monospacedDigit()`。

自定义颜色透明度统一从 `AppDesignSystem.Opacity` 派生。系统前景层级通过 `AppDesignSystem.Foreground` 暴露，页面使用设计系统标准入口，基础实现继续交给 SwiftUI 环境适配。

成绩和课程页面共用 `AppDesignSystem.Course.accent` 作为页面强调色。状态色、系统前景色和历史成绩图表的多序列颜色属于独立分类，保留对应令牌。

## 公共组件

- **容器**：`AppCard` 表达标准、紧凑、分组背景变体；`appGroupedListStyle()` 统一列表内容边距、section 间距和 52 点最小行高，动态字体按内容扩展。普通列表行与 DDL 卡片使用系统默认行边距；更新时间组件通过 `appListRowInsets()` 容纳 44 点点击区域、上下各 4 点边距及动态字体内容。
- **交互列表文字**：List、Form 和 Section 内的按钮、导航、Picker、Toggle、DatePicker、Link 与照片选择入口接入 `appInteractiveListRow()`，左侧标题使用系统主文字色，右侧值使用页面主题色；SF Symbol 使用对应的系统预设颜色。删除入口传入 `isDestructive: true` 使用警示色；浏览器导航行传入 `isSelected`，与信息流共用 `AppSelectionHighlight` 的浅色主题底，保持辅助信息可读。行内值和说明文字按各自分类着色。自定义标题组件同样遵循此约定。
- **操作**：`AppDetailShareLink` 使用系统自适应标签，在菜单中展示动作名称与图标，在工具栏中使用系统样式；`AppDetailCircleButton`、`AppFloatingActionButton` 与 `AppFloatingActionStack` 统一触控区域、材质和布局。
- **输入与标题**：`AppInputPrompt` 使用正文与系统 placeholder 颜色；`AppListSectionHeader` 与原生 `Section("标题")` 共同继承系统分组标题样式。列表分组通过正文承载实际内容，Section footer 解释文案由静态检查阻断。更新时间行的时间和加载提示使用副标题字号，刷新操作和只读标记使用正文字号。
- **内容控制**：顶部 segmented、排序搜索栏和设置导航行共享公共组件。
- **内容展示**：头像、标签、信息流分割线、比例数据行和刷新状态行各有公共实现。
- **评论**：`AppCommentThread` 组合身份、气泡、操作栏与回复；`AppComposerToolbar` 统一取消与提交。
- **验证码**：共用数字清洗、自动填充和输入样式，各认证流程传入掩码手机号与提交行为。系统建议或整段粘贴填入完整的 4 至 8 位验证码后自动验证，逐位输入保留手动提交；提交期间统一锁定输入、验证和取消操作。
- **状态**：`AppLoadingState`、`AppInlineLoadingState`、`AppEmptyState`、`AppFailureState` 提供加载、空态、失败与恢复操作；诊断操作通过环境注入。
- **触感**：`appSelectionFeedback` 与 `appImpactFeedback` 使用系统反馈能力。

错误分类由客户端基础设施提供，恢复操作通过 `diagnosticRecoveryActions()` 注入 `AppFailureState`，打开系统设置等恢复动作描述由 App 统一适配。业务页面负责内容、状态和操作绑定。

课程半星评分使用原生 `Stepper` 增减并归零；地图桥接层按系统减弱动态效果设置执行相机动作。长文本的完整阅读采用原生文本布局、动态字体与选择能力。

头像容器 `AppAvatarContainer` 接收已加载的 `Image`，远程图片展示和缓存由 `MediaKit` 适配。设计系统维护视图结构与视觉规则，业务依赖在 App 组装入口连接。

图形与短信验证共用 `AppVerificationSheet`。图形验证采用系统大面板容纳图片与提交操作，短信验证采用系统半屏面板。验证面板通过 `appDiagnosticModalActivity` 将呈现生命周期交给宿主；失败提示通过统一队列等待面板退场，再显示所属业务的恢复入口。日程与其他页面共用 `diagnosticAlert` 转发提示。

## 自适应

布局依据容器可用空间、safe area、系统动态字体和 SwiftUI 布局协商。社区缩略图使用容器与既有横向比例协商尺寸，本地缩略图、预览入口和移除按钮共用 `MediaKit.LocalImageTile`，社区上传状态由 `ComposerImageTile` 组合展示。固定值用于基础刻度、触控区域及具有明确用途的局部尺寸。iPhone、iPad、Mac 共用布局规则；Widget 与 Watch 使用外部展示令牌。

`appWindowLayout()` 提供窗口尺寸、容器宽度、宽度类别、辅助功能字号、安全区及系统分隔位置，随窗口与安全区变化更新并在键盘弹出时保持方向。搜索弹层在自身容器内提供布局环境；表单通过 `appReadableContent()` 控制阅读宽度，话题、文章、成绩、课程详情及宽幅设置二级页铺满可用区域，窄容器与大字号采用单列布局。

主导航由系统 `TabView` 承载：宽幅窗口展开八个业务入口，窄窗口归入五个主入口并保持页面身份稳定。iPad 与 Mac 通过 `appNativeBarBackground` 为主 Tab、导航栏和分区栏提供分组底色，iPhone 使用系统原生栏样式。分区栏位于导航栏下方，详情保留标准控件行高与顶部安全区自适应间距。

宽幅双栏窗口将日程呈现为课表与 DDL 并排；空教室、话题、文章、成绩、课程和个人页共用 `AppBrowserLayout` 切换单列与双栏 `NavigationStack`。横屏侧栏宽度按安全区高度的 9/16 或系统 `reservedRegions` 纵向分隔位置计算。筛选页与浏览页共用容器与列宽，节次筛选在右侧打开，横屏右栏通过 `appPaneBackButton` 提供左上返回按钮，窄窗口切换共用 `AppPairedPages` 保留页面状态。

成绩、课程与个人入口共用 `AppBrowserListRow`，一级分组通过 `appGroupedSectionStyle` 统一行背景，列表状态使用 `secondaryGrouped`。横屏 DDL 与空教室结果共用 `appGroupedListStyle(insetViewport:)` 保留分组圆角并对齐分栏；左栏按列宽保留标准行边距，右栏与整页列表通过滚动容器内缩排列，刷新信息位于分组列表内并随大字号扩展高度。

地图、话题、文章、课表和 DDL 共用 `appBrowserActions`：带水平系统安全区的紧凑竖屏窗口通过原生竖向工具栏排列侧方操作，空间紧凑时由系统更多菜单显示剩余操作；其余窗口使用公共悬浮按钮组，话题和文章的操作按钮竖向悬浮于所属列表右下角。单列子页保留窗口原有的工具栏策略；课表和浏览列表共用 `appBrowserNavigationBar` 安排原生导航栏与背景。

课表卡片优先保留完整楼宇和教室行数，课程名使用剩余文字区域；地点所需高度超出卡片时按可用区域缩放地点字体，课程详情和无障碍名称提供完整信息。周次刻度、日期入口和帖子菜单使用公共触控尺寸（周次选择 44 点、下方日期行 26 点）；课表页头与周次尺按当前窗口尺寸对齐当前周。日程主视图与横屏浏览分栏保持完整可用高度，编辑面板由所属弹窗处理键盘避让；横屏课表网格和悬浮操作延伸至容器底部安全边缘，竖屏课表与悬浮操作使用公共底部间距。

## 检查职责

| 入口 | 范围 |
| --- | --- |
| `Scripts/check-ui-consistency.py` | AST 作用域内的视觉令牌、主 App 布局、所有 Swift target 的字体使用、页面角色、公共组件、系统触感、错误报告入口和图片型操作控件的无障碍名称 |
| `Scripts/check-code-quality.py` | 客户端工程规范：网络、日志、日期解析、取消处理、存储、源码与工程维护 |

`Scripts/run-static-audit.sh` 汇总既有检查入口。每条规则及其派生检查由同一检查器维护，执行范围按当前改动选择。

UI 检查器基于 SwiftSyntax 作用域解析渲染表达式和 View 调用树。页面角色表登记视图职责；新增、改名或拆分相关页面时，同步角色登记和对应自测。固定几何、图表预设颜色及模块例外通过所属源码契约维护。

图片型 `Button`、`NavigationLink` 和 `Menu` 标签提供 `accessibilityLabel`。动态 SF Symbol 使用源码可枚举的有限字符串集合，菜单和操作按控件作用域判定。

主 Tab UI 用例在辅助功能大字号及浅色、深色外观下验证可见区域、触达性、名称和窗口边缘，失败时保存元素树与截图。设备截图覆盖 `.build/screenshot.png`；较长静态结果覆盖 `.build/ui-consistency-report.txt`。流程见 [构建与测试](TESTING.md)。
