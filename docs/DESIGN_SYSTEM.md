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
- `appGroupedListStyle()`：统一 inset grouped 列表及 section 间距。
- `appCommentSectionStyle()`：统一课程、帖子和文章的评论区容器样式。
- `AppComposerContentSection`、`AppCommentComposerContentSection`、`AppComposerToolbar`：统一课程、话廊、文章评论和开发者建议的输入区共性及工具栏。

`AppHapticFeedback.swift` 提供 `appSelectionFeedback(trigger:)` 和 `appImpactFeedback(trigger:)`，分别用于离散切换和操作按钮；实际是否输出由系统决定。右下角公共按钮、地图校区按钮、课表菜单按钮和空白处长按菜单均接入触感。所有 `Picker`、`Toggle`、自绘勾选行和全选/全不选入口也必须接入选择触感。`Scripts/check-haptic-consistency.sh` 会扫描这些控件，提醒遗漏，并拒绝绕过公共接口的触感实现。

课程、话廊和文章评论页面使用公共评论输入组件；开发者建议复用公共内容段和编辑工具栏；评分、图片和文本编辑器等业务差异通过页面内容区保留。
`Scripts/check-component-consistency.sh` 会检查这些页面是否复用公共组件，避免匿名开关、提交栏再次分叉实现。

页面不应重新声明同一类颜色、圆角或卡片结构。确有不同语义时，先增加命名清晰的令牌或变体，再在页面使用。
分组 `List` 的筛选区、结果区和 section 间距统一交给 `appGroupedListStyle()`；自绘列表的间距使用 `AppDesignSystem.Spacing`。

## 复用规则

1. 相同结构只保留一个公共组件。
2. 内容差异通过参数或显式变体表达。
3. 不通过复制组件后微调 padding、corner radius 或背景色制造“新样式”。
4. 能用 SwiftUI 系统默认值时，不额外设置同等效果的自定义值。
5. 跨页面的视觉改动只修改设计系统或公共组件。

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
- 分组列表必须使用 `appGroupedListStyle()`，不要在页面单独设置 section 间距；消息中心的 plain 列表是唯一例外。
- 新增的固定 UI 间距必须使用设计令牌；检查只针对工作区新增行，不强迫一次性重写历史代码。
- 详情页必须共用分享与圆形操作按钮，评论区必须共用间距和容器样式，信息流卡片必须共用 Feed 间距。
- 学业页的顶部切换栏由外层安全区承载，成绩与课程列表不重复叠加滚动上边距。
- 课表周次滑块和日期栏必须使用可区分的语义背景色；周次与全学期叠加共用等宽列、课程层级和网格线遮罩规则。
- 已移除的社区举报、文章隐藏等入口在全部源码中保持禁用，避免从详情页或旧菜单回流。
- 主 App 不直接调用 `print`、`debugPrint` 或 `NSLog`；诊断输出只由网络 smoke 实现负责。
- 业务页面不直接调用 `URLSession.shared`；网络请求统一经 `HTTPClient` 或场景化 Service，避免会话与错误处理分叉。
- 公共卡片容器仍保留并有实际调用。

它不替代编译和真机检查，也不默认运行。发布前或进行大范围 UI 调整时显式执行即可。
