# iOS 相对 Android 的待补齐能力审计

**审计日期：** 2026-09-19  
**审计范围：** `BIT101-iOS` 与 `../BIT101-Android` 当前源码、工程配置、测试入口  
**关注方向：** Android 已有、iOS 待补齐的能力  
**职责范围：** iOS 客户端维护  
**证据等级：** A 表示源码调用链完整；B 表示局部能力或入口待确认；C 表示需要真机或网络复现。

本次审计从源码重新建立差异矩阵，审计输入采用当前源码、工程配置与测试入口。Android 独有能力作为对照依据，报告正文聚焦 iOS 待补齐项。服务端事实保持证据范围内的结论。

## 结论总表

| 优先级 | iOS 待补齐项 | Android 对照能力 | 证据等级 |
|---|---|---|---|
| P1 | 空教室隐藏忙碌教室 | 空教室设置页提供开关，默认开启 | A |
| P1 | 空教室最小空闲分钟阈值 | 空教室设置页提供分钟设置，默认 5 分钟 | A |
| P1 | 用户详情隐藏用户 | 用户详情提供隐藏/取消隐藏动作 | A |
| P1 | 隐藏用户可视化管理 | Android 提供隐藏用户列表、用户信息、恢复显示 | A |
| P1 | 屏蔽用户及其回复统一过滤 | Android 具备 `comment.replyUser.id` 过滤路径，当前由严格模式开关控制 | A |
| P2 | 底部页面顺序、主页、隐藏配置 | Android 提供页面编辑器 | A |
| P2 | 独立 BIT101 Web 页面入口 | Android 将通用 WebView 作为底部页面 | A |
| P2 | 网页成绩、课程等通用 Web 路由 | Android WebView 支持站内路由、网页成绩自动填充 | A |
| P2 | 大量评论的独立回复页 | Android 提供“更多回复”分页页 | A |
| P2 | 图片保存到系统相册 | Android 提供 ImageDownloader | A |
| P3 | 地图缩放倍率设置 | Android 提供缩放倍率 Slider 与持久化 | A |
| P3 | 关闭话廊横向滑动的设置项 | Android 提供“允许横向滑动”开关 | A |
| C | 初次 App 登录阶段的学校 SSO 互动验证 | Android 初次登录直接走学校 SSO 与短信总线 | C |

## P1：空教室高级过滤

### Android 现有能力

Android `FreeClassroomSettingPage` 提供：

- 当前校区
- 隐藏当前占用教室
- 空闲时段阈值

`FreeClassroomSearchViewModel` 使用 `hideBusyClassroom` 与 `freeMinutesThreshold` 参与教室结果计算。默认值位于 `SettingDataStore`：

- `freeClassroomHideBusyClassroom = true`
- `freeClassroomFreeMinutesThreshold = 5`

**源码证据**

- `../BIT101-Android/features/setting/src/main/java/cn/bit101/android/features/setting/page/FreeClassroomSettingPage.kt:108-124`
- `../BIT101-Android/features/setting/src/main/java/cn/bit101/android/features/setting/viewmodel/FreeClassroomViewModel.kt:16-62`
- `../BIT101-Android/features/schedule/src/main/java/cn/bit101/android/features/schedule/classroom/FreeClassroomSearchViewModel.kt:39-40,120-257`
- `../BIT101-Android/config/src/main/java/cn/bit101/android/config/datastore/SettingDataStore.kt:124-131`

### iOS 当前能力

iOS `FreeClassroomTabView` 提供：

- 校区选择
- 教学楼选择
- 刷新
- 节次筛选
- 按命中状态使用主题色与次级主题色区分

结果计算器当前围绕选中节次与当前空闲状态运行，设置模型待纳入 `hideBusyClassroom` 与 `freeMinutesThreshold` 字段。

**源码证据**

- `BIT101-iOS/Schedule/FreeClassroomViews.swift:25-131`
- `BIT101-iOS/Schedule/ClassroomAvailabilityCalculator.swift:16-116`
- `BIT101-iOS/Schedule/ScheduleCacheModels.swift:30-40,70-80`

### 影响

