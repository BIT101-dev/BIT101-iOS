# BIT101-iOS 代码质量审计

更新时间：2026-09-04

## 审计结果

- 默认真机测试共 95 项：89 项 Swift Testing、6 项 XCTest。
- `RELEASE_NETWORK_SMOKE`、`ICLOUD_CROSS_DEVICE_SMOKE` 和 `EXTENDED_AUTOMATION` 为专用测试，测试范围与默认测试和 Release 包分离。
- `EXTENDED_AUTOMATION` 另有 27 项本地自动化测试，按课程表、基础设施、登录三组运行。
- 审查结果显示，已删除功能和旧接口处于测试断言范围外。
- 维护手册与源码职责已在本轮同步；`stale-docs` 检查负责提示长期未编辑文档。
- 已将网络 smoke runner 从 `BIT101_iOSApp.swift` 移到独立文件。
- 已加入逐份源码质量扫描，覆盖 App、Widget、Watch 和测试 target；硬性规则拦截死代码、
  公共网络/触感入口越界和脚本动态临时产物；布局值、强制解包与大型文件生成审查候选。
- 首屏/列表/滚动状态已统一使用公共状态组件；课程与成绩的比例列已统一使用公共数据行；
  日程与成绩的课程评价跳转共用课程匹配器和 CoursePageContent。
- GitHub Actions 已强制执行统一静态审计，并在 generic iOS `build-for-testing` 中将 Swift/Clang 警告视为错误。
- 启动、回前台和切换账号的路径移除学校/WebVPN 自动预热；成绩恢复路径采用本地缓存，查询和短信验证由用户显式操作触发。

## 已完成的结构整理

- Gallery、Schedule、Settings、Paper、Course 的页面按叶子功能拆分。
- 登录拆为存储、会话、密码变换、CAS 解析、API 客户端和业务门面。
- 日程拆出缓存、CloudKit、空教室协调、短信续接、ICS 解析和集合编辑。
- 社区请求统一由 `CommunityAPIClient` 处理认证、URL、状态码和 JSON。
- 取消错误统一由 `TaskCancellation` 识别。
- 分页状态统一由 `PagedItemsState` 管理。
- 错误报告、更新提醒、网络 smoke 各自使用独立基础组件。

## 大文件审查

| 文件 | 判断 |
| --- | --- |
| `Schedule/ScheduleViewModel.swift` | 日程状态、初始化、缓存投影和共享辅助方法。其余职责已移到扩展文件。 |
| `Schedule/ScheduleViewModel+CourseSync.swift` | 课表同步、学期列表、短信验证和显式认证续接。 |
| `Schedule/ScheduleViewModel+Classroom.swift` | 空教室请求、元数据和筛选。 |
| `Schedule/ScheduleViewModel+CourseEditing.swift` | 课程和自定义日程编辑。 |
| `Schedule/ScheduleViewModel+DDL.swift` | 乐学、DDL 和相关文案。 |
| `Schedule/ScheduleViewModel+Preferences.swift` | 周次、显示设置和时间表。 |
| `Schedule/ScheduleModels.swift` | 课表、考试、DDL、缓存模型和编解码。属于同一领域，当前保持合并。 |
| `Schedule/ScheduleRootView.swift` | 日程容器和页面路由。 |
| `Schedule/CourseScheduleTabView.swift` | 课表分栏、周次切换、分享和编辑入口。 |
| `Schedule/ScheduleCalendarViews.swift` | 按周/全学期课表网格和背景层。 |
| `Schedule/ScheduleEntryDetailView.swift` | 课程、考试和自定义日程详情。 |
| `Schedule/ScheduleEditingSupport.swift` | 课程编辑模式和调休/放假表单。 |
| `Score/ScoreViewModels.swift` | 成绩筛选、缓存、短信续接和刷新状态。状态互相关联，当前保持合并。 |
| `Score/ScoreRootView.swift` | 成绩/课程合并页及其列表子视图，后续按独立生命周期拆分。 |
| `Gallery/GalleryModels.swift` | 话廊数据模型和分页状态，职责单一。 |
| `Gallery/GalleryViewModel.swift` | 信息流、搜索、消息状态，推荐预取已独立。 |
| `BIT101_iOSApp.swift` | 应用生命周期和全局副作用。 |
| `Shared/Infrastructure/ReleaseNetworkSmoke.swift` | 编译范围限定为 Debug/专用 smoke 条件，与应用生命周期分离。 |

文件拆分依据独立生命周期、独立测试边界或高频冲突；文件长度单独作为观察指标。

## 保留的桥接

