# UI 设计系统

## 目标

让同类页面共享同一套视觉基础，复制页面时保持视觉规则一致。

## 唯一来源

`BIT101-iOS/Shared/DesignSystem/AppDesignSystem.swift` 是主 App 的基础样式入口：

- `AppDesignSystem.Spacing`：常用语义间距。
- `AppDesignSystem.Comment.layout`：评论头像、回复缩进与分割线布局；信息流和详情页通过公共组件复用 `Spacing` 与 `Size`，令牌由设计系统集中维护。
- `AppDesignSystem.Radius`：常用圆角。
- `AppDesignSystem.Palette`：`accent`、`highlight`、`highlightForeground`、`danger`、`info`、`subtleBorder` 以及系统背景色和填充色。
- `AppDesignSystem.roundedRectangle(_:)`：统一圆角形状。
- `AppCard`：统一卡片容器。
- `AppCardVariant`：`standard`、`compact`、`secondaryGrouped` 三种明确变体。
- `AppDetailShareLink`、`AppDetailCircleButton`：课程、帖子和文章详情页共用的分享、评论和点赞按钮。
- `AppFloatingActionButton`、`AppFloatingActionButtonSurface`、`AppFloatingActionStack`：统一右下角圆形按钮的尺寸、材质、徽标和组间距。
- `appGroupedListStyle()`：所有分组列表共用的唯一公共入口，统一 inset grouped 样式、`AppDesignSystem.Spacing.content` Section 间距、8pt 横向内容边距和首屏顶部边距。
- `appCommentSectionStyle()`：统一课程、帖子和文章的评论区容器样式。
- `AppCommentComposerContentSection`、`AppComposerToolbar`：统一课程、话廊和文章评论的输入区共性及工具栏；开发者建议复用 `AppComposerToolbar` 与图片草稿组件，正文输入保留建议场景的专用结构。
- `AppSegmentedPicker`、`AppTopSegmentedPicker`：统一 segmented 选择控件的样式和选择触感；顶部版本统一安全区下沿、内容边缘与背景，`stacked` 变体用于连续双层顶部栏。
- `AppDesignSystem.Schedule`：统一课表网格线、课程块与网格线的对称内缩、课程块边框、课程文字安全内边距、标题/地点字号、两格课程的标题行数限制和地点紧凑行高；地点行高使用可调的字体比例令牌；按周与全学期叠加共用同一套几何与文字布局。课程块默认显示名称+地点，并通过“名/地”按钮轮换为仅名称或仅两行地点。
- `AppDesignSystem.Size.avatar`：统一文章详情、账号设置、用户列表和个人资料头像尺寸，以及头像占位透明度和大图标阈值。
- `AppDesignSystem.Size.sheet`：统一 DDL 数值选择 sheet 高度。
- `AppOrderedSearchBar`、`AppSearchBarContainer`：统一话廊和文章搜索的排序菜单、输入框、清空按钮、圆角背景和顶部材质。
- `AppFeedRow`：统一话廊、文章和我的帖子流的零间距行、分割线和分割线起始位置。
- `AppAvatarView`：统一话题、文章、我的、设置、消息和评论头像的加载、占位、裁切和尺寸；组件接收尺寸与色彩参数表达语义差异。
- `AppTagChip`、`AppTagChipVariant`：统一信息流、详情页和编辑页标签胶囊的间距、字体、前景色和背景色。
- `AppCommentIdentityHeader`、`AppCommentActionBar`、`AppCommentBubble`、`AppCommentRowContainer`：统一课程、话廊和文章评论的标题、操作、气泡和行布局；业务差异只保留在内容闭包。
- `AppCommentThread`：统一三类评论的主评论、回复缩进和分隔线结构；单条气泡内容由业务闭包提供。
- `AppSMSVerificationSheet`：统一课表、成绩和可信成绩单的验证码输入、错误态、焦点与提交状态；业务只传入挑战和提交文案。
- `AppDateText`：统一社区时间字段的多格式解析和相对时间文案，课程、话廊与消息共用该组件维护的 formatter。
- `AppFileDirectories`：统一 App 持久化目录的系统入口，目录逻辑由系统入口提供，仓库追加语义子目录。
- `AppEmptyState`、`AppFailureState`：统一无数据和加载失败页面的系统图标、说明、重试和诊断入口。
- `AppLoadingState`、`AppInlineLoadingState`、`AppScrollStateContainer`：统一首屏、列表内和滚动页状态的布局；页面通过这些组件承载状态，进度条保持单层包裹，页面上下留白遵循与机型无关的统一规则。
- `AppFixedColumnItem`、`AppFixedColumnRow`：课程与成绩列表共用的比例列数据行；列内容由业务传入，几何和截断规则集中在公共组件内。
- `AppRefreshStatusRow`：统一成绩、课表、DDL 等数据页面的最近更新时间、同步状态和手动刷新入口；所有更新时间直接放进页面主 List 的 Section。
- `ScheduleExternalDesignSystem`：统一桌面 Widget、Live Activity、Apple Watch App 和 Watch Widget 的间距、尺寸、字体数值与缩放比例；该边界保持 Foundation 依赖，跨 target 共享课表展示参数。

