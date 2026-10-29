# UI 设计系统

跨功能复用的视觉令牌和控件归 `DesignSystemKit`；课程等多个页面与扩展共用的业务令牌沿公共设计系统维护。话廊、地图等单一功能的专属令牌归所属功能模块，共享页面通过同一声明使用。社区呈现与编辑器组件归 `CommunityUI`，媒体编码、读取和预览算法归 `MediaKit`，图片草稿容量策略归社区领域模型。

## 原则

以更少的定义、更浅的依赖和更高的组件复用维护一致界面。优先系统字体、颜色、控件与自适应布局；接受适度视觉变化，保留可读性、触控便利性、动态字体和跨设备适配。

同类规则共享一个入口。派生用于表达必要的几何关系；组件直接使用已有令牌。模块专用参数归所属模块，公共参数归共享层。

`AppDesignSystem.Motion` 按选择变化和页面切换提供系统默认动画。页面消费 `accessibilityReduceMotion`，通过同一入口选择动画；系统导航和控件沿用原生时序。触觉反馈归 `AppHapticFeedback`，加载、空态和失败展示归 `AppStateComponents`，尺寸与间距消费已有语义令牌。

客户端网络、存储、解析与并发规范见 [架构说明](ARCHITECTURE.md)。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| `Modules/DesignSystemKit/Sources/DesignPrimitives.swift` | Foundation 基础值：间距、圆角、透明度刻度；定义 `AppDesignSystem` 根命名空间 |
| `Modules/DesignSystemKit/Sources/AppDesignSystem.swift` | 主 App 尺寸、颜色、语义动画、UIKit 字体桥接与形状工厂 |
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
| `Modules/DesignSystemKit/Sources/AppVerificationComponents.swift` | 数据无关的短信验证码输入面板 |
| `Modules/ScheduleFeature/Sources/ScheduleDesignSystem.swift` | 课表网格、周次栏、时间轴、课程块颜色与模块强调色 |
| `Modules/GalleryFeature/Sources/GalleryDesignSystem.swift` | 话廊消息标记与模块强调色 |
| `Modules/CommunityUI/Sources/CommunityDesignSystem.swift` | 社区卡片令牌与公共图片编辑条目 |
| `Modules/MapFeature/Sources/CampusMapScreen.swift` | 地图模块强调色令牌 |
| `Modules/DesignSystemKit/Sources/ExternalDesignSystem.swift` | 主 App、Widget、Watch、Live Activity 共用 SwiftUI 字体、尺寸与缩放 |

以上路径相对于仓库根目录。基础值和外部展示令牌同时加入 App、Widget、Watch App 与 Watch Widget target。课表快照文件负责数据契约。

## 基础刻度

- 间距：`none = 0`、`micro = 2`、`tiny = 4`、`regular = 8`、`content = 12`、`section = 16`。
- 圆角：`small = 8`、`card = 12`、`grouped = 16`。
- 透明度：`selection = 0.06` 用于选中行底色；`subtle`、`surface`、`softOverlay`、`overlay`、`controlOverlay`、`emphasis` 表达其他层级；`full` 表示完全不透明。
- 基础字号：`title / body / subheadline / footnote / caption` 五档，全部使用系统动态字体。
- 常规头像：40；资料头像：80。评论共享常规头像尺寸。
- 浮动按钮视觉尺寸与触控区域统一为 44；徽标偏移直接复用基础间距。
- 最小触控区域：`Size.Control.touchTarget`，44。

主 App 与外部展示共同引用基础间距、透明度刻度和五档 SwiftUI 字体。UIKit 富文本桥接位于主 App 扩展，强调和特殊几何从基础角色派生；等宽数字直接从基础字体角色调用 `monospacedDigit()`。

自定义颜色透明度统一从 `AppDesignSystem.Opacity` 派生。系统前景层级通过 `AppDesignSystem.Foreground` 暴露，页面使用设计系统语义入口，基础实现继续交给 SwiftUI 环境适配。

成绩和课程页面共用 `AppDesignSystem.Course.accent` 作为页面强调色。状态色、系统前景色和历史成绩图表的多序列颜色属于独立语义，保留对应令牌。

## 公共组件