用户查看某栋楼时，iOS 仍展示当前忙碌教室。用户可以按节次命中筛选，页面待纳入 Android 的“过滤忙碌结果”和“忽略短暂空闲”两种工作流。

### 建议

将两个设置纳入 `AppDesignSystem` 统一设置行：

1. `隐藏当前占用教室`
2. `空闲时段阈值`

结果计算继续复用 iOS 现有 `ClassroomAvailabilityCalculator`，设置状态进入 `ScheduleCache`，结果页保留现有节次筛选与主题色标记。

## P1：用户隐藏管理

### Android 现有能力

- 用户详情显示“隐藏 / 已隐藏”按钮。
- 话廊设置显示隐藏用户数量。
- 隐藏用户列表加载用户昵称、签名、头像。
- 列表支持恢复显示。

**源码证据**

- `../BIT101-Android/features/user/src/main/java/cn/bit101/android/features/user/UserScreen.kt:64-123,247-311`
- `../BIT101-Android/features/user/src/main/java/cn/bit101/android/features/user/UserViewModel.kt:48-94`
- `../BIT101-Android/features/setting/src/main/java/cn/bit101/android/features/setting/page/GallerySettingPage.kt:47-77,101-228`

### iOS 当前能力

iOS 用户详情提供资料、关注、头像预览和用户帖子。隐藏用户入口位于话廊设置中的 UID 文本输入框，保存动作依靠提交文本触发。页面待增加：

- 用户详情快捷隐藏动作
- 已隐藏用户列表
- 昵称、头像、UID 展示
- 单项恢复显示动作
- 当前隐藏数量展示

**源码证据**

- `BIT101-iOS/Mine/MineRootView.swift:171-303`
- `BIT101-iOS/Settings/SettingsCommunityViews.swift:4-113`
- `BIT101-iOS/Settings/AppSettingsStore.swift:60-65,221-238`

### 建议

沿用现有 `galleryHiddenUserIDs` 数据结构，新增：

1. 用户详情中的隐藏/恢复按钮
2. 话廊设置中的隐藏用户列表页
3. 列表项的头像、昵称、UID、恢复动作
4. 空列表状态和恢复成功反馈

现有账号级偏好同步继续沿用，避免产生第二套屏蔽存储。

## P1：屏蔽用户及其回复

### Android 规则

Android 评论过滤器包含作者 UID 与回复目标 UID 两层判断，回复目标判断当前受严格模式开关控制：

```kotlin
!hiddenUIDs.contains(comment.user.id)
    && (!strictMode || !hiddenUIDs.contains(comment.replyUser.id))
```

用户屏蔽后，目标用户相关回复可以直接进入过滤范围。

**源码证据**

- `../BIT101-Android/features/poster/src/main/java/cn/bit101/android/features/poster/PosterViewModel.kt:93-100`

### iOS 当前规则

iOS `GalleryComment` 已有 `user` 与 `replyUser` 字段。过滤器当前检查：

- 评论作者 UID
- 匿名状态
- 子评论树递归

作者 UID、匿名状态和子评论递归保持现有语义，`replyUser.id` 规则待纳入。匿名内容保持独立设置语义。

**源码证据**

- `BIT101-iOS/Gallery/GalleryModels.swift:294-313`
- `BIT101-iOS/Gallery/GalleryService.swift:277-290`

### 建议

将 iOS 屏蔽规则定义为：

```swift
let authorHidden = hiddenIDs.contains(comment.user.id)
let replyTargetHidden = hiddenIDs.contains(comment.replyUser.id)
guard !authorHidden, !replyTargetHidden else {
    return nil
}
```

匿名内容继续由“隐藏匿名内容”开关单独控制。随后补充评论作者、回复目标、子评论递归三组纯逻辑测试。

## P2：底部页面编辑器

### Android 现有能力

Android `PagesSettingPage` 支持：

- 页面拖动排序
- 设置启动主页
- 隐藏底部页面
- 保存与恢复默认值

页面集合包含日程、地图、BIT101 Web、话廊、我的。

**源码证据**

- `../BIT101-Android/features/setting/src/main/java/cn/bit101/android/features/setting/page/PagesSettingPage.kt:55-208`
- `../BIT101-Android/config/src/main/java/cn/bit101/android/config/setting/base/PageSettings.kt:8-40`