`AppHapticFeedback.swift` 提供 `appSelectionFeedback(trigger:)` 和 `appImpactFeedback(trigger:)`，分别用于离散切换和操作按钮；实际是否输出由系统决定。右下角公共按钮、地图校区按钮、课表菜单按钮和空白处长按菜单均接入触感。所有 `Picker`、`Toggle`、自绘勾选行和全选/全不选入口也接入选择触感。`Scripts/check-haptic-consistency.sh` 扫描这些控件、提醒遗漏，并将公共接口之外的触感实现判为失败。

课程、话廊和文章评论页面使用公共评论输入组件；开发者建议复用 `AppComposerToolbar` 与图片草稿组件；评分、图片和文本编辑器等业务差异通过页面内容区保留。
`Scripts/check-component-consistency.sh` 会检查这些页面的公共组件复用情况；匿名开关、提交栏、搜索栏、segmented 控件和评论结构沿用公共实现。

页面使用设计系统中的颜色、圆角和卡片结构。出现不同语义时，先增加命名清晰的令牌或变体，再在页面使用。
所有分组 `List` 的筛选区、结果区、Section 间距和横向宽度统一交给唯一的 `appGroupedListStyle()`；顶部标准 picker 到第一个 Section 的间距复用同一个 `AppDesignSystem.Spacing.content` 令牌；自绘列表的间距使用 `AppDesignSystem.Spacing`。

## 复用规则

1. 相同结构集中到一个公共组件。
2. 内容差异通过参数或显式变体表达。
3. 复制组件后的 `padding`、`corner radius` 和背景色使用公共令牌或显式变体表达。
4. SwiftUI 系统默认值满足要求时，组件直接使用系统默认值。
5. 跨页面的视觉改动集中修改设计系统或公共组件。

## 跨设备自适应约束

本项目同时适配 iPhone、iPad 和 Mac。页面布局依据 SwiftUI 的自适应布局、系统 safe area、
容器提出的可用尺寸、`frame(maxWidth:)` / `frame(maxHeight:)` 和设计令牌确定；页面位置、宽高
和底部避让值统一依据上述规则确定，单台真机截图和单一屏幕尺寸用于验证结果。固定值用于
稳定的语义间距、最小可点击尺寸或设计系统令牌，
绝对坐标、设备相关的固定宽高和机型补偿值列为禁用布局值。

涉及顶部栏、底部 Tab 栏、键盘、分屏、窗口缩放或横竖屏时，内容边界约束在系统 UI 之外；
截图像素差异用于结果核对，布局依据保持为自适应规则。真机验证覆盖至少一种 iPhone 尺寸，
代码审查确认 iPad / Mac 的宽度、窗口和 safe area 采用跨设备布局规则。

## 检查

UI 改动后按需运行：

```sh
Scripts/check-ui-consistency.sh
```

完整源码风格审查使用 `Scripts/check-code-quality.sh`。它扫描 App、Widget、Watch
和测试 target 的全部 Swift 文件；死代码标记、网络/触感公共入口外的调用、已移除文案、
脚本权限问题、动态临时产物路径和失效的本地文档链接由检查阻止，固定布局值、强制解包和大型文件写入审查报告，源码保持原样。

该检查扫描主 App 的 SwiftUI 源码，并检查以下规则：

- 圆角必须通过 `AppDesignSystem.roundedRectangle` 创建。
- 系统背景色必须通过 `AppDesignSystem.Palette` 获取。
- 右下角圆形操作按钮使用公共按钮组件，尺寸和材质由组件统一提供。
- 所有分组列表使用唯一的 `appGroupedListStyle()`，列表样式、横向间距和 section 间距由公共入口统一提供；消息中心使用 plain 列表作为唯一例外。
- 新增的固定 UI 间距使用设计令牌；检查覆盖工作区新增行，历史代码保留原状。
- 详情页必须共用分享与圆形操作按钮，评论区必须共用间距和容器样式，信息流卡片必须共用 Feed 间距。
- 成绩页的顶部切换栏使用公共顶部选择控件与系统安全区布局；成绩页分组列表复用公共横向边距和单层滚动上边距。课表布局使用现有 `Spacing`、`Schedule` 与 `Radius` 令牌，`TopBar.contentGap` 保持移除状态。
- 课表周次滑块和日期栏必须使用可区分的语义背景色；周次与全学期叠加共用等宽列、课程层级和网格线遮罩规则。
- 主 App 的诊断输出由网络 smoke 实现负责；`print`、`debugPrint` 和 `NSLog` 保持在该实现的调用边界内。
- 业务页面将网络请求交给 `HTTPClient` 或场景化 Service；`URLSession.shared` 保持在业务页面调用边界之外，会话与错误处理沿用统一入口。
- 公共卡片容器保留实际调用。

编译和真机检查作为独立验证保留。该检查采用手动触发，发布前或进行大范围 UI 调整时显式执行。