- **容器**：`AppCard` 表达标准、紧凑、分组背景变体；`appGroupedListStyle()` 统一列表内容边距与 section 间距。普通列表行与 DDL 卡片沿用系统默认行边距；更新时间组件通过 `appListRowInsets()` 容纳 44 点点击区域、上下各 4 点边距及动态字体内容。原生 UI 公共断言核对访问到的更新时间行，专项验收覆盖四个数据页及辅助功能大字体。
- **交互列表文字**：List、Form 和 Section 内的按钮、导航、Picker、Toggle、DatePicker、Link 与照片选择入口接入 `appInteractiveListRow()`，左侧标题沿系统主文字色，右侧值使用页面主题色；SF Symbol 沿所属系统语义颜色。删除入口传入 `isDestructive: true` 使用警示色；浏览器导航行传入 `isSelected`，与信息流共用 `AppSelectionHighlight` 的浅色主题底，保持辅助信息可读。行内值和说明文字按各自语义着色。自定义标题组件同样遵循此约定。`check-ui-consistency.py` 基于 SwiftSyntax 检查控件自身样式和标题组件的前景色，并自测时间轴 Picker、删除入口、嵌套组件及字符串边界。
- **操作**：`AppDetailShareLink` 使用系统自适应标签，在菜单中展示动作名称与图标，在工具栏中沿系统样式展示；`AppDetailCircleButton`、`AppFloatingActionButton` 与 `AppFloatingActionStack` 统一触控区域、材质和布局。
- **输入与标题**：`AppInputPrompt` 使用正文与系统 placeholder 颜色；`AppListSectionHeader` 与原生 `Section("标题")` 共同继承系统分组标题样式。列表分组通过正文承载实际内容，Section footer 解释文案由静态检查阻断。更新时间行的时间和加载提示使用副标题字号，刷新操作和只读标记使用正文字号。
- **内容控制**：顶部 segmented、排序搜索栏和设置导航行共享公共组件。
- **内容展示**：头像、标签、信息流分割线、比例数据行和刷新状态行各有公共实现。
- **评论**：`AppCommentThread` 组合身份、气泡、操作栏与回复；`AppComposerToolbar` 统一取消与提交。
- **验证码**：共用数字清洗、自动填充和输入样式，各认证流程传入掩码手机号与提交行为。系统建议或整段粘贴填入完整的 4 至 8 位验证码后自动验证，逐位输入保留手动提交；提交期间统一锁定输入、验证和取消操作。
- **状态**：`AppLoadingState`、`AppInlineLoadingState`、`AppEmptyState`、`AppFailureState` 提供加载、空态、失败与恢复操作；诊断操作通过环境注入。
- **触感**：`appSelectionFeedback` 与 `appImpactFeedback` 使用系统反馈能力。

错误分类由客户端基础设施提供，恢复操作通过 `appDiagnosticRecoveryActions()` 注入 `AppFailureState`。业务页面负责内容、状态和操作绑定。

课程半星评分使用原生 `Stepper` 增减并归零；地图桥接层按系统减弱动态效果设置执行相机动作。长文本的完整阅读采用原生文本布局、动态字体与选择能力。

头像容器 `AppAvatarContainer` 接收已加载的 `Image`，远程图片展示和缓存由 `MediaKit` 适配。设计系统维护视图结构与视觉规则，业务依赖在 App 组装入口连接。

## 自适应

布局依据容器可用空间、safe area、系统动态字体和 SwiftUI 布局协商。社区缩略图使用容器与既有横向比例协商尺寸，本地缩略图、预览入口和移除按钮共用 `MediaKit.LocalImageTile`，社区上传状态由 `ComposerImageTile` 组合展示。打开系统设置由 App 适配恢复动作描述。固定值用于基础刻度、触控区域及具有明确用途的局部尺寸。iPhone、iPad、Mac 共用布局规则；Widget 与 Watch 使用外部展示令牌。

`appWindowLayout()` 提供所属窗口的尺寸、容器宽度、宽度类别、辅助功能字号、安全区及系统分隔位置。窗口布局和安全区变化共同更新布局测量；键盘出现时继续保持窗口方向，单列子页保留同一窗口信息。搜索弹层在自身容器重新提供布局环境。Duo 内屏与 iPad 的宽幅横屏使用 `AppSidebarLayout` 将筛选或搜索与主体并排呈现；日程并排呈现课表与单列 DDL；浏览分栏的左侧列表与右侧详情各自保持阅读位置。设置使用双列卡片。表单通过 `appReadableContent()` 控制阅读宽度，话题、文章、成绩和课程详情使用 `fillsAvailableWidth: true` 铺满所属可用区域；设置二级页面在宽幅分栏中同样铺满右侧区域，单列沿表单阅读宽度展示。窄容器与辅助功能字号采用单列内容，各页面沿同一状态和业务动作切换布局。

课表卡片优先为课程名保留文字区域，地点沿剩余完整行数截断，名称与地点使用所选动态字体。课程详情和无障碍名称承接完整信息。

成绩、课程与个人入口的浏览行共用 `AppBrowserListRow`，统一整行矩形点击区域、披露标记和浅色选中底。一级分组通过 `appGroupedSectionStyle` 统一行背景；刷新、交互行、空态、加载态与错误态的列表背景沿 `secondaryGrouped`，页级状态由宿主提供背景。iPad 与 Mac 通过 `appNativeBarBackground` 为原生主 Tab 和导航栏提供公共分组底色，分区栏沿同一底色布局；iPhone（含 Duo）沿系统原生栏样式。浏览分栏通过 `AnyLayout` 保持列表与详情的原生导航栈身份，横屏并排、竖屏全宽呈现；详情的页面状态随布局切换保留，宽幅标题使用 inline 模式。