### iOS 当前规则

iOS `AppTab.allCases` 固定返回日程、地图、话廊、成绩、我的，设置首页的页面编辑入口待增加。

**源码证据**

- `BIT101-iOS/Shell/AppShellView.swift:15-50`
- `BIT101-iOS/Settings/SettingsRootView.swift:17-49`

### 判断

这是 iOS 真实缺口，优先级低于空教室与用户隐藏。iOS 还拥有成绩 Tab，页面编辑器需要额外处理：

- 我的页面保留为必选入口
- 至少保留日程或成绩中的一个主入口
- 深链进入隐藏页面时自动恢复可见状态，或提供明确的临时导航
- Widget、Watch、Universal Link 的默认目标保持稳定

## P2：独立 BIT101 Web 入口

### Android 现有能力

Android 将 `BIT101Web` 纳入底部页面。WebView 具备：

- 网页成绩入口
- 网页课程入口
- BIT101 内部链接路由
- 文件选择器
- 页面加载进度
- 外部域名系统浏览器跳转

**源码证据**

- `../BIT101-Android/config/src/main/java/cn/bit101/android/config/setting/base/PageSettings.kt:8-40,68-78`
- `../BIT101-Android/features/web/src/main/java/cn/bit101/android/features/web/WebScreen.kt:48-205`

### iOS 当前规则

iOS `WKWebView` 入口嵌入话廊设置，页面地址固定为 `https://bit101.cn/gallery`。iOS 原生成绩和课程模块已覆盖核心网页流程，产品入口层的独立 Web 页面待增加。

**源码证据**

- `BIT101-iOS/Gallery/GalleryRootView.swift:62-160`
- `BIT101-iOS/Score/ScoreRootView.swift`
- `BIT101-iOS/Course/CourseRootView.swift`

### 判断

若产品要求双端入口结构一致，iOS 需要增加通用 Web 容器与 Web 页面入口。若产品优先原生体验，该项保持 P2 观察，避免引入第二套成绩、课程和社区流程。

## P2：大量回复独立分页页

### Android 现有能力

Android 帖子详情提供“更多回复”页面，子回复独立刷新、分页、排序和继续回复。

**源码证据**

- `../BIT101-Android/features/poster/src/main/java/cn/bit101/android/features/poster/PosterScreen.kt:166-316`
- `../BIT101-Android/features/poster/src/main/java/cn/bit101/android/features/poster/component/MoreCommentsPage.kt:196-260`

### iOS 当前规则

iOS 评论与子评论以内嵌线程展示，独立回复分页页面待增加。

**源码证据**

- `BIT101-iOS/Gallery/GalleryPosterDetailView.swift:127-190`
- `BIT101-iOS/Gallery/GalleryCommentViews.swift:1-190`
- `BIT101-iOS/Gallery/GalleryPosterDetailViewModel.swift:189-331`

### 建议

当子评论数量超过页面承载范围时，增加“更多回复”入口，进入独立分页页。评论服务层已经具备 `fetchComments(objectID:order:page:)`，新增页面可以复用现有请求与设计系统。

## P2：图片保存到系统相册

### Android 现有能力

Android `ImageDownloader` 提供图片下载、媒体库写入、成功提示和失败处理。

**源码证据**

- `../BIT101-Android/features/poster/src/main/java/cn/bit101/android/features/poster/ImageDownloader.kt:16-77`
- `../BIT101-Android/features/common/src/main/java/cn/bit101/android/features/common/component/image/ImageScreen.kt:67-213`

### iOS 当前规则

iOS 提供原图预览、渐进式高清加载、系统分享和缓存。“保存到照片”动作待增加。

**源码证据**

- `BIT101-iOS/Gallery/GalleryImageViewer.swift`
- `BIT101-iOS/Gallery/GalleryImageCache.swift`
- `BIT101-iOS/Shared/DesignSystem/AppDesignSystem.swift:307-317`

### 建议

在系统图片预览与帖子详情图片菜单中增加“保存到照片”，复用原图缓存，接入照片权限错误提示和 AppAlert 设计系统。

## P3：地图缩放倍率设置

