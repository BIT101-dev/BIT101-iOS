# BIT101-iOS 模块维护清单

这份文档不是介绍模块“是什么”，而是回答：

- 如果我要改这个模块，我应该先看哪几个文件
- 哪些地方最容易出回归
- 改完后最值得人工验证什么

适合当作日常维护的落地手册。

## 1. 登录模块

### 先看哪些文件

- `Login/LoginViews.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginService.swift`

### 最容易出问题的点

- 学校 CAS 参数变更
- 学校登录成功但 BIT101 侧注册 / 登录桥接失败
- 登录态检查误把网络波动或学校页面异常当成凭据失效，导致清掉 `fake-cookie` 并连带让 widget / Apple Watch 显示未登录
- 账号切换后，本地状态没有跟着更新
- URL 跳转链里出现 `http -> https` 兼容问题
- 把 App/BIT101 登录恢复与教务业务的 bit-login challenge 混成同一份状态

### 改完建议验证

- 冷启动自动恢复登录
- 断网 / 弱网下触发登录检查时，不应直接退出登录或把手表端推成未登录
- BIT101 明确返回 401 或学校 CAS 静默重登明确失败时，应能正常清退并回到登录流程
- 退出登录再重新登录
- 切换到另一个账号后，课表和设置是否串号
- 教务业务需要短信时能否正确弹出、取消、报错和过期，而不误清 BIT101 登录态

## 2. 日程模块

### 先看哪些文件

- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleService.swift`
- `Schedule/ScheduleViewModel.swift`
- `Schedule/ScheduleRootView.swift`

### 最容易出问题的点

- 缓存恢复和同步覆盖顺序
- 自定义日程与远端课表合并
- 空教室校区 / 教学楼 / 节次自动匹配
- DDL 与考试的展示边界
- 课表日期调休 / 放假是否只影响课程、不误删考试和自定义日程
- 切换目标学期后，普通刷新是否又回到学校当前学期
- 学期列表是否夹带客户端推算项，首周日期是否与目标学期一致
- 教学中心 session 失效后是否只做有限自动恢复

### 改完建议验证

- 冷启动是否能秒开并恢复缓存
- 手动同步后结果是否正常刷新
- 学期页是否只显示学校实际返回的选项
- 切到其它学期后，课程、考试、首周日期是否一起切换
- 第 1 周之前显示为 `-1、-2…`，且第 16 周之后仍可浏览
- 尚未发布课表的学期是否显示可操作的空课表
- 空教室是否仍按当前时段块筛选
- 切号后是否不再使用上一个账号的课表

## 3. 成绩模块

### 先看哪些文件

- `Score/ScoreModels.swift`
- `Score/ScoreCacheStore.swift`
- `Score/ScoreService.swift`
- `Score/ScoreRootView.swift`

### 最容易出问题的点

- 成绩解析字段兼容
- 学期筛选与成绩类型筛选
- “上一次筛选偏好”恢复逻辑
- 列表排序偏好与统计口径是否被混在一起
- `jwb` 与 `jwb_cjd` challenge 被错误复用
- challenge 过期、错误验证码和重复提交是否会卡死 sheet
- 可信成绩单图片是否意外进入磁盘缓存

### 改完建议验证

- 成绩查询是否仍正常
- 普通请求超时后是否给出中文提示；首次认证允许更长的轮询窗口
- 学期筛选退出重进后是否恢复
- 全选 / 全不选 / 0 选是否正常
- 按名称 / 成绩 / 均分 / 学分切换升序和降序后，列表顺序是否符合预期
- 成绩同步中可信成绩单入口是否禁用
- 可信成绩单能否申请、点击进入全屏并双指缩放
- 关闭成绩单页面后，图片和 challenge 是否只从内存中释放

### 3.1 课程模块补充检查

先看 `Course/` 下的 Models、Service、列表 ViewModel、详情 ViewModel 和两份 View。
重点验证课程搜索与分页、教师切换、历年成绩筛选、评分换算、评论点赞及图片全屏预览。
课程状态与成绩状态相互独立，切换顶部分段或左右滑动不应触发另一侧刷新。

## 4. 地图模块

### 先看哪些文件

- `Map/CampusMapScreen.swift`

### 最容易出问题的点

- `MKMapView` 桥接
- 校区跳转
- attribution / legal label 隐藏
- 系统版本变化导致子视图层级变化

### 改完建议验证

- 拖拽缩放
- 校区切换
- 回到我的位置
- 地图角标是否异常

## 5. 话廊模块

### 先看哪些文件

- `Gallery/GalleryModels.swift`
- `Gallery/GalleryService.swift`
- `Gallery/GalleryViewModel.swift`
- `Gallery/GalleryRootView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`

### 最容易出问题的点

- feed 刷新后跳位置
- 推荐流分页、预取和去重
- 本地过滤后的可见列表与原始列表错位
- 帖子详情、图片查看器、消息页之间的路由
- 本地敏感词与屏蔽逻辑

### 改完建议验证

- `关注 / 推荐 / 最新 / 最热 / 机器人` 切换
- 推荐流下滑分页
- 搜索结果分页
- 帖子详情和评论
- 消息中心四个分类切换
- 点消息进入帖子详情

### 5.1 文章模块补充检查

先看 `Paper/` 下的 Models、Service、ViewModel 和 RootView。重点验证文章列表排序与分页、
搜索、发布/编辑、正文块原生渲染、详情点赞、评论以及文章深链。话题和文章共享外层入口，
但不能共享同一份分页状态或把未知正文块强制交给 WebView。

## 6. 我的模块

### 先看哪些文件

- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineRootView.swift`

