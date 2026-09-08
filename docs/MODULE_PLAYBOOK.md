# BIT101-iOS 模块维护清单

更新时间：2026-09-02

每个模块列出相关文件、风险和验证项。

## 1. 登录

### 文件

- `Login/LoginViews.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginService.swift`
- `Login/LoginStorage.swift`
- `Login/BIT101APIClient.swift`

### 风险

- CAS 参数或跳转链变化会影响登录流程。
- BIT101 登录桥接可能失败。
- 网络错误可能被误判为凭据失效。
- 账号切换后，旧请求可能回写 UI。
- App 登录恢复与教务 challenge 可能混用。

### 验证

- 冷启动在存在缓存会话时先展示主界面。
- 断网检查登录态时，本地会话保持不变。
- 会话仅在明确返回 401 时清退。
- 用户退出登录后重新登录，检查登录流程。
- 切换账号后，课表、设置和话廊状态与当前账号匹配。
- 教务短信 challenge 在弹出、取消和过期场景下分别完成对应处理。

## 2. 日程

### 文件

- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleViewModel.swift`
- `Schedule/ScheduleRootView.swift`
- `Schedule/ScheduleService.swift`
- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleClassroomCoordinator.swift`

### 风险

- 缓存恢复与远端覆盖顺序可能错误。
- 学期切换后，刷新请求可能回到当前学期。
- 空响应保留现有课表；已发布但课程数减少时，用户确认后再替换课表。
- 空教室查询可能错误匹配校区、教学楼和节次。
- DDL、考试和自定义日程的边界需要分别核对。
- 教学中心会话可能失效。
- “按周显示”和“全学期叠加”两种显示模式的布局需要分别核对。

### 验证

- 应用冷启动立即恢复缓存。
- 手动同步保持当前选定学期。
- 请求失败时保留当前学期选择。
- 空课表保留现有课程；缩减课表由用户确认是否替换。
- 手动周次可超过课程周数。
- 自动定位范围限定为第 -12 至 +20 周。
- 未发布学期显示可操作的空课表。
- 空教室查询按当前时段筛选。
- 退出登录或切号后，旧账号课表与当前读取范围解除关联。
- 全学期模式保持文字可读，课程详情入口保持可用。

## 3. 成绩与课程

### 文件

- `Score/ScoreViewModels.swift`
- `Score/ScoreService.swift`
- `Score/ScoreRootView.swift`
- `Course/CourseViewModel.swift`
- `Course/CourseDetailViewModel.swift`

### 风险

- 成绩字段变化可能影响解析。
- 筛选、排序和统计可能混用口径。
- `jwb` 与 `jwb_cjd` challenge 可能混用。
- 短信 challenge 可能过期或重复提交。
- 课程搜索可能错误匹配教师。

### 验证

- 成绩查询、筛选、排序和统计结果分别与对应条件匹配。
- 可信成绩单使用独立 challenge，图片处理保留在内存中。
- 课程搜索支持分页和教师匹配。
- 课程详情返回后按课程名搜索，支持查看其他教师评价。

## 4. 地图

### 文件

- `Map/CampusMapScreen.swift`

### 验证

- 地图验证拖拽、缩放、校区切换、定位和角标。
- `MKMapView` 桥接消除时，稳定功能保持原状。

## 5. 话廊与文章

### 文件

- `Gallery/GalleryViewModel.swift`
- `Gallery/GalleryRootView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`
- `Paper/PaperViewModel.swift`
- `Paper/PaperRootView.swift`

### 验证

- 页面验证 feed、推荐、最新、最热和机器人流切换。
- 推荐流、搜索和消息列表支持分页。
- 帖子、文章详情、评论、点赞和图片预览保持可用。
- 深链支持进入对应详情。
- 未知正文块按类型选择处理方式，WebView 遵循正文块类型条件。

## 6. 我的与设置

### 文件

- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`
- `Settings/AppSettingsStore.swift`
- `Settings/SettingsRootView.swift`
- `Settings/SettingsAccountViews.swift`

### 验证

- 个人资料、他人主页、粉丝、关注和帖子支持分页。
- 主题、自动旋转和账号设置即时生效。
- 退出登录后，旧资料请求与弹窗解除关联。

## 7. Widget、Watch、Live Activity

### 文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidgets/`
- `BIT101Watch/`
- `BIT101WatchWidgets/`

### 验证

- 主 App 快照、桌面组件、锁屏组件、Live Activity 和 Watch 内容保持一致。
- Watch target 使用 watchOS destination 单独构建。
- 旧式 target 结构保持现状；Watch 发布判断以 watchOS destination 单独构建结果为准，`generic iOS Debug` 结果与 Watch 发布判断分离。

## 8. 跨模块修改顺序

1. 修改前确认真实数据源。
2. 修改前确认持久化位置。
3. 修改前确认页面消费方。
4. 完成数据链路确认后修改 UI。

跨模块修改优先复用现有 service、协调器和状态模型；页面、ViewModel、持久化层共享同一套状态。
