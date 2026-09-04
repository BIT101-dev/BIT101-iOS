# BIT101-iOS 代码质量审计

更新时间：2026-09-03

## 结论

- 默认真机测试共 95 项：89 项 Swift Testing、6 项 XCTest。
- `RELEASE_NETWORK_SMOKE`、`ICLOUD_CROSS_DEVICE_SMOKE` 和 `EXTENDED_AUTOMATION` 为专用测试，不进入默认测试和 Release 包。
- `EXTENDED_AUTOMATION` 另有 27 项本地自动化测试，按课程表、基础设施、登录三组运行。
- 未发现测试仍断言已删除功能或旧接口。
- 维护手册与源码职责已在本轮同步，后续由 stale-docs 检查提醒长期未编辑文档。
- 已将网络 smoke runner 从 `BIT101_iOSApp.swift` 移到独立文件。
- 不因文件长度机械拆分状态机和模型文件。
- 已加入逐份源码质量扫描，覆盖 App、Widget、Watch 和测试 target；硬性规则阻止死代码、
  越过公共网络/触感入口和脚本动态临时产物，布局值、强制解包与大型文件仅生成审查候选。

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
| `Schedule/ScheduleViewModel+CourseSync.swift` | 课表同步、学期列表、短信验证和自动刷新。 |
| `Schedule/ScheduleViewModel+Classroom.swift` | 空教室请求、元数据和筛选。 |
| `Schedule/ScheduleViewModel+CourseEditing.swift` | 课程和自定义日程编辑。 |
| `Schedule/ScheduleViewModel+DDL.swift` | 乐学、DDL 和相关文案。 |
| `Schedule/ScheduleViewModel+Preferences.swift` | 周次、显示设置和时间表。 |
| `Schedule/ScheduleModels.swift` | 课表、考试、DDL、缓存模型和编解码。属于同一领域，暂不拆。 |
| `Schedule/ScheduleRootView.swift` | 日程容器和页面路由。 |
| `Schedule/CourseScheduleTabView.swift` | 课表分栏、周次切换、分享和编辑入口。 |
| `Schedule/ScheduleCalendarViews.swift` | 按周/全学期课表网格和背景层。 |
| `Schedule/ScheduleEntryDetailView.swift` | 课程、考试和自定义日程详情。 |
| `Schedule/ScheduleEditingSupport.swift` | 课程编辑模式和调休/放假表单。 |
| `Score/ScoreViewModels.swift` | 成绩筛选、缓存、短信续接和刷新状态。状态互相关联，暂不拆。 |
| `Score/ScoreRootView.swift` | 成绩/课程合并页及其列表子视图，后续按独立生命周期拆分。 |
| `Gallery/GalleryModels.swift` | 话廊数据模型和分页状态，职责单一。 |
| `Gallery/GalleryViewModel.swift` | 信息流、搜索、消息状态，推荐预取已独立。 |
| `BIT101_iOSApp.swift` | 应用生命周期和全局副作用，网络 smoke runner 已独立。 |
| `Shared/Infrastructure/ReleaseNetworkSmoke.swift` | 只在 Debug/专用 smoke 条件下编译，与应用生命周期分离。 |

继续拆分的条件：出现独立生命周期、独立测试边界或高频冲突。仅为减少文件长度不拆。

## 有意保留的桥接

- `Map/CampusMapScreen.swift`：`MKMapView` 提供相机、定位和 overlay 能力。
- `Gallery/GalleryImageViewer.swift`：Quick Look 提供系统图片预览；控制器负责预览图到原图的替换。
- `Gallery/GalleryRootView.swift`：segmented + 手势切换已稳定，暂不改为 pager。
- Live Activity、Widget、Watch target：受系统 target 边界约束，单独维护。

这些是平台适配，不是重复实现。

## 已收口的重复逻辑

- 课表同步、学期切换和空教室请求共用教学中心会话准备入口。
- 课程、成绩和学校请求共用 bit-login challenge 基础类型，但 `jwb`、`jwb_cjd`、教学中心会话保持隔离。
- 空响应和完全相同的课表不会覆盖现有课程；已发布但课程数减少时先弹窗确认，替换策略有自动化测试。
- 账号切换会取消预热任务、清理旧错误提示，设置页旧请求不会回写新会话。
- GitHub Issues 与 Cloudflare KV 报告可由 `Scripts/fetch-issues-and-reports.sh` 一次拉取。

## 仍需关注的真实风险

1. 学校 CAS、WebVPN、教务 JSON 结构变化。
2. 课表、成绩、可信成绩单的 challenge 失效和短信续接。
3. App、Widget、Watch、Live Activity 的共享快照版本一致性。
4. 账号切换时旧任务的取消和 UI 回写。
5. Xcode beta 对 Watch target 的构建行为。

## UI 一致性收口

- 主 App 的系统背景色、圆角和公共卡片集中在 `Shared/DesignSystem/AppDesignSystem.swift`。
- 课程、帖子和文章详情页共用分享及圆形操作按钮；评论区共用间距、分割线和容器样式。
- 周次和全学期叠加课表共用等宽网格，叠加层按课程中心排序并使用不透明课程背景隔离节次分割线。
- 页面差异通过 `AppCardVariant` 等语义变体表达，不复制卡片结构后局部修改。
- `Scripts/check-ui-consistency.sh` 还会检查详情页分享/操作组件、评论区样式、信息流间距和课表叠加规则。
- 检查同时阻止已移除的社区操作回流、阻止主 App 直接写标准输出，并限制 plain 列表只用于消息中心。
- 网络请求边界也纳入检查：业务页面不能绕过 `HTTPClient` 直接使用 `URLSession.shared`。
- 该检查按需运行，不替代编译或真机验证。
- `Scripts/check-code-quality.sh` 逐份扫描全部 Swift 文件，并固定输出 `.build/code-quality-report.txt`；
  它补充了原有 UI、触感、组件检查未覆盖的脚本权限、死代码标记、文档失效链接、重复 import、
  强制解包候选和大型文件候选。
- `run-static-audit.sh` 负责统一编排；源码质量检查会确认 UI、触感、组件、错误报告和文档检查仍已接入，
  并确保静态审计不会误调用网络 smoke。
- 解释性文案报告仅扫描列表/表单的 `Section footer` 和空状态的 `ContentUnavailableView description`；
  已由用户确认的文案进入白名单，新增文案继续提示。

## 后续顺序

1. 依据真实错误报告增加学校响应 fixture。
2. 观察 smoke 失败样本，再补充探针。
3. 观察状态机的修改频率，再决定是否继续拆分。
4. 保持测试、脚本和文档中的版本与数量同步。
