# BIT101-iOS 模块维护清单

更新时间：2026-09-02

这份清单回答三件事：改哪个文件、哪里容易出错、改完验证什么。

## 1. 登录

### 文件

- `Login/LoginViews.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginService.swift`
- `Login/LoginStorage.swift`
- `Login/BIT101APIClient.swift`

### 风险

- CAS 参数或跳转链变化。
- BIT101 登录桥接失败。
- 网络错误被误判为凭据失效。
- 账号切换后旧请求回写 UI。
- App 登录恢复与教务 challenge 混用。

### 验证

- 有缓存会话时冷启动先展示主界面。
- 断网检查登录态不清除本地会话。
- 明确 401 才清退会话。
- 退出登录后重新登录。
- 切换账号后课表、设置和话廊状态不串号。
- 教务短信 challenge 的弹出、取消和过期处理正常。

## 2. 日程

### 文件

- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleViewModel.swift`
- `Schedule/ScheduleRootView.swift`
- `Schedule/ScheduleService.swift`
- `Schedule/ScheduleCacheStore.swift`
- `Schedule/ScheduleClassroomCoordinator.swift`

### 风险

- 缓存恢复和远端覆盖顺序。
- 学期切换后刷新请求回到当前学期。
- 空响应不得覆盖现有课表；已发布但课程数减少时必须先确认。
- 空教室校区、教学楼和节次匹配。
- DDL、考试、自定义日程边界。
- 教学中心会话失效。
- “按周显示”和“全学期叠加”两种显示模式的布局。

### 验证

- 冷启动立即恢复缓存。
- 手动同步保持选定学期。
- 请求失败保留学期选择。
- 空课表不覆盖现有课程；缩减课表由用户确认后决定是否替换。
- 手动周次可超过课程周数。
- 自动定位限制在第 -12 至 +20 周。
- 未发布学期显示可操作的空课表。
- 空教室按当前时段筛选。
- 退出登录或切号后不再使用旧账号课表。
- 全学期模式文字不拥挤，课程详情入口正常。

## 3. 成绩与课程

### 文件

- `Score/ScoreViewModels.swift`
- `Score/ScoreService.swift`
- `Score/ScoreRootView.swift`
- `Course/CourseViewModel.swift`
- `Course/CourseDetailViewModel.swift`

### 风险

- 成绩字段解析变化。
- 筛选、排序和统计口径混用。
- `jwb` 与 `jwb_cjd` challenge 混用。
- 短信 challenge 过期或重复提交。
- 课程搜索教师匹配错误。

### 验证

- 成绩查询、筛选、排序和统计正常。
- 可信成绩单使用独立 challenge，图片不落盘。
- 课程搜索支持分页和教师匹配。
- 课程详情返回后按课程名搜索，可查看其它教师评价。

## 4. 地图

### 文件

- `Map/CampusMapScreen.swift`

### 验证

- 拖拽、缩放、校区切换、定位和角标正常。
- 不要为消除 `MKMapView` 桥接而重写稳定功能。

## 5. 话廊与文章

### 文件

- `Gallery/GalleryViewModel.swift`
- `Gallery/GalleryRootView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`
- `Paper/PaperViewModel.swift`
- `Paper/PaperRootView.swift`

### 验证

- feed、推荐、最新、最热、机器人流切换正常。
- 推荐流、搜索和消息列表分页正常。
- 帖子、文章详情、评论、点赞和图片预览正常。
- 深链能进入对应详情。
- 未知正文块不强制交给 WebView。

## 6. 我的与设置

### 文件

- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`
- `Settings/AppSettingsStore.swift`
- `Settings/SettingsRootView.swift`
- `Settings/SettingsAccountViews.swift`

### 验证

- 个人资料、他人主页、粉丝、关注和帖子分页正常。
- 主题、自动旋转和账号设置即时生效。
- 退出登录后旧资料请求不再弹窗。

## 7. Widget、Watch、Live Activity

### 文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidgets/`
- `BIT101Watch/`
- `BIT101WatchWidgets/`

### 验证

- 主 App 快照、桌面组件、锁屏组件、Live Activity 和 Watch 内容一致。
- Watch target 使用 watchOS destination 单独构建。
- 不修改旧式 target 结构，不用 generic iOS Debug 结果判断 Watch 发布。

## 8. 跨模块修改顺序

1. 找到真实数据源。
2. 找到持久化位置。
3. 找出页面消费方。
4. 最后改 UI。

优先复用现有 service、协调器和状态模型。不要在页面、ViewModel、持久化层各写一套状态。