Android 地图提供 1–5 倍 Slider，并通过 `MapSettings` 持久化。iOS MapKit 支持手势缩放与相机控制，页面的显式倍率设置项待增加。

**源码证据**

- Android：`../BIT101-Android/features/map/src/main/java/cn/bit101/android/features/map/MapScreen.kt:47-107`
- Android：`../BIT101-Android/features/map/src/main/java/cn/bit101/android/features/map/MapViewModel.kt:78-87`
- iOS：`BIT101-iOS/Map/CampusMapScreen.swift`
- iOS：`BIT101-iOS/Map/CampusNativeMapView.swift`

该项属于地图交互偏好，优先级低于业务能力缺口。

## P3：话廊横向滑动开关

Android `GallerySettings.allowHorizontalScroll` 提供横向切换开关。iOS 话廊当前直接启用 feed 与文章间的横向手势，设置页的同名开关待增加。

**源码证据**

- Android：`../BIT101-Android/config/src/main/java/cn/bit101/android/config/setting/base/GallerySettings.kt:10`
- Android：`../BIT101-Android/features/gallery/src/main/java/cn/bit101/android/features/gallery/GalleryScreen.kt`
- iOS：`BIT101-iOS/Gallery/GalleryRootView.swift:213-315`

该项适合与 iOS 手势误触反馈、页面切换偏好一起评估。

## C：初次 App 登录的学校 SSO 互动验证

### Android

Android `DefaultLoginRepo.login` 先调用 `SchoolLoginService.login`，学校 SSO 的短信或验证码由 `SmsCodeRequestHub` 直接交给全局 DialogHost。

### iOS

iOS `LoginService.login` 执行 BIT101 后端 WebVPN 校验与 fake-cookie 注册。学校 SSO 恢复在 `restoreSchoolSessionIfNeeded` 中按需触发，课表与成绩页面各自提供 challenge 输入 sheet。

**源码证据**

- Android：`../BIT101-Android/data/src/main/java/cn/bit101/android/data/repo/DefaultLoginRepo.kt:163-235`
- Android：`../BIT101-Android/api/src/main/java/cn/bit101/api/service/school/SchoolLoginService.kt`
- iOS：`BIT101-iOS/Login/LoginService.swift:68-134`
- iOS：`BIT101-iOS/Schedule/ScheduleViewModel+CourseSync.swift:132-195`

### 判断

两端学校验证时机存在差异。若产品要求“初次 App 登录阶段直接完成学校 SSO 互动验证”，iOS 对应流程待补齐；当前源码证据足以确认行为差异，真机登录场景用于确认优先级。

## 已有 iOS 能力（Android 对照项）

以下能力已在 iOS 形成实现，当前审计记录为对照结果：

- 原生成绩、可信成绩单、成绩缓存
- 课表多学期快照与替换保护
- 课程编辑、分享课表、导入课表
- 课程、考试、自定义日程系统日历导入与删除
- 课程地点地图标记、下一节课聚焦、系统导航
- Live Activity、通知兜底、Widget、Watch
- 结构化错误报告、诊断记录、用户错误过滤
- 帖子、评论、图片、举报、文章、消息、搜索
- 手动检查更新与自动检查开关

## iOS 补齐顺序

### 第一阶段

1. 空教室隐藏忙碌教室
2. 空教室最小空闲分钟阈值
3. 用户详情隐藏/恢复动作
4. 隐藏用户列表与恢复显示
5. 屏蔽用户及其回复统一过滤

### 第二阶段

1. 大量回复独立分页页
2. 图片保存到系统相册
3. 底部页面编辑器
4. 独立 BIT101 Web 入口评估

### 第三阶段

1. 地图缩放倍率设置
2. 话廊横向滑动开关
3. 初次 App 登录学校 SSO 互动验证的产品决策与真机验证

## 最终结论

iOS 当前相对 Android 的真实待补齐项集中在：空教室高级过滤、用户隐藏管理、屏蔽用户及其回复统一过滤、大量回复浏览、图片保存、页面编辑、独立 Web 入口，以及少量地图与手势偏好设置。

iOS 的成绩、课表编辑分享、系统日历、课程地图、通知组件、Watch、错误报告等核心能力已覆盖 Android 对照范围。