周次刻度、日期入口和帖子菜单沿公共触控尺寸设置点击区域；刻度文字使用自然行高，课表页头随 caption 字体缩放。周次尺在尺寸变化时沿无动画事务对齐当前周。采用顶部原生主导航的日程页在横竖切换时保持导航栏可见，系统负责安排内容安全区。表单阅读宽度沿统一上限居中展示，浏览详情沿当前分栏或单列的可用宽度展示。

## 检查职责

| 入口 | 范围 |
| --- | --- |
| `Scripts/check-ui-consistency.py` | AST 作用域内的视觉令牌、主 App 布局、所有 Swift target 的字体使用、页面角色、公共组件、系统触感、错误报告入口和图片型操作控件的无障碍名称 |
| `Scripts/check-code-quality.py` | 客户端工程规范：网络、日志、日期解析、取消处理、存储、源码与工程维护 |

`Scripts/run-static-audit.sh` 汇总既有检查入口。每条规则由所属检查维护，派生放在规则拥有者内部；执行范围依据用户明确指示。

UI 检查器基于 SwiftSyntax 作用域解析渲染表达式和 View 调用树。页面角色表登记视图职责；新增、改名或拆分相关页面时，同步角色登记和对应自测。固定几何、图表语义颜色及模块例外通过所属源码契约维护。

图片型 `Button`、`NavigationLink` 和 `Menu` 标签提供 `accessibilityLabel`。动态 SF Symbol 使用源码可枚举的有限字符串集合，菜单和操作按控件作用域判定。

主 Tab UI 用例在辅助功能大字号及浅色、深色外观下验证可见区域、触达性、名称和窗口边界，失败时保存元素树与截图。设备截图覆盖 `.build/screenshot.png`；较长静态结果覆盖 `.build/ui-consistency-report.txt`。流程见 [构建与测试](TESTING.md)。

横屏浏览分栏保持完整可用高度，编辑面板沿所属呈现层处理键盘避让。横屏分栏内的列表沿各自列宽布局，分组圆角和操作入口保持完整可见。

横屏右侧详情通过 `appPaneBackButton` 提供公共返回入口，采用原生导航栏与系统按钮，iOS 27.1 起将该入口保留在所属栏的横向左上侧。课表 / DDL 与空教室分别持有所属导航容器，空教室左右栏各自承载原生导航栈。节次筛选在右侧打开，返回后显示当前筛选结果；竖屏沿现有整页导航展示。节次列表共用包含起止时间的 `ScheduleSectionSelectionPage`。

横屏 DDL 与空教室结果共用 `appGroupedListStyle(insetViewport:)`，将公共水平间距分配到滚动容器与内容两侧，保留系统分组圆角并让行边缘对齐所属分栏。带水平系统安全区的列表沿同一容器内缩方式排列，行内容保持在系统侧栏旁的可用区域内。

横屏日程将课表与单列 DDL 并排呈现。话题、文章、成绩、课程和个人页共用 `AppBrowserLayout`，由原生 `NavigationStack` 分别承载左侧列表与右侧详情，公共布局统一安排两列位置；话题和文章的操作按钮竖向悬浮于所属列表右下角，列表延伸至底部。iPad 横屏侧栏宽度统一为窗口安全区域高度的 9/16；系统提供纵向分隔区域时，分栏沿该区域排列，列宽扣除窗口左侧安全区。iOS 27.1 起通过 `reservedRegions` 读取包含平展姿态的系统分隔位置，课表 / DDL、浏览列表和空教室筛选共用该边界。`AppBrowserLayout` 与 `AppSidebarLayout` 共用列宽计算，切换页面保持列宽；竖屏浏览列表与详情使用完整可用宽度，横屏详情转回竖屏时回到列表。选中态沿内容下方的浅色主题底呈现。主导航由系统 `TabView` 承载，系统安排其水平或垂直位置；iOS 18 起，宽幅窗口展开日程 / DDL、空教室、地图、话题、文章、成绩、课程、我的八个入口，窄窗口沿当前子页归入五个主入口，页面身份保持稳定。分区栏放在原生导航栏下方，日程与成绩分区直接更新选择。水平系统安全区存在且顶部安全区为零时，内容顶部保留公共标准间距。主导航周围沿公共分组背景呈现，刷新信息位于各自模块的分组列表内，沿公共刷新行高度与分组底色布局。日程主视图保持完整可用高度，编辑表单沿所属弹窗处理键盘避让。横屏课表网格和悬浮操作延伸至所属容器的底部安全边界，系统手势安全区由系统维护；竖屏课表保留模块底部间距，悬浮操作沿公共 20 点底部间距排列。横竖屏共用所属业务主题色；页面同时提供当前主题的 tint 与 accentColor。
