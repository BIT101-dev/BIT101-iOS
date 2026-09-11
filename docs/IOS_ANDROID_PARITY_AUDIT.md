# iOS / Android 功能对照审计

## 审计状态

- 开始提交：`2f54df7`
- Android 基线：`6d79f18`
- 审计方式：Android 与 iOS git 提交、模块、服务、UI、测试入口交叉阅读
- 并行审计：4 个 Luna xhigh 请求，4 个有效结果已汇总
- 当前阶段：第一轮高置信度结果完成

## 记录格式

每项缺口记录以下信息：

- 功能名称
- Android commit 与文件证据
- iOS commit 与文件证据
- 当前 iOS 状态
- 缺口等级：高 / 中 / 低 / 待确认
- 建议验证入口

## 初始范围

Android 模块：`gallery`、`login`、`map`、`message`、`postedit`、`poster`、`report`、`schedule`、`setting`、`theme`、`user`、`versions`、`web`。

iOS 模块：`Course`、`Gallery`、`Login`、`Map`、`Mine`、`Paper`、`Schedule`、`Score`、`Settings`、`Shared`、`WatchSync`。

## 当前高关注方向

- Android 原生消息页面、消息角标与左右分页
- Android 日历导入、学校 SSO、短信验证、课表、DDL、成绩、可信成绩单
- Android 日志导出、版本更新、Web 页面入口
- iOS Widget、Watch、Live Activity、系统日历与设计系统的对应关系
- 两端测试脚本、真机验证、网络 Smoke、认证错误提示的覆盖差异

## 审计结果

### P1：社区认证刷新与重试（代码已补齐）

- Android：`f975d5d`、`5320289`、`f113265`；`DefaultAPIManager.kt:43-84`、`DefaultLoginRepo.kt:61-160`
- iOS：`CommunityAPIClient.swift:170-180` 将 401 映射为登录错误；教学中心在 `ScheduleServiceTeachingCenter.swift:53-125` 维护独立恢复
- `fd20fe6` 已加入统一社区 401 刷新、并发复用、失败分类和单次重试；`NetworkClientTests.swift` 增加 401 重试覆盖
- 验证：401、并发请求、刷新成功、刷新失败、登录态清理

### P1：学校 SSO 静默恢复短信入口（代码已补齐）

- Android：`86736e8`、`a910e33`、`69e0921`；`SchoolLoginService.kt`、`DefaultLoginRepo.kt`
- iOS 非 DDL 教学中心已有 `BITLoginAuthenticationChallenge` 与 `AppSMSVerificationSheet`，课表、考试、空教室、成绩链路使用该机制
- iOS App 登录页使用 `LoginService.login()` 的 `webVPNVerify` 流程
- `e2de22d` 已为 `LoginService.restoreSchoolSessionIfNeeded()` → `BIT101APIClient.loginSchool()` 的 CAS 会话恢复路径接入学校 SSO 短信回调
- DDL 页面已有 `SchoolSMSCodeRequest` 与 `AppSchoolSMSVerificationSheet`
- 真机触发恢复场景、输入验证码、完成 CAS 回流仍属于验证项

### P1：DDL Smoke 真实短信闭环

- iOS Smoke 当前使用 `smsDeliveryMode: .preflight`
- 已覆盖二次验证页面识别、手机号接口、订阅地址和 ICS
- `sendSmsCode`、`checkToken`、`smsLogin` 表单、错误码回流、正确码回流、DDL 页面恢复采用真机手动验证
- `schoolSMSCoverage=preflight_only` 已写入 Smoke 报告

### P1：帖子编辑

- Android：`features/poster/PosterScreen.kt:357-364`、`features/postedit/PostEditScreen.kt:446-530`、`PostersApiService.kt:35-39`
- iOS：`GalleryPosterActionViews.swift:40-46`、`GalleryService.swift:288-300` 当前覆盖删除、详情和创建；帖子更新接口与编辑入口待补齐
- 验证：本人帖子标题、正文、图片、标签、声明、匿名、可见性修改后重新加载

### P1：帖子与评论举报

- Android：`ManageRepo.kt`、`ReportScreen.kt`、`NavDest.Report`、`0cdfec9`
- iOS：话题操作覆盖分享、删除、复制；社区内容举报路由与 Service 待补齐
- 验证：帖子举报、评论举报、举报类型加载、提交反馈、失败提示

### P1：他人主页关注

- Android：`UserScreen.kt:113-124、299-301`、`UserApiService.kt:54-57`
- iOS：`MineService.swift` 覆盖资料、粉丝、关注列表；他人主页资料卡缺少关注动作与对应请求
- 验证：关注、取消关注、重复点击、粉丝数、关注列表

### P1：话廊隐藏用户与严格模式

- Android：`2e8fe88`、`ee29b23`；`GallerySettingPage.kt:45-80、100-180`、`GallerySettings.kt`
- iOS：设置与服务层当前覆盖机器人帖子过滤；用户 UID 列表、匿名用户开关、严格模式待补齐
- 验证：用户主页隐藏、帖子流、搜索、评论、回复、重启持久化

### P1：评论图片、删除与复制

- Android：`CommentBottomSheet.kt:81-84、227-236`、`PosterScreen.kt:339-384`、`ReactionApiService.kt`
- iOS：`GalleryCommentViews.swift:134-205` 覆盖点赞、回复、文本和匿名；`imageMids` 固定为空数组，评论删除和复制入口待补齐
- 验证：帖子、课程、文章评论图片上传，评论删除，复制，失败重试

