# BIT101-iOS 源码文件索引

这份文档只做一件事：列出当前全部 Swift 源码文件，并给出每份文件的职责说明。

适合这几种场景：

- 你知道要改哪个模块，但不知道先从哪份文件看起
- 你想快速判断某份文件是模型、服务、状态机还是视图
- 你想确认一个功能到底分布在主 App 还是 widget extension

## 1. 主应用入口与公共文件

- `BIT101-iOS/BIT101-iOS/BIT101_iOSApp.swift`
  应用入口，负责全局主题、根视图挂载和屏幕方向策略。
- `BIT101-iOS/BIT101-iOS/ContentView.swift`
  根容器，根据登录状态切换登录页或登录后壳层。
- `BIT101-iOS/BIT101-iOS/CachedRemoteImage.swift`
  远程图片缓存组件，负责头像等高频图片的内存与磁盘缓存。
- `BIT101-iOS/BIT101-iOS/Shared/ScheduleSharedOccurrence.swift`
  跨主 App / widget / watch 共用的课表 occurrence 解析与展示规范化逻辑。
- `BIT101-iOS/BIT101-iOS/Shared/ScheduleSharedSnapshot.swift`
  共享快照模型、共享容器路径和读写入口。
- `BIT101-iOS/BIT101-iOS/WatchSync/WatchScheduleSyncManager.swift`
  iPhone 与 Apple Watch 之间的课表镜像同步桥。

## 2. Shell

- `BIT101-iOS/BIT101-iOS/Shell/AppShellView.swift`
  登录后的全局壳层，负责 tab、全局路由、深链分发和部分跨模块弹层。

## 3. 登录模块

- `BIT101-iOS/BIT101-iOS/Login/LoginViews.swift`
  登录页、启动检查页、原生表单 UI。
- `BIT101-iOS/BIT101-iOS/Login/LoginViewModel.swift`
  登录流程状态机，管理输入、提交、错误态和恢复逻辑。
- `BIT101-iOS/BIT101-iOS/Login/LoginService.swift`
  学校 CAS、SSO、BIT101 登录桥接、Keychain 与凭据恢复。

## 4. 话廊模块

- `BIT101-iOS/BIT101-iOS/Gallery/CommunityModeration.swift`
  本地敏感词、屏蔽规则、举报相关辅助逻辑。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryComposerView.swift`
  发帖页，包括标签、自定义标签、内容输入和提交。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryModels.swift`
  帖子、评论、搜索、消息、用户等模型定义。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryPosterDetailViewModel.swift`
  帖子详情页状态机，处理评论、点赞、详情刷新等。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryRootView.swift`
  话廊首页、消息页、搜索页、帖子详情、图片查看器等主要视图。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryService.swift`
  话廊 feed、搜索、消息、帖子详情、删除等网络接口。
- `BIT101-iOS/BIT101-iOS/Gallery/GalleryViewModel.swift`
  话廊 feed、搜索与消息分类的状态机，负责刷新、分页、预取和本地已读近似状态。

## 5. 地图模块

- `BIT101-iOS/BIT101-iOS/Map/CampusMapScreen.swift`
  基于 `MapKit` 的地图页，包含校区跳转、定位与自定义图层桥接。

## 6. 我的模块

- `BIT101-iOS/BIT101-iOS/Mine/MineModels.swift`
  个人资料、分页状态、列表项等模型。
- `BIT101-iOS/BIT101-iOS/Mine/MineRootView.swift`
  我的主页、他人主页、粉丝、关注、帖子列表等视图。
- `BIT101-iOS/BIT101-iOS/Mine/MineService.swift`
  个人信息、粉丝、关注、帖子列表相关请求。
- `BIT101-iOS/BIT101-iOS/Mine/MineViewModel.swift`
  我的模块状态机，管理主页加载与分页。

## 7. 日程模块

- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleLiveActivityManager.swift`
  课程提醒 Live Activity 管理器，负责开始、更新和结束提醒。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleModels.swift`
  课表、考试、DDL、空教室、自定义日程、本地缓存和时间表相关模型。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleRootView.swift`
  日程页主视图，包含课表、DDL、空教室三块 UI。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleService.swift`
  教务、乐学、空教室接口及解析逻辑。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleViewModel.swift`
  日程模块状态机，负责缓存恢复、同步、偏好恢复、自动匹配和查询。
- `BIT101-iOS/BIT101-iOS/Schedule/ScheduleWidgetSupport.swift`
  将主 App 课表导出为共享快照，供 widget / 锁屏 / Live Activity 使用。

## 8. 成绩模块

- `BIT101-iOS/BIT101-iOS/Score/ScoreModels.swift`
  成绩记录、筛选与统计模型。
- `BIT101-iOS/BIT101-iOS/Score/ScoreRootView.swift`
  成绩主页、筛选页、统计展示等原生视图。
- `BIT101-iOS/BIT101-iOS/Score/ScoreService.swift`
  成绩查询接口与响应解析。

## 9. 设置模块

- `BIT101-iOS/BIT101-iOS/Settings/AppSettingsStore.swift`
  设置快照与持久化中心，处理全局设置和账号隔离设置。
- `BIT101-iOS/BIT101-iOS/Settings/SettingsRootView.swift`
  设置页、关于页、开源声明与子设置页。
- `BIT101-iOS/BIT101-iOS/Settings/SettingsServices.swift`
  设置模块复用的网络辅助逻辑。

## 10. Widget / 锁屏组件 / Live Activity 扩展

- `BIT101-iOS/BIT101ScheduleWidget/BIT101ScheduleWidget.swift`
  桌面小组件、锁屏组件、Live Activity / Dynamic Island 的主要实现。
- `BIT101-iOS/BIT101ScheduleWidget/BIT101ScheduleWidgetBundle.swift`
  widget bundle 入口，用来向系统注册当前扩展提供的组件。

## 11. Apple Watch

- `BIT101-iOS/BIT101Watch/BIT101WatchApp.swift`
  watch app 入口，负责挂载 watch 主页面状态模型。
- `BIT101-iOS/BIT101Watch/WatchScheduleRootView.swift`
  Apple Watch 主页面与本地镜像消费逻辑。
- `BIT101-iOS/BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`
  Apple Watch Smart Stack 课表组件。
- `BIT101-iOS/BIT101WatchWidgets/BIT101WatchWidgetsBundle.swift`
  watch widgets bundle 入口，用来向系统注册 Smart Stack 组件。

## 12. 建议阅读顺序

如果你准备修改某个模块，推荐先按这个顺序看：

1. 对应模块的 `Models`
2. 对应模块的 `Service`
3. 对应模块的 `ViewModel`
4. 对应模块的 `RootView`

如果你准备改全局行为，优先看：

1. `BIT101_iOSApp.swift`
2. `ContentView.swift`
3. `Shell/AppShellView.swift`
4. `Settings/AppSettingsStore.swift`
