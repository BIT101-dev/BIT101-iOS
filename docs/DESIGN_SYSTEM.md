# UI 设计系统

## 目标

让同类页面共享同一套视觉基础，避免复制页面后产生细小但持续累积的差异。

## 唯一来源

`BIT101-iOS/Shared/DesignSystem/AppDesignSystem.swift` 是主 App 的基础样式入口：

- `AppDesignSystem.Spacing`：常用语义间距。
- `AppDesignSystem.Feed`、`AppDesignSystem.Comment`、`AppDesignSystem.Detail`：信息流、评论区和详情页的共用间距。
- `AppDesignSystem.Radius`：常用圆角。
- `AppDesignSystem.Palette`：`accent`、`highlight`、`danger`、`info` 以及系统背景色和填充色。
- `AppDesignSystem.roundedRectangle(_:)`：统一圆角形状。
- `AppCard`：统一卡片容器。
- `AppCardVariant`：`standard`、`compact`、`secondaryGrouped` 三种明确变体。
- `AppDetailShareLink`、`AppDetailCircleButton`：课程、帖子和文章详情页共用的分享、评论和点赞按钮。
- `AppFloatingActionButton`、`AppFloatingActionButtonSurface`、`AppFloatingActionStack`：统一右下角圆形按钮的尺寸、材质、徽标和组间距。
- `appGroupedListStyle()`：所有分组列表唯一允许使用的公共入口，统一 inset grouped 样式、`AppDesignSystem.Spacing.content` Section 间距、8pt 横向内容边距和首屏顶部边距。
- `appCommentSectionStyle()`：统一课程、帖子和文章的评论区容器样式。
- `AppComposerContentSection`、`AppCommentComposerContentSection`、`AppComposerToolbar`：统一课程、话廊、文章评论和开发者建议的输入区共性及工具栏。
- `AppSegmentedPicker`、`AppTopSegmentedPicker`：统一 segmented 选择控件的样式和选择触感；顶部版本统一安全区下沿、内容边缘与背景，`stacked` 变体用于连续双层顶部栏。
- `AppDesignSystem.Schedule`：统一课表网格线、课程块与网格线的对称内缩、课程块边框、课程文字安全内边距、标题/地点字号、两格课程的标题行数限制和地点紧凑行高；地点行高使用可调的字体比例令牌；按周与全学期叠加共用同一套几何与文字布局。课程块默认显示名称+地点，并通过“名/地”按钮轮换为仅名称或仅两行地点。
- `AppOrderedSearchBar`、`AppSearchBarContainer`：统一话廊和文章搜索的排序菜单、输入框、清空按钮、圆角背景和顶部材质。
- `AppFeedRow`：统一话廊、文章和我的帖子流的零间距行、分割线和分割线起始位置。
- `AppAvatarView`：统一话题、文章、我的、设置、消息和评论头像的加载、占位、裁切和尺寸；不同语义只传入尺寸与色彩参数。
- `AppTagChip`、`AppTagChipVariant`：统一信息流、详情页和编辑页标签胶囊的间距、字体、前景色和背景色。
- `AppCommentAvatarView`、`AppCommentIdentityHeader`、`AppCommentActionBar`、`AppCommentBubble`、`AppCommentRowContainer`：统一课程、话廊和文章评论的头像、标题、操作、气泡和行布局；业务差异只保留在内容闭包。
- `AppCommentThread`：统一三类评论的主评论、回复缩进和分隔线结构；单条气泡内容由业务闭包提供。
- `AppSMSVerificationSheet`：统一课表、成绩和可信成绩单的验证码输入、错误态、焦点与提交状态；业务只传入挑战和提交文案。
- `AppDateText`：统一社区时间字段的多格式解析和相对时间文案，课程、话廊与消息不得各自维护 formatter。
- `AppFileDirectories`：统一 App 持久化目录的系统入口，仓库只负责追加语义子目录。
- `AppEmptyState`、`AppFailureState`：统一无数据和加载失败页面的系统图标、说明、重试和诊断入口。
- `AppLoadingState`、`AppInlineLoadingState`、`AppScrollStateContainer`：统一首屏、列表内和滚动页状态的布局，不允许页面重复包进度条或使用机型相关的上下留白。
- `AppFixedColumnItem`、`AppFixedColumnRow`：课程与成绩列表共用的比例列数据行；列内容由业务传入，几何和截断规则只保留一份。
- `AppRefreshStatusRow`：统一成绩、课表、DDL 等数据页面的最近更新时间、同步状态和手动刷新入口；所有更新时间直接放进页面主 List 的 Section。