- `Map/CampusMapScreen.swift`：`MKMapView` 提供相机、定位和 overlay 能力。
- `Gallery/GalleryImageViewer.swift`：Quick Look 提供系统图片预览；控制器负责预览图到原图的替换。
- `Gallery/GalleryRootView.swift`：使用 segmented + 手势切换方案，pager 方案列为后续调整项。
- Live Activity、Widget、Watch target：受系统 target 边界约束，单独维护。

这些桥接承担平台适配职责，各自对应系统 target 或平台能力。

## 重复逻辑的统一处理

- 课表同步、学期切换和空教室请求共用教学中心会话准备入口。
- 课程、成绩和学校请求共用 bit-login challenge 基础类型；`jwb`、`jwb_cjd`、教学中心会话保持隔离。
- 空响应和完全相同的课表保留现有课程；已发布课表出现课程数减少时先弹窗确认，替换策略有自动化测试。
- 账号切换会取消旧请求、清理旧错误提示并重置内存状态；设置页旧请求与新会话隔离。
- GitHub Issues 与 Cloudflare KV 报告可由 `Scripts/fetch-issues-and-reports.sh` 一次拉取。

## 风险

1. 学校 CAS、WebVPN、教务 JSON 结构存在变化风险。
2. 课表、成绩、可信成绩单的 challenge 失效和短信续接。
3. App、Widget、Watch、Live Activity 的共享快照版本一致性。
4. 账号切换期间的旧任务取消和 UI 回写。
5. Xcode beta 的 Watch target 构建行为。

## UI 一致性处理

- 主 App 的系统背景色、圆角和公共卡片集中在 `Shared/DesignSystem/AppDesignSystem.swift`。
- 课程、帖子和文章详情页共用分享及圆形操作按钮；评论区共用间距、分割线和容器样式。
- 成绩详情使用原生分组 List，并通过与日程相同的 `CourseNavigationRequest` 流程进入课程评价。
- 课表、成绩、可信成绩单的验证码表单统一使用 `AppSMSVerificationSheet`，保留业务提交文案差异。
- 课程、话廊和消息统一使用 `AppDateText` 解析时间，旧解析器纳入禁用检查。
- `AppDateText` 的多格式解析和回退文案由基础设施单测覆盖。
- 课表缓存和发帖草稿共用 `AppFileDirectories`；保存失败记录诊断，空 `catch` 已移除。
- 头像和标签统一由公共容器加载；课程、话廊和文章共用评论头像/标题/操作/气泡结构；话廊、文章和我的帖子流共用信息流行容器；话廊和文章共用排序搜索栏；所有 segmented 页面选择统一通过公共控件。
- 主要加载失败态统一由 `AppFailureState` 承载；重试和错误反馈入口沿用同一组件结构。
- 周次和全学期叠加课表共用等宽网格，叠加层按课程中心排序并使用不透明课程背景隔离节次分割线。
- 页面差异通过 `AppCardVariant` 等语义变体表达，卡片结构保持共用。
- `Scripts/check-ui-consistency.sh` 检查详情页分享/操作组件、评论区样式、信息流间距和课表叠加规则。
- UI/组件检查共用 `Scripts/check-ui-consistency.py` 的契约表：按目录模式、页面后缀和已采用的公共组件自动发现成员，再检查同一契约的要求；`check-component-consistency.sh` 负责入口转发，契约表负责成员发现和契约检查。
- 组件声明、页面契约和必要例外均集中在契约表；例外限定为消息中心 plain 列表、网络基础设施和平台专用布局等确有边界的项目。
- 规则优先检查页面对公共组件和语义令牌的采用情况；新增同类页面落入目录/组件发现条件即可自动继承契约。
- 检查同时拦截已移除的社区操作回流、主 App 的标准输出写入，并将 plain 列表限定于消息中心。
- 业务页面通过 `HTTPClient` 发起网络请求；`URLSession.shared` 的直接调用归入网络基础设施边界。
- 该检查按需运行，编译和真机验证保持独立。
- `Scripts/check-code-quality.sh` 逐份扫描全部 Swift 文件，并固定输出 `.build/code-quality-report.txt`；
  它覆盖脚本权限、死代码标记、文档失效链接、重复 import、强制解包候选和大型文件候选，
  延伸原有 UI、触感和组件检查范围。
- `run-static-audit.sh` 统一编排检查；源码质量检查核对 UI、触感、组件、错误报告和文档检查的接入状态，
  静态审计与网络 smoke 保持调用隔离；CI 检查该入口和 generic device 编译门禁的存在状态。
- 解释性文案报告扫描范围为列表/表单的 `Section footer` 和空状态的 `ContentUnavailableView description`；
  已由用户确认的文案进入白名单，新增文案继续提示。

## 后续顺序

1. 根据错误报告增加学校响应 fixture。
2. 观察 smoke 失败样本，再补充探针。
3. 观察状态机的修改频率，再决定是否继续拆分。
4. 保持测试、脚本和文档中的版本与数量同步。
