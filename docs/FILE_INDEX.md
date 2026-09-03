# BIT101-iOS 源码索引

这份文档提供**模块入口和职责地图**，不再手工维护逐文件清单。新增同模块文件时只需保持目录归属；完整清单用文末命令生成。

## 应用入口

- `BIT101-iOS/BIT101_iOSApp.swift`：应用入口、全局主题、方向策略。
- `BIT101-iOS/ContentView.swift`：按登录状态切换登录页和主壳层。
- `BIT101-iOS/Shell/AppShellView.swift`：登录后 tab、全局路由、深链和跨模块弹层。
- `BIT101-iOS/Settings/AppSettingsStore.swift`：全局设置、账号隔离和公告状态。

## 共享层

- `BIT101-iOS/Shared/Infrastructure/`：提示模型、深链、更新检查、紧急更新、错误报告、键盘收起、分页、账号存储、手势、任务取消、偏好同步和网络 smoke。
- `BIT101-iOS/Shared/Networking/`：HTTP 传输、社区 API、登录 challenge 支持和安全 URL 传输。
- `BIT101-iOS/Shared/ScheduleShared*.swift`：主 App、widget、Live Activity 共用的课表快照与 occurrence 规范。
- `BIT101-iOS/WatchSync/WatchScheduleSyncManager.swift`：iPhone 与 Apple Watch 的课表镜像同步。
- `BIT101-iOS/CachedRemoteImage.swift`：头像等远程图片的内存与磁盘缓存。

## 业务模块

### 登录

目录：`BIT101-iOS/Login/`

`LoginViews.swift` 是表单入口，`LoginViewModel.swift` 管理状态，`LoginService.swift` 协调登录与会话，`BIT101APIClient.swift` 负责学校与 BIT101 网络请求；其余文件负责模型、存储、加密和 CAS 页面解析。

### 话廊与文章

- `BIT101-iOS/Gallery/`：信息流、搜索、消息、帖子详情、评论、治理、图片缓存和发帖。
- `BIT101-iOS/Paper/`：文章列表、详情、评论、编辑、搜索和点赞。

各模块的 `*RootView.swift` 是页面入口，`*Service.swift` 是网络门面，`*ViewModel.swift` 管理页面状态，`*Models.swift` 保存载荷模型。

### 日程

目录：`BIT101-iOS/Schedule/`

- `ScheduleRootView.swift`：日程页容器和页面路由。
- `ScheduleCalendarViews.swift`：按周/全学期课表网格、课程详情、分享和交互。
- `ScheduleModels.swift`：课程、考试、DDL、空教室和缓存领域模型。
- `ScheduleViewModel*.swift`：同步、学期、空教室、编辑、DDL 和偏好分支。
- `ScheduleService*.swift`：教学中心、乐学、认证、传输及响应模型。
- `ScheduleCacheStore.swift`、`ScheduleWidgetSupport.swift`：缓存持久化和 widget 导出。
- 其余解析器、策略、日历、分享和编辑文件按职责拆分，不在此重复列出。

### 成绩与课程

- `BIT101-iOS/Score/`：成绩、筛选、统计、可信成绩单及其独立状态机。
- `BIT101-iOS/Course/`：课程搜索、详情、教师评价、历年成绩和评论。

两者均遵循 Models / Service / Servicing / ViewModel / View 的职责划分。

### 地图

目录：`BIT101-iOS/Map/`

`CampusMapScreen.swift` 是地图入口，`CampusNativeMapView.swift` 桥接 MapKit，`CampusMapLocations.swift` 保存校区与教室匹配规则；定位和下一节课解析分别由同目录辅助文件负责。

### 我的与设置

- `BIT101-iOS/Mine/`：个人主页、他人主页、关注关系和帖子列表。
- `BIT101-iOS/Settings/`：账号、外观、课表、DDL、话廊、关于和开发者建议页面。

## 扩展 target

- `BIT101ScheduleWidget/`：桌面/锁屏 widget、Live Activity 和 Dynamic Island。
- `BIT101Watch/`：Apple Watch 主 App。
- `BIT101WatchWidgets/`：Apple Watch Smart Stack widget。

旧目录 `BIT101WatchExtension/` 已删除，不应重新添加。

## 维护提示

- 课表核心 UI 仍集中在 `ScheduleCalendarViews.swift` 与 `ScheduleRootView.swift`；拆分计划见 [CODE_QUALITY_AUDIT.md](CODE_QUALITY_AUDIT.md)。
- 新文件优先放入已有模块目录，不在根目录复制业务实现。
- 网络请求统一经过对应 Service，不在 View 中直接创建请求。

## 生成完整文件清单

文档不保存易过时的行号或逐文件职责表。需要完整清单时运行：

```sh
find BIT101-iOS BIT101ScheduleWidget BIT101Watch BIT101WatchWidgets \
  -type f -name '*.swift' | sort
```
