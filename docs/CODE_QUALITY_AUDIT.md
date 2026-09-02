# BIT101-iOS 代码质量审计

更新时间：2026-09-02

## 结论

- 默认真机测试共 95 项：89 项 Swift Testing、6 项 XCTest。
- `RELEASE_NETWORK_SMOKE` 和 `ICLOUD_CROSS_DEVICE_SMOKE` 为专用测试，不进入默认测试和 Release 包。
- 未发现测试仍断言已删除功能或旧接口。
- 发现一份维护手册超过 30 天未更新，已在本轮同步更新。
- 已将网络 smoke runner 从 `BIT101_iOSApp.swift` 移到独立文件。
- 不按行数机械拆分状态机和模型文件。

## 已完成的结构整理

- Gallery、Schedule、Settings、Paper、Course 的页面按叶子功能拆分。
- 登录拆为存储、会话、密码变换、CAS 解析、API 客户端和业务门面。
- 日程拆出缓存、CloudKit、空教室协调、短信续接、ICS 解析和集合编辑。
- 社区请求统一由 `CommunityAPIClient` 处理认证、URL、状态码和 JSON。
- 取消错误统一由 `TaskCancellation` 识别。
- 分页状态统一由 `PagedItemsState` 管理。
- 错误报告、更新提醒、网络 smoke 各自使用独立基础组件。

## 大文件审查

| 文件 | 行数 | 判断 |
| --- | ---: | --- |
| `Schedule/ScheduleViewModel.swift` | 347 | 日程状态、初始化、缓存投影和共享辅助方法。其余职责已移到扩展文件。 |
| `Schedule/ScheduleViewModel+CourseSync.swift` | 258 | 课表同步、学期列表、短信验证和自动刷新。 |
| `Schedule/ScheduleViewModel+Classroom.swift` | 573 | 空教室请求、元数据和筛选。 |
| `Schedule/ScheduleViewModel+CourseEditing.swift` | 223 | 课程和自定义日程编辑。 |
| `Schedule/ScheduleViewModel+DDL.swift` | 151 | 乐学、DDL 和相关文案。 |
| `Schedule/ScheduleViewModel+Preferences.swift` | 203 | 周次、显示设置和时间表。 |
| `Schedule/ScheduleModels.swift` | 674 | 课表、考试、DDL、缓存模型和编解码。属于同一领域。暂不拆。 |
| `Schedule/ScheduleRootView.swift` | 1009 | 日程容器、路由和多页面协调。叶子页面已独立。暂不拆。 |
| `Score/ScoreViewModels.swift` | 734 | 成绩筛选、缓存、短信续接和刷新状态。状态互相关联。暂不拆。 |
| `Score/ScoreRootView.swift` | 865 | 成绩/课程合并页及其列表子视图。后续可按页面增长拆分。 |
| `Gallery/GalleryModels.swift` | 728 | 话廊数据模型和分页状态。职责单一。暂不拆。 |
| `Gallery/GalleryViewModel.swift` | 676 | feed、搜索、消息状态。推荐预取已独立。暂不拆。 |
| `BIT101_iOSApp.swift` | 457 | 应用生命周期和全局副作用。网络 smoke runner 已独立。 |
| `Shared/Infrastructure/ReleaseNetworkSmoke.swift` | 441 | 只在 Debug/专用 smoke 条件下编译。与应用生命周期分离。 |

继续拆分的条件：出现独立生命周期、独立测试边界或高频冲突。仅为减少行数不拆。

## 有意保留的桥接

- `Map/CampusMapScreen.swift`：`MKMapView` 提供相机、定位和 overlay 能力。
- `Gallery/GalleryImageViewer.swift`：Quick Look 提供系统图片预览；控制器负责预览图到原图的替换。
- `Gallery/GalleryRootView.swift`：segmented + 手势切换已稳定，暂不改为 pager。
- Live Activity、Widget、Watch target：受系统 target 边界约束，单独维护。

这些是平台适配，不是重复实现。

## 已收口的重复逻辑

- 课表同步、学期切换和空教室请求共用教学中心会话准备入口。
- 课程、成绩和学校请求共用 bit-login challenge 基础类型，但 `jwb`、`jwb_cjd`、教学中心会话保持隔离。
- 空响应、缩减响应和完全相同的课表不会覆盖现有课程；替换策略有自动化测试。
- 账号切换会取消预热任务、清理旧错误提示，设置页旧请求不会回写新会话。
- GitHub Issues 与 Cloudflare KV 报告可由 `Scripts/fetch-issues-and-reports.sh` 一次拉取。

## 仍需关注的真实风险

1. 学校 CAS、WebVPN、教务 JSON 结构变化。
2. 课表、成绩、可信成绩单的 challenge 失效和短信续接。
3. App、Widget、Watch、Live Activity 的共享快照版本一致性。
4. 账号切换时旧任务的取消和 UI 回写。
5. Xcode beta 对 Watch target 的构建行为。

## 后续顺序

1. 依据真实错误报告增加学校响应 fixture。
2. 观察 smoke 失败样本，再补充探针。
3. 观察状态机的修改频率，再决定是否继续拆分。
4. 保持测试、脚本和文档中的版本与数量同步。