### 最容易出问题的点

- 个人信息刷新与分页并存
- 粉丝 / 关注 / 帖子分页
- 我的主页与他人主页复用
- 从帖子详情、评论作者跳到他人主页

### 改完建议验证

- 我的主页数据是否正常
- 他人主页能否进入
- 粉丝 / 关注 / 帖子是否能加载更多
- 从他人主页再点帖子详情是否正常

## 7. 设置模块

### 先看哪些文件

- `Settings/AppSettingsStore.swift`
- `Settings/SettingsRootView.swift`
- `Settings/SettingsServices.swift`

### 最容易出问题的点

- 设置是全局还是账号隔离
- 改完后是否即时生效
- 文案与实际行为不一致

### 改完建议验证

- 主题切换
- 自动旋转
- 话廊屏蔽偏好
- 灵动岛阈值
- 关于页与开源声明

## 8. 小组件 / 锁屏组件 / Live Activity

### 先看哪些文件

- `Schedule/ScheduleWidgetSupport.swift`
- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidget.swift`
- `BIT101ScheduleWidget/BIT101ScheduleWidgetBundle.swift`
- `BIT101Watch/BIT101WatchApp.swift`
- `BIT101Watch/WatchScheduleStatusModel.swift`
- `BIT101Watch/WatchScheduleRootView.swift`
- `BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`

### 最容易出问题的点

- 主 App 快照变了，扩展没同步
- widget family 布局被改坏
- 锁屏组件、桌面组件、Live Activity 混成一套逻辑
- 提前显示阈值与实际显示不一致
- 错把新版单 Watch App target 改回旧式 `BIT101WatchExtension` 结构

### 改完建议验证

- 桌面小组件
- 锁屏组件
- Live Activity / 灵动岛
- 深链是否仍然能打开到 `日程 -> 课表`
- Watch App 与 Smart Stack 是否都随主 App 完整构建并嵌入

## 9. 跨模块改动时的建议顺序

如果你准备改的是“一个设置影响多个页面”“一个缓存影响主 App 和 widget”这类功能，建议顺序是：

1. 先定位真实的数据源
2. 再确认谁负责持久化
3. 再确认哪些页面只是消费方
4. 最后再改 UI

不要从页面层直接往下瞎补逻辑，否则很容易变成：

- UI 先写一套临时状态
- ViewModel 再补一套
- 持久化层又补一套

最后谁也说不清到底哪份状态才是真的。
