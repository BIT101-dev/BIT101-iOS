# BIT101-iOS 代码质量审查

更新时间：2026-09-22

## 当前工程约束

- 主 App、Widget、Watch App、Watch Widget 与测试 target 按各自平台边界组织。
- 网络请求通过 `HTTPClient`、`CommunityAPIClient` 或场景化 Service 发送。
- 任务取消、账号隔离存储、日期展示、错误分类和网络诊断复用 `Shared/Client` 中的公共入口。
- UI 令牌与组件位于 `Shared/DesignSystem`；课表、课程、话廊使用所属模块的专用设计文件。
- ViewModel 通过场景化 `Servicing` 协议依赖 Service，页面负责状态呈现与交互。
- 账号切换会取消过期任务并隔离缓存、诊断提示与页面状态。

## 结构审查结论

- 日程服务按同步、缓存、认证、空教室、DDL、日历和编解码职责拆分。
- 课表界面按网格、线性时间轴、课程卡片、周次控件和详情分工。
- Gallery、Paper、Course、Mine 与 Settings 按各自页面流程分层。
- 登录模块由认证 Service、会话状态、Keychain 存储、CAS 解析和 API 客户端组成。
- HTTP 传输、社区请求、网络诊断、错误报告和更新检查归 `Shared/Client`。
- 加载、空态、失败提示和操作恢复由共享组件提供。

## 跨页面约定

- 课表、成绩与可信成绩单共用短信验证表单；各业务 Service 维护独立 challenge。
- 评论、头像、标签、列表、搜索、刷新、比例数据行和浮动按钮通过设计系统组件复用。
- 课程、话廊、文章和消息的日期文案由 `AppDateText` 提供。
- 社区分页由 `PagedItemsState` 管理；课程、话廊、文章、我的页面通过场景协议维护独立业务状态。
- 错误报告脱敏与载荷由 `ErrorReportSupport.swift` 维护；原生弹窗、恢复操作和报告 Sheet 由 `AppErrorPresentation.swift` 维护。

## Apple 平台桥接

- `Map/CampusMapScreen.swift` 使用 `MKMapView` 管理相机、定位和地图 overlay。
- `Gallery/GalleryImageViewer.swift` 使用 Quick Look 呈现原图，并维护低清到高清的预览切换。
- `Schedule/ScheduleCalendarViews.swift` 使用 `UIContextMenuInteraction` 定位空白课表区域的原生菜单，并通过 `UIActivityViewController` 提供系统分享面板。
- `Schedule/ScheduleLinearCalendarViews.swift` 使用 `UIScrollView` 和 `UIHostingController` 实现双指缩放与可见中心保持。
- `Schedule/ScheduleCourseCardViews.swift` 使用 `UILabel` 排列独立的课程名称、完整地点和动态字体。
- `Paper/PaperDetailView.swift` 使用 `UITextView` 呈现 HTML 富文本。
- `Gallery/GalleryAnimatedImage.swift` 使用 ImageIO 和 `UIImageView` 解码、播放 GIF。
- `Shared/Client/KeyboardDismissSupport.swift` 使用 UIKit 手势和输入附件处理跨页面键盘收起。
- `Gallery/GalleryRootView.swift` 提供原生话廊与用户可选的 WKWebView 入口。

## 检查入口

- `Scripts/check-ui-consistency.sh`：视觉令牌、字体、布局、页面角色、公共组件、系统触感和错误报告入口。
- `Scripts/check-code-quality.sh`：客户端网络、存储、日期、并发、源码与脚本规范。
- `Scripts/run-static-audit.sh`：统一运行静态检查。
- `Scripts/run-extended-tests.sh`：默认与分组自动化测试。

各项检查从当前源码和项目测试 target 获取状态。此文档维护结构边界和公共入口说明。