`AppHapticFeedback.swift` 提供 `appSelectionFeedback(trigger:)` 和 `appImpactFeedback(trigger:)`，分别用于离散切换和操作按钮；实际是否输出由系统决定。右下角公共按钮、地图校区按钮、课表菜单按钮和空白处长按菜单均接入触感。所有 `Picker`、`Toggle`、自绘勾选行和全选/全不选入口也必须接入选择触感。`Scripts/check-haptic-consistency.sh` 会扫描这些控件，提醒遗漏，并拒绝绕过公共接口的触感实现。

课程、话廊和文章评论页面使用公共评论输入组件；开发者建议复用公共内容段和编辑工具栏；评分、图片和文本编辑器等业务差异通过页面内容区保留。
`Scripts/check-component-consistency.sh` 会检查这些页面是否复用公共组件，避免匿名开关、提交栏、搜索栏、segmented 控件和评论结构再次分叉实现。

页面不应重新声明同一类颜色、圆角或卡片结构。确有不同语义时，先增加命名清晰的令牌或变体，再在页面使用。
所有分组 `List` 的筛选区、结果区、Section 间距和横向宽度统一交给唯一的 `appGroupedListStyle()`；顶部标准 picker 到第一个 Section 的间距复用同一个 `AppDesignSystem.Spacing.content` 令牌；自绘列表的间距使用 `AppDesignSystem.Spacing`。

## 复用规则

1. 相同结构只保留一个公共组件。
2. 内容差异通过参数或显式变体表达。
3. 不通过复制组件后微调 padding、corner radius 或背景色制造“新样式”。
4. 能用 SwiftUI 系统默认值时，不额外设置同等效果的自定义值。
5. 跨页面的视觉改动只修改设计系统或公共组件。

## 跨设备自适应约束

本项目必须同时适配 iPhone、iPad 和 Mac。禁止根据单台真机截图或单一屏幕尺寸
反复试出页面位置、宽高或底部避让值。页面布局优先依赖 SwiftUI 的自适应布局、
系统 safe area、容器提出的可用尺寸、`frame(maxWidth:)` / `frame(maxHeight:)`
和设计令牌；绝对坐标、设备相关的固定宽高和为某个机型临时增加的补偿值均不得进入
正式代码。固定值只有在表达稳定的语义间距、最小可点击尺寸或设计系统令牌时才允许。

涉及顶部栏、底部 Tab 栏、键盘、分屏、窗口缩放或横竖屏时，必须约束内容边界而不是
覆盖系统 UI；不要把某次截图的像素差异当成布局依据。真机验证应覆盖至少一种 iPhone
尺寸，并在代码审查中确认 iPad / Mac 的宽度、窗口和 safe area 不依赖该机型。

## 自动检查

UI 改动后按需运行：

```sh
Scripts/check-ui-consistency.sh
```

完整源码风格审查使用 `Scripts/check-code-quality.sh`。它会扫描 App、Widget、Watch
和测试 target 的全部 Swift 文件，阻止死代码标记、绕过网络/触感公共入口、已移除文案、
脚本权限、动态临时产物路径和失效的本地文档链接；固定布局值、强制解包和大型文件只写入审查报告，不自动改动。

该检查会扫描主 App 的 SwiftUI 源码，确保：

- 圆角必须通过 `AppDesignSystem.roundedRectangle` 创建。
- 系统背景色必须通过 `AppDesignSystem.Palette` 获取。
- 右下角圆形操作按钮必须通过公共按钮组件，不能重新设置尺寸或材质。
- 所有分组列表必须使用唯一的 `appGroupedListStyle()`，不要按页面拆分列表样式或单独设置横向/section 间距；消息中心的 plain 列表是唯一例外。
- 新增的固定 UI 间距必须使用设计令牌；检查只针对工作区新增行，不强迫一次性重写历史代码。
- 详情页必须共用分享与圆形操作按钮，评论区必须共用间距和容器样式，信息流卡片必须共用 Feed 间距。
- 学业页的顶部切换栏由外层 `safeAreaInset` 承载，日程根页同时为底部系统 Tab 栏保留同一固定安全区间隙；所有分组列表统一使用唯一的 `appGroupedListStyle()`，共用可调横向边距且不重复叠加滚动上边距。课表表格上下的内容间隙统一使用 `AppDesignSystem.TopBar.contentGap`，主体圆角改为与 List 分组内容一致的 `AppDesignSystem.Radius.grouped`，普通分组内容保持原有圆角。
- 课表周次滑块和日期栏必须使用可区分的语义背景色；周次与全学期叠加共用等宽列、课程层级和网格线遮罩规则。
- 主 App 不直接调用 `print`、`debugPrint` 或 `NSLog`；诊断输出只由网络 smoke 实现负责。
- 业务页面不直接调用 `URLSession.shared`；网络请求统一经 `HTTPClient` 或场景化 Service，避免会话与错误处理分叉。
- 公共卡片容器仍保留并有实际调用。

它不替代编译和真机检查，也不默认运行。发布前或进行大范围 UI 调整时显式执行即可。