### P1：BIT101 内置网页入口

- Android：`NavDest.Web`、`WebScreen.kt:48-166`、`PageShowOnNav.BIT101Web`
- iOS：底部页面固定为日程、地图、话廊、成绩、我的；当前 WebKit 仅用于设置页网站数据清理
- WebView 登录态注入、网页成绩自动填充、站内路由、外链处理待补齐

### P2：底部页面自定义

- Android：`PageSettings.kt:81-96`、`PagesSettingPage.kt:54-87`、`ef7246c`
- iOS：`AppTab.allCases` 固定页面集合和顺序，`SettingsRoute` 缺少页面设置入口
- 验证：页面排序、隐藏、主页选择、重启持久化

### P2：粉丝与关注列表用户导航

- Android：`FollowPage.kt:181-186`
- iOS：`MineRootView.swift:381-450` 的用户行采用静态展示，用户主页导航待补齐

### P2：话廊日志导出

- Android：`AboutPage.kt`、`LogExporter.kt`
- iOS：`ErrorReportSupport.swift` 覆盖错误诊断提交；关于页提供缓存清理和数据删除，通用日志导出入口待补齐

### P2：单条日程加入系统日历

- Android：`ScheduleUtils.kt` 支持课程、考试、自定义日程逐条导入
- iOS：`ScheduleSystemCalendarManager` 面向当前学期批量导入课程；考试、自定义日程详情缺少对应单条入口

### P2：DDL 网络环境适配

- Android：`90b6fc3`、`SchoolLexueService.kt:30-39` 根据 WebVPN 和校园网地址切换
- iOS：`ScheduleService.swift:333-337` 使用固定 `lexueBaseURL`；课表链路具备 WebVPN/直连回退，DDL 链路采用固定直连地址
- 验证：校外网络、校园网、WebVPN DNS 异常、直连回退、登录态恢复

### P2：话廊横向滑动设置

- Android：`128b339`、`GallerySettingPage.kt:80-86`
- iOS：`GalleryRootView` 固定启用横向手势，设置层缺少开关

### P2：空教室过滤设置

- Android：`128b339`、`FreeClassroomSettingPage.kt:108-124`
- iOS：`FreeClassroomViews.swift` 已有校区、教学楼、节次筛选；隐藏非空教室和空闲分钟阈值待补齐

### P2：更新检查控制

- Android：`AboutPage.kt:80-93` 提供手动检查与自动检查控制
- iOS：`AppUpdateChecker.swift:100-122` 执行自动检查，关于页缺少对应控制项

### Smoke 与测试覆盖差异

- iOS Smoke 当前覆盖网络读链路，写操作、帖子编辑、举报、设置修改采用独立人工验证
- DDL 短信报告保持 `schoolSMSCoverage=preflight_only`
- iOS `LoginLogicTests.swift`、`RefactorSafetyTests.swift` 覆盖解析与状态机；手机号获取、短信发送、校验、CAS 表单提交缺少 mock HTTP 闭环测试
- iOS 缺少发帖、编辑、举报、隐藏用户、页面配置、更新设置、日志导出的 UI 回归入口
- Android 侧已有 `SmsCodeRequestHubTest`、`DefaultLoginRepoTest`、`SchoolCookieStoreTest`

### API 能力差异待确认

Android API 侧已确认以下接口，iOS 当前 Service 检索结果待补齐或待确认 UI 使用范围：

- `POST /user/mail_verify`
- `POST /user/login`
- `GET /courses/upload/url`
- `POST /courses/upload/log`
- `PUT /papers/{id}`
- `DELETE /papers/{id}`
- `PUT /posters/{id}`
- `DELETE /reaction/comments/{id}`
- `POST /reaction/stay`

证据：`UserApiService.kt`、`CoursesApiService.kt`、`PapersApiService.kt`、`PostersApiService.kt`、`ReactionApiService.kt`。

## iOS 已确认优势

- 成绩与可信成绩单：`ScoreService.swift` 原生 challenge、短信认证、分页图片下载
- iCloud 与跨设备：`ScheduleCloudSyncManager.swift`、`ExperimentalPreferenceCloudSync.swift`、CloudKit、iCloud Key-Value Store
- Widget、锁屏组件、Live Activity、Apple Watch、Smart Stack
- 课表、考试、学期、首周日期、空教室：两端核心接口基本对齐
- DDL、课程、文章、话廊编辑器与草稿恢复
- 消息中心、未读数、消息分类与入口角标
- 统一设计系统：`AppDesignSystem.swift`

## 第一轮优先级

1. DDL 真实短信闭环
2. 帖子编辑、举报、关注、隐藏用户、评论媒体与操作菜单
3. BIT101 内置网页入口
4. DDL WebVPN / 直连策略
5. 页面自定义、日志导出、单条日历导入

## 待人工确认

- BIT101 内置 Web 页面是否属于当前产品必需功能
- iOS 帖子编辑与举报的产品优先级
- 话廊屏蔽设置是否要求跨端一致
- 空教室阈值是否纳入 iOS 设计系统
- 更新检查是否需要用户开关
- 地图缩放设置是否形成独立功能差异
