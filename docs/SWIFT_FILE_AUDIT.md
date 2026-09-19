# Swift 文件人工审计记录

**启动日期：** 2026-09-19  
**范围：** BIT101-iOS、Widget、Watch、测试 Swift 文件  
**方法：** 每个 agent 负责 3–8 个强相关文件，逐个直接通读全文；agent 在自身文件范围内直接修正，跨文件事项交给主 agent。

## 审计规则

- 直接阅读全文，禁止脚本摘要替代阅读。
- 检查死代码、过时注释、设计系统令牌、原生 Swift/SwiftUI 实现、Apple 桥接边界、无障碍和测试覆盖。
- WebKit、HTML、JavaScript、UIKit、UIHostingController、UIViewRepresentable、第三方容器逐项判断必要性。
- 完成一个 agent 后关闭，再启动新的独立上下文。
- 同时运行的 agent 数量保持在 4 个以内。

## 第一轮已完成

### 设计系统公共组件组

文件：

- `Shared/DesignSystem/AppDesignSystem.swift`
- `Shared/DesignSystem/AppCommentComponents.swift`
- `Shared/DesignSystem/AppAvatarComponents.swift`
- `Shared/DesignSystem/AppTagComponents.swift`
- `Shared/DesignSystem/AppContentControlComponents.swift`
- `Shared/DesignSystem/AppRefreshStatusComponents.swift`
- `Shared/DesignSystem/AppVerificationComponents.swift`

agent 结论与改动：

- 公共令牌与组件边界清晰。
- `UIFont.TextStyle`、`Color(uiColor:)` 属于 Apple 原生桥接，继续保留。
- `CachedRemoteImage` 的缓存职责成立，继续保留。
- 详情按钮、头像、评论、搜索、刷新、验证码控件补齐触控区域或无障碍语义。
- 标签未选中背景统一使用设计令牌。
- 验证码长度令牌与输入清洗逻辑完成收敛。

主 agent 交叉事项：反馈封装与系统 `sensoryFeedback` 的最低系统版本评估；语义头像标签的调用方覆盖。

### 课表日历组

文件：

- `Schedule/ScheduleCalendarViews.swift`
- `Schedule/ScheduleLinearCalendarViews.swift`
- `Schedule/ScheduleCourseCardViews.swift`
- `Schedule/ScheduleCalendarModels.swift`
- `Schedule/ScheduleWeekSliderView.swift`
- `Schedule/ScheduleEntryDetailView.swift`

agent 结论与改动：

- 课表网格和时间轴主体使用 SwiftUI。
- 空白区域上下文菜单、系统分享、线性时间轴缩放、课程双文字块均有明确 Apple 原生能力需求。
- 周次滑块移除手写异步定位，改用 SwiftUI 原生 `scrollPosition` 与 `viewAligned`。
- 时间分钟转换、背景层排序、同起始节次稳定排序完成收敛。
- 日期头部、星期头部、节次行、课程卡片补充无障碍语义。
- 自定义日程详情操作区结构完成修正。

主 agent 交叉事项：缩放锚点和边界测试、课程条目归一化顺序、课程颜色对比度、课程合并与日历删除回调。

## 第二轮进行中

### 话廊详情组已完成

文件：

- `Gallery/GalleryPosterDetailView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`
- `Gallery/GalleryCommentViews.swift`
- `Gallery/GalleryPosterActionViews.swift`
- `Gallery/GalleryImageViewer.swift`
- `Gallery/GalleryImageCache.swift`

agent 结论与改动：

- 详情、评论、举报、Quick Look、缓存均使用 SwiftUI 或 Apple 原生桥接。
- Quick Look 保留，用于低清预览到高清文件的原地刷新。
- UIImage、NSCache、UniformTypeIdentifiers 保留，用于图片解码、变体缓存、类型识别。
- 详情失败态、匿名身份隐藏、图片无障碍、删除确认、上传生命周期、举报状态收敛完成改动。
- 零字节缓存恢复、HEIF 类型支持、嵌套回复展示完成改动。

主 agent 交叉事项：`GalleryFeedViews.swift` 的匿名帖子身份展示、`GalleryPosterImagesView` 逐图标签、评论图片上传服务注入、高清回退与多级回复测试。

后续 agent 的执行范围锁定为源码全文阅读、代码审查和自身文件内修改；编译、装机、真机运行、截图和测试执行由主 agent统一控制。

### 话廊详情组

- `Gallery/GalleryPosterDetailView.swift`
- `Gallery/GalleryPosterDetailViewModel.swift`
- `Gallery/GalleryCommentViews.swift`
- `Gallery/GalleryPosterActionViews.swift`
- `Gallery/GalleryImageViewer.swift`
- `Gallery/GalleryImageCache.swift`

### 设置组

- `Settings/AppSettingsStore.swift`
- `Settings/SettingsCommunityViews.swift`
- `Settings/SettingsScheduleViews.swift`
- `Settings/SettingsScheduleSheets.swift`
- `Settings/SettingsDDLViews.swift`
- `Settings/SettingsAppearanceViews.swift`
- `Settings/SettingsSupportViews.swift`

### 登录组

- `Login/LoginService.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginViews.swift`
- `Login/LoginSessionState.swift`
- `Login/LoginStorage.swift`
- `Login/SchoolLoginHTMLParser.swift`

### 成绩组

- `Score/ScoreRootView.swift`
- `Score/ScoreViewModels.swift`
- `Score/ScoreService.swift`
- `Score/ScoreModels.swift`
- `Score/ScorePresentationModels.swift`
- `Score/ScoreFilterViews.swift`

## 后续批次

## 第三轮进行中

### Course 课程组

- `Course/CourseCommentViews.swift`
- `Course/CourseDetailView.swift`
- `Course/CourseDetailViewModel.swift`
- `Course/CourseHistoryGradesViews.swift`
- `Course/CourseLookup.swift`
- `Course/CourseModels.swift`
- `Course/CourseRootView.swift`
- `Course/CourseService.swift`

### Paper 文章组

- `Paper/PaperCommentViews.swift`
- `Paper/PaperComposerViews.swift`
- `Paper/PaperDetailView.swift`
- `Paper/PaperModels.swift`
- `Paper/PaperRootView.swift`
- `Paper/PaperSearchViews.swift`
- `Paper/PaperService.swift`

### Map 与 Mine 基础组

- `Map/CampusLocationController.swift`
- `Map/CampusMapLocations.swift`
- `Map/CampusMapScreen.swift`
- `Map/CampusNativeMapView.swift`
- `Map/UpcomingCourseMapResolver.swift`
- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineServicing.swift`

### Login 认证组

- `Login/LoginService.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginViews.swift`
- `Login/LoginSessionState.swift`
- `Login/LoginStorage.swift`
- `Login/SchoolLoginHTMLParser.swift`

## 第三轮已完成：Course 课程组

文件：

- `Course/CourseCommentViews.swift`
- `Course/CourseDetailView.swift`
- `Course/CourseDetailViewModel.swift`
- `Course/CourseHistoryGradesViews.swift`
- `Course/CourseLookup.swift`
- `Course/CourseModels.swift`
- `Course/CourseRootView.swift`
- `Course/CourseService.swift`

agent 结论与改动：

- ShareLink、openURL、Charts 等路径保持 Apple 原生实现。
- 评论图片、评分按钮、历史成绩趋势图补充无障碍语义和触控区域。
- 回复匿名用户时过滤无效 `replyUID`。
- 课程检索增加课程号、课程名交集保护。
- 清理过时注释与未参与页面流转的历史审查 fixture 模型。
- 历史成绩接口课程号使用 URL path component 编码。

主 agent 交叉事项：详情加载状态字段、课程消歧页面、历史 fixture 外部引用、评论图片尺寸令牌、历史成绩双轴展示决策。

## 第三轮已完成：Map 与 Mine 基础组

文件：

- `Map/CampusLocationController.swift`
- `Map/CampusMapLocations.swift`
- `Map/CampusMapScreen.swift`
- `Map/CampusNativeMapView.swift`
- `Map/UpcomingCourseMapResolver.swift`
- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineServicing.swift`

agent 结论与改动：

- MapKit 与 CoreLocation 桥接均有明确系统能力职责。
- 定位权限状态与地图定位职责完成收敛。
- 校区、楼号、操场推断与空白清洗完成补强。
- 地图权限拒绝状态、课程目标监听、定位失败反馈、地图标记无障碍完成改动。
- Mine 数据模型、服务协议、分页接口保持清晰。

主 agent 交叉事项：MapNotice 的系统设置按钮、UserProfileViewModel 已关注状态同步。

## 第三轮已完成：Paper 文章组

文件：

- `Paper/PaperCommentViews.swift`
- `Paper/PaperComposerViews.swift`
- `Paper/PaperDetailView.swift`
- `Paper/PaperModels.swift`
- `Paper/PaperRootView.swift`
- `Paper/PaperSearchViews.swift`
- `Paper/PaperService.swift`

agent 结论与改动：

- 文章评论、文章正文、编辑器和列表均保持 SwiftUI 与系统富文本桥接边界。
- 匿名评论、匿名文章作者的头像和昵称保护完成改动。
- 正文加载/失败状态、文章图片占位、富文本链接校验、纯文本 HTML 转义完成改动。
- TextEditor 占位与无障碍标签、文章卡片按钮语义、Typography 和间距完成统一。
- 文章评论匿名字段收敛为必填布尔值，过时文件头注释与无效字段完成清理。

主 agent 交叉事项：PaperViewModel 大正文 HTML 后台解析、编辑器块级富文本保留、文章卡片 Button 化、回复目标匿名模型、文章搜索入口状态。

## 第三轮已完成：Schedule 服务组

文件：

- `Schedule/ScheduleService.swift`
- `Schedule/ScheduleServiceDTOs.swift`
- `Schedule/ScheduleServiceTransport.swift`
- `Schedule/ScheduleServiceAuthentication.swift`
- `Schedule/ScheduleServiceLexue.swift`
- `Schedule/ScheduleServiceTeachingCenter.swift`
- `Schedule/ScheduleServiceSupport.swift`

agent 结论与改动：

- 课表错误归并、周次归一化、DTO 字段映射保持清晰。
- 学校业务响应、课表未发布、直连/WebVPN 路线切换、DNS/超时/证书错误识别完成收敛。
- 学校认证增加 Cookie 写入确认与暂态网络重试。
- 乐学 ICS 内容校验、登录 HTML 路线重试、preflight 提前结束和直连偏好记录完成改动。
- WebVPN 与校园网直连故障回退路径完成改动。

主 agent 交叉事项：教学中心包装调用覆盖、Login/Challenge/Cookie/ICS 契约、课程响应收窄逻辑。

## 第三轮已完成：Settings 设置组

文件：

- `Settings/AppSettingsStore.swift`
- `Settings/SettingsCommunityViews.swift`
- `Settings/SettingsScheduleViews.swift`
- `Settings/SettingsScheduleSheets.swift`
- `Settings/SettingsDDLViews.swift`
- `Settings/SettingsAppearanceViews.swift`
- `Settings/SettingsSupportViews.swift`

agent 结论与改动：

- 遇到未知主题值时回退系统主题，同时保留其余设置数据。
- 外观设置注释、课表设置尾部注释完成清理。
- 设置数据持久化、账号隔离、错误反馈和设计令牌边界保持清晰。

主 agent 交叉事项：ScheduleCacheStore 与设置仓库账号标识编码统一、SettingsAccountViews 提交中状态、启动公告与自动更新开关的设备级范围。

## 第三轮已完成：Score 成绩组

文件：

- `Score/ScoreRootView.swift`
- `Score/ScoreViewModels.swift`
- `Score/ScoreService.swift`
- `Score/ScoreModels.swift`
- `Score/ScorePresentationModels.swift`
- `Score/ScoreFilterViews.swift`

agent 结论与改动：

- 成绩缓存同步避开进行中的刷新与短信认证。
- 修复简略数据缺少筛选项导致列表永久空白。
- 学期、课程字段空白处理、成绩行唯一标识和缓存学期匹配完成统一。
- 可信成绩单图片增加同源下载限制。
- 筛选页、成绩单页数和动态字体补充无障碍语义。
- 清理过时 WebVPN 与旧分页说明。

主 agent 交叉事项：空成绩缓存策略、学号 trim 统一、AppFixedColumnRow 大字体适配、敏感下载重定向策略。

## 第三轮已完成：Shared Infrastructure 组

文件：

- `Shared/Infrastructure/AccountScopedCodableStore.swift`
- `Shared/Infrastructure/ErrorReportSupport.swift`
- `Shared/Infrastructure/NetworkDiagnostics.swift`
- `Shared/Infrastructure/ReleaseNetworkSmoke.swift`
- `Shared/Infrastructure/ReleaseNetworkSmokeModels.swift`
- `Shared/Infrastructure/AppUpdateChecker.swift`
- `Shared/Infrastructure/EmergencyUpdateChecker.swift`

agent 结论与改动：

- App Store URL 与紧急更新跳转安全校验增强。
- Bearer、认证请求头等敏感字段脱敏范围补齐。
- 弹窗等待并发、诊断记录 Sendable、诊断错误信息保护完成修正。
- smoke 原始响应清理、文件保护、runID 校验完成收敛。
- 学校 smoke 补齐当前学期探针，课程历史部分失败状态正确传递。
- 无效网络状态读取与过时注释完成清理。

主 agent 交叉事项：HTTPClient 诊断记录调用链、CourseService 原始响应保留路径、App Group 文件保护与扩展读取流程。

## 第三轮已完成：Networking 组

文件：

- `Shared/Networking/BITLoginChallengeSupport.swift`
- `Shared/Networking/CommunityAPIClient.swift`
- `Shared/Networking/HTTPClient.swift`
- `Shared/Networking/SecureURLTransport.swift`
- `Login/BIT101APIClient.swift`

agent 结论与改动：

- challenge 轮询增加无效超时与间隔保护。
- 401 刷新使用原始 Cookie，降低并发重复刷新风险。
- HTTP 诊断记录覆盖无效响应与非 2xx 状态错误。
- URLSession 统一支持 HTTPS 升级，跨源重定向清理认证头并限制非安全方法。
- 学校 SSO 重定向增加 HTTPS、域名白名单、Location 校验和 8 次上限。
- 登录响应错误解析复用 `HTTPClient.errorMessage`。

主 agent 交叉事项：NetworkDiagnosticStore 敏感字段脱敏、LoginService.login 凭据更新原子性。

## 第三轮已完成：Schedule ViewModel 组

文件：

- `Schedule/ScheduleViewModel.swift`
- `Schedule/ScheduleViewModel+Classroom.swift`
- `Schedule/ScheduleViewModel+CourseEditing.swift`
- `Schedule/ScheduleViewModel+CourseSync.swift`
- `Schedule/ScheduleViewModel+DDL.swift`
- `Schedule/ScheduleViewModel+Preferences.swift`
- `Schedule/ScheduleCacheStore.swift`

agent 结论与改动：

- 增加账号代际校验，隔离旧请求回写状态。
- 课程同步、学期列表、DDL、短信验证并发状态完成修正。
- 空教室取消时 loading 状态、空响应课表元数据、非当前学期同步时间完成修正。
- 分享课表周次定位与时间表输入校验完成收紧。
- DDL 时间窗口范围、缓存编解码器生命周期、通知账号过滤完成收敛。

主 agent 交叉事项：CloudKit 与 Live Activity 异步任务的账号切换隔离。

## 第三轮已完成：Schedule 模型与编辑组

文件：

- `Schedule/ScheduleCoreModels.swift`
- `Schedule/ScheduleCacheModels.swift`
- `Schedule/ScheduleDateCodecs.swift`
- `Schedule/ScheduleSharePayloads.swift`
- `Schedule/ScheduleCourseEditor.swift`
- `Schedule/ScheduleEditorViews.swift`
- `Schedule/ScheduleEditingSupport.swift`

agent 结论与改动：

- 缓存迁移补齐部分学期缓存，首周日期校验增强。
- 时间解析支持 `24:00` 日界点。
- 分享载荷增加字段数量校验、编码对称性和错误映射。
- 课程编辑增加周次校验、单次调课保护和同日调课保护。
- 缓存文档注释移动到正确文件。
- 编辑页与调休页的设计令牌、公共组件和原生 Swift 结构保持清晰。

主 agent 交叉事项：导入时间语义、Shared 日期编码约定、课表导入与调休日目标日期校验。

## 第三轮已完成：Shared 基础组件组

文件：

- `Shared/Infrastructure/AppAlert.swift`
- `Shared/Infrastructure/AppDateText.swift`
- `Shared/Infrastructure/AppDeepLinkCoordinator.swift`
- `Shared/Infrastructure/AppFileDirectories.swift`
- `Shared/Infrastructure/AppStateComponents.swift`
- `Shared/Infrastructure/AppURL.swift`

agent 结论与改动：

- 诊断与恢复链接状态完成统一。
- 日期格式化器改为调用内创建，增强并发安全，中文相对时间统一。
- 深链路径结构与正整数 ID 校验收紧。
- Application Support URL 缓存，内置 URL 增加 scheme 校验。
- 状态组件保持原生 SwiftUI 与设计令牌结构。

主 agent 交叉事项：AppURL.required 调用参数、深链生产方路径约定、日期相对文案区域设置。

## 第三轮已完成：Widget、Watch 与共享快照组

文件：

- `Shared/ScheduleSharedLiveActivity.swift`
- `Shared/ScheduleSharedOccurrence.swift`
- `Shared/ScheduleSharedSnapshot.swift`
- `Schedule/ScheduleWidgetSupport.swift`
- `WatchSync/WatchScheduleSyncManager.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgets.swift`
- `BIT101Watch/WatchScheduleRootView.swift`

agent 结论与改动：

- ActivityKit、WidgetKit、WatchConnectivity 属于 Apple 原生平台能力，桥接保持。
- 共享 occurrence 增加日期、时间、周次、星期和时段校验，排序稳定性增强。
- Widget 时间线使用 entry 时间，跨午夜刷新，圆形组件使用原生动态计时。
- WatchConnectivity 增加激活期间待发送快照缓存。
- 快照注释和跨 target 设计令牌引用完成整理。

主 agent 交叉事项：ScheduleLiveActivityManager 重复时段字典、Watch Widget 日期文案、Watch 首次同步重复请求、External 令牌边界。

## 第三轮已完成：Schedule 协调与日历组

文件：

- `Schedule/ScheduleAcademicCourseResolver.swift`
- `Schedule/ScheduleClassroomCoordinator.swift`
- `Schedule/ScheduleCourseEntries.swift`
- `Schedule/ScheduleCourseSyncCoordinator.swift`
- `Schedule/ScheduleDDLEditor.swift`
- `Schedule/ScheduleICSParser.swift`
- `Schedule/ScheduleSystemCalendarManager.swift`

agent 结论与改动：

- 空教室请求增加认证前、认证后和超时前的取消检查。
- 考试与自定义日程时间解析增加严格时分校验。
- DDL 合并保留完成状态，并保持新增、更新、合并后的稳定排序。
- ICS 解析支持折行、大小写属性、TZID、严格日期、转义和 UID 去重。
- EventKit 权限、日期边界、批次排序、标记匹配和取消传播完成增强，死代码完成清理。

主 agent 交叉事项：课程日历删除学期参数、课表条目裁剪时的背景层、空教室任务持有、短信 continuation 校验。

## 第三轮已完成：测试文件组

文件：

- `BIT101-iOSTests/InfrastructureTests.swift`
- `BIT101-iOSTests/ExtendedInfrastructureTests.swift`
- `BIT101-iOSTests/NetworkClientTests.swift`
- `BIT101-iOSTests/ReleaseNetworkSmokeTests.swift`
- `BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift`
- `BIT101-iOSTests/ErrorReportAndSchedulePolicyTests.swift`
- `BIT101-iOSTests/AppUpdateCheckerTests.swift`

agent 结论与改动：

- 登录启动、账号隔离、分页、成绩刷新、课表协议、网络认证、脱敏、DDL、课程替换、更新检查覆盖进一步补齐。
- Release smoke 增加 scope 与登录探针校验。
- iCloud smoke 增加成绩与设置时间戳校验，以及多协调状态保护。
- 测试异步任务清理和共享 UserDefaults 隔离完成加强。

主 agent 交叉事项：缓存账号标识统一、课程历史 fixture 元数据校验、Release smoke 业务语义校验、测试 capture 边界。

## 第三轮已完成：Login 认证组

文件：

- `Login/LoginService.swift`
- `Login/LoginViewModel.swift`
- `Login/LoginViews.swift`
- `Login/LoginSessionState.swift`
- `Login/LoginStorage.swift`
- `Login/SchoolLoginHTMLParser.swift`

agent 结论与改动：

- 会话 Cookie 标准化、状态恢复、取消处理、密码清理和 Keychain 迁移完成审计。
- 登录输入框补充无障碍标签与提示，设计系统字体和颜色完成统一。
- 学校登录 HTML 解析支持隐藏 input、属性顺序变化和实体解码，保留 HTTPS 同源校验。
- Login Service、Storage、Session State 的职责边界保持清晰。

主 agent 交叉事项：学校 SSO 静默恢复接入 `LoginServicing`、原始密码访问器收敛、学校 CAS 短信界面闭环、`loginSchool` 的 3xx 判定。

按相同粒度继续覆盖：

- Course 课程服务与详情数据组
- Paper 文章服务与详情数据组
- Map 地图与定位组
- Mine 用户资料与用户详情组
- Schedule 服务、ViewModel、缓存、CloudKit 组
- Shared Infrastructure 与 Networking 组
- Widget、Watch、测试组

每个批次完成后，将 agent 结论、直接改动和主 agent 交叉事项追加到本文件。

## 第三轮已完成：根路由与协议组

文件：

- `Gallery/GalleryRootView.swift`
- `Login/LoginCrypto.swift`
- `Login/LoginServicing.swift`
- `Schedule/ScheduleModels.swift`
- `Schedule/ScheduleRootView.swift`
- `Schedule/ScheduleServicing.swift`

agent 结论与改动：

- WebView 模式保留文章深链原生路由，帖子详情改为服务协议注入。
- Cookie 注入改用 JSON 编码，WebView 错误页间距纳入设计令牌。
- CommonCrypto、CryptoKit、Security 属于原生安全实现，AES 密钥长度校验增强。
- 登录协议移除 `savedPassword`，收窄敏感数据边界。
- 清理课表模型过时尾注，根页面底部 inset 使用设计系统令牌。

主 agent 交叉事项：LoginService.savedPassword 调用点、TeachingCenter 登录服务注入、AppShell/Paper 深链消费链。

## 第三轮已完成：登录与交互测试组

文件：

- `BIT101-iOSTests/CampusMapLocationTests.swift`
- `BIT101-iOSTests/ListViewModelTests.swift`
- `BIT101-iOSTests/LoginLogicTests.swift`
- `BIT101-iOSTests/ScheduleICSParserTests.swift`
- `BIT101-iOSTests/ExtendedLoginTests.swift`

agent 结论与改动：

- 登录认证页 fixture 改用真实退出登录标记。
- 移除死编译条件，补充登录取消、账号身份、启动调用次数断言。
- 补充课程重试、文章搜索取消、空搜索清理断言。
- 加强地图同名地点经纬度隔离断言。
- ICS fixture 事件读取增加边界保护。

主 agent 交叉事项：ScheduleCacheStore、TeachingCenterSessionState、ScheduleViewModel 的跨账号缓存与在途请求专项覆盖。

## 第三轮已完成：Schedule 小型解析组

文件：

- `Schedule/AcademicTermPolicy.swift`
- `Schedule/ClassroomSorting.swift`
- `Schedule/ScheduleStringParsing.swift`

agent 结论与改动：

- 学期规则缓存改为不可变静态值，边界规则与教学阶段规则完成核对。
- 空教室排序增加原始 ID 兜底，提升同本地化结果下的确定性。
- 可选捕获组缺少文本时返回空字符串，保持捕获组位置稳定。

主 agent 交叉事项：`preferredTerm`、`nextBoundary`、`captureGroups` 调用关系。

## 第三轮已完成：诊断、网络与账号交叉组

文件：

- `Shared/Infrastructure/ErrorReportSupport.swift`
- `Shared/Infrastructure/NetworkDiagnostics.swift`
- `Shared/Networking/HTTPClient.swift`
- `Login/LoginService.swift`
- `Settings/AppSettingsStore.swift`

agent 结论与改动：

- 强制脱敏字段扩展到 session、API Key、secret、验证码、CAS 临时字段。
- 网络诊断 actor 串行保护、学校外链清理、报告提交脱敏边界完成核对。
- HTTP 状态码、401 记录和服务端错误消息链路保持清晰。
- 登录开始阶段移除会话清空，成功认证后再写入新登录状态。
- 无账号历史设置迁移延迟，默认账号标识统一。

主 agent 交叉事项：Keychain 保存事务化、登录/学校会话原子切换、诊断采集阶段脱敏策略、错误消息展示长度。

## 更新时间行高问题已修正

- 原因：公共 `AppRefreshStatusRow` 使用 `touchTarget` 作为最小高度，更新时间 List 行因此增高。
- 修正：移除更新时间行的最小高度约束，保留按钮触控区域和页面自然行高。
- 影响范围：课表、DDL、成绩、空教室等复用页面。
- 状态：源码修正完成，等待主 agent 后续统一验证。

## 待核查问题

### 更新时间 List 行高变化

- 用户反馈：多个页面的“更新时间”列表行高度较基线变高。
- 记录时间：2026-09-19。
- 核查范围：`AppRefreshStatusComponents.swift`、所有使用 `AppRefreshStatusRow` 的页面、近期 agent 改动。
- 核查方法：对照提交 `9a18c1e`，检查字体令牌、垂直内边距、List row insets、Section 布局和动态字体行为。
- 处理状态：等待当前批次 agent 完成后由主 agent 复核。

## 第三轮已完成：CloudKit 同步组

文件：

- `Schedule/ScheduleCloudSyncManager.swift`

agent 结论与改动：

- 固定 CloudKit 操作账号上下文，降低账号切换串账号风险。
- 账号切换、关闭同步、本地缓存变化时丢弃过期异步操作。
- 上传前比较远端时间戳，增加 `serverRecordChanged` 冲突重取与单次重试。
- record type、studentID、updatedAt、payload 校验增强。
- 初次上传回写本地时间戳，错误日志内容收敛。

主 agent 交叉事项：缓存时间戳精度、账号标识迁移、CloudKit 生命周期调用、字段合并策略、payload 容量。

## 第三轮已完成：剩余基础组件组

文件：

- `Score/ScoreServicing.swift`
- `Shared/Infrastructure/ExperimentalPreferenceCloudSync.swift`
- `Shared/Infrastructure/HorizontalSwitchGesture.swift`
- `Shared/Infrastructure/KeyboardDismissSupport.swift`
- `Shared/Infrastructure/PagedItemsState.swift`
- `Shared/Infrastructure/TaskCancellation.swift`

agent 结论与改动：

- KVS 待处理同步域合并、开关关闭和账号切换清理完成增强。
- 键盘 UIKit 组件纳入 MainActor 并发隔离。
- 取消错误遍历完整底层错误链，并加入 NSError 环检测。
- Score 协议、横向手势、分页状态保持清晰。

主 agent 交叉事项：KVS 容量与分片、分页取消路径 loading 清理、ScoreService actor 隔离与 Sendable。

## 第三轮已完成：课表交叉并发组

文件：

- `Schedule/CourseScheduleTabView.swift`
- `Schedule/ScheduleViewModel+Classroom.swift`
- `Schedule/ScheduleViewModel+CourseSync.swift`
- `Schedule/ScheduleCalendarModels.swift`
- `Schedule/ScheduleSystemCalendarManager.swift`
- `Schedule/ScheduleLiveActivityManager.swift`

agent 结论与改动：

- 空教室刷新、课表同步、学期加载、短信提交增加账号代际与取消保护。
- 重叠裁剪保留并裁剪背景层。
- 日历 marker 保存学期参数，Live Activity 去重重复课程和自定义日程。
- 活动结束等待、取消、会话保护完成增强。

主 agent 交叉事项：日历删除链路补齐 term、Shared occurrence 稳定去重、课程分享异步解析账号代际保护。

## 第三轮已完成：Activity、Widget、Watch 入口组

文件：

- `Schedule/ScheduleLiveActivityManager.swift`
- `BIT101Watch/WatchScheduleStatusModel.swift`
- `BIT101WatchWidgets/BIT101WatchScheduleWidget.swift`
- `BIT101ScheduleWidgets/BIT101ScheduleWidgetsBundle.swift`
- `BIT101WatchWidgets/BIT101WatchWidgetsBundle.swift`
- `BIT101Watch/BIT101WatchApp.swift`

agent 结论与改动：

- ActivityKit、WidgetKit、WatchConnectivity 桥接保持原生平台边界。
- Live Activity 刷新并发、账号切换、重复 Activity、注销清理和异常课表数据处理完成修正。
- Watch 激活流程增加幂等保护。
- Watch Widget 日期文案使用时间线 entry 基准时间。
- WidgetBundle 和 Watch App 生命周期接线保持清晰。

主 agent 交叉事项：时间线边界回退、Watch 快照时间序列与账号版本、跨 target 字体令牌收口。

## 第三轮已完成：App 根容器与账号设置组

文件：

- `BIT101_iOSApp.swift`
- `ContentView.swift`
- `Shell/AppShellView.swift`
- `Settings/SettingsRootView.swift`
- `Settings/SettingsAccountViews.swift`
- `Settings/SettingsServices.swift`

agent 结论与改动：

- 登录态变化、后台刷新和 Live Activity 清理完成收敛。
- 初始 Tab 重置逻辑、启动公告重复入队、通知权限提示完成修正。
- 账号资料、头像、登录检查、退出登录和学号/UID 展示补充状态保护与无障碍语义。
- 根容器与服务边界保持清晰。

主 agent 交叉事项：AppPromptCoordinator 去重与账号切换、SettingsNetworkService 依赖注入、账号切换后的旧缓存清理。

## 第三轮已完成：Refactor Safety 测试组

文件：

- `BIT101-iOSTests/RefactorSafetyTests.swift`

agent 结论与改动：

- 补充作者隐藏、fixture 人工标签计数、成绩人数边界和低分场景断言。
- 负周次案例改为真实旧 parser 版本迁移场景。
- 增加 reconciliation、超时、预取失败、首屏请求次数和并发安全断言。
- 修正认证测试名称，保持标题与实际覆盖一致。

主 agent 交叉事项：GalleryService 评论过滤、ScheduleViewModel 短信恢复、设计系统契约、Gallery 刷新取消与 generation 竞态测试。

## 第三轮已完成：Course 与 Paper ViewModel 组

文件：

- `Course/CourseViewModel.swift`
- `Course/CourseDetailViewModel.swift`
- `Paper/PaperViewModel.swift`

agent 结论与改动：

- Course 列表刷新、搜索切换、分页加入 generation，固定分页参数快照。
- Course Detail 详情、评论分页、历史成绩加入 generation，修复旧请求回写和取消恢复。
- Paper 列表、搜索、详情评论 generation 完善，分页旧任务不再清理新任务 loading 状态。
- 刷新期间保留已有文章内容，失败与取消恢复路径完成整理。
- 匿名回复使用匿名用户文案。

主 agent 交叉事项：GalleryPosterDetailViewModel 评论 generation、CourseCommentViews 匿名身份展示、PaperModels 回复 UID 规则。

## 第三轮已完成：剩余设计系统组件组

文件：

- `Shared/DesignSystem/AppFeedComponents.swift`
- `Shared/DesignSystem/AppFixedColumnComponents.swift`
- `Shared/DesignSystem/AppHapticFeedback.swift`
- `Shared/DesignSystem/AppCommentComposerComponents.swift`

agent 结论与改动：

- 装饰性分割线隐藏无障碍朗读。
- 固定列宽按比例归一化，避免比例总和变化导致布局溢出。
- 评论工具栏配置改为不可变属性，并补充初始化器。
- 原生 `sensoryFeedback` 实现保持。

主 agent 交叉事项：暂无。

## 第三轮已完成：Gallery 信息流组

文件：

- `Gallery/GalleryModels.swift`
- `Gallery/GalleryService.swift`
- `Gallery/GalleryServicing.swift`
- `Gallery/GalleryViewModel.swift`
- `Gallery/GalleryFeedViews.swift`
- `Gallery/GalleryMessagesView.swift`
- `Gallery/GallerySearchView.swift`
- `Gallery/GalleryComposerView.swift`

agent 结论与改动：

- 信息流、机器人流、推荐流、搜索、评论和消息协议边界保持清晰。
- 消息刷新与分页增加 generation 防护，避免旧请求覆盖新列表。
- 帖子卡片、图片、消息行、图片草稿、标签删除按钮补充无障碍语义。
- 无关联帖子的消息点击可完成已读标记。
- 发帖编辑图片、JPEG 上传、旧草稿兼容和新帖草稿恢复规则完成审查。
- 过时“话题”注释完成清理。

主 agent 交叉事项：图片草稿状态引用、GalleryServicing 发帖能力抽象、回复目标和身份字段稳定性。

## 第三轮已完成：Mine 与协议组

文件：

- `Mine/MineRootView.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineServicing.swift`
- `Gallery/GalleryAnimatedImage.swift`
- `Gallery/GalleryRecommendPrefetchCoordinator.swift`
- `Gallery/GalleryLinkifiedText.swift`
- `Gallery/GalleryServicing.swift`
- `Paper/PaperServicing.swift`
- `Course/CourseServicing.swift`

agent 结论与改动：

- 用户详情标题、本人主页关注入口、关注状态、统计项无障碍语义完成修正。
- Mine 资料、粉丝、关注、帖子分页增加 generation 校验。
- GIF 减少动态效果时仅解码首帧，缓存成本改按像素估算，静态图保持静态展示。
- 预取深度和起始页增加边界约束。
- NSDataDetector、AttributedString、Gallery/Paper/Course 协议均保持原生和清晰边界。

主 agent 交叉事项：Feed 链接与卡片手势优先级、图片/GIF 无障碍标签、Course ViewModel generation、Course Detail ViewModel generation。

## 第三轮已完成：Mine 用户与服务协议组

文件：

- `Course/CourseServicing.swift`
- `Paper/PaperServicing.swift`
- `Mine/MineRootView.swift`
- `Mine/MineViewModel.swift`
- `Mine/MineModels.swift`
- `Mine/MineService.swift`
- `Mine/MineServicing.swift`
- `Gallery/GalleryAnimatedImage.swift`
- `Gallery/GalleryRecommendPrefetchCoordinator.swift`
- `Gallery/GalleryLinkifiedText.swift`

agent 结论与改动：

- Mine 异步刷新、下拉刷新、分页任务取消链路、无障碍标签和会话失效登录回退完成改动。
- 首页资料与帖子并行加载。
- 用户模型、分页契约、服务接口和协议边界保持清晰。
- GIF 减少动态效果时仅解码首帧，缓存成本按像素估算，静态图保持静态展示。
- 预取深度边界与 NSDataDetector 原生链接实现保持清晰。

主 agent 交叉事项：Paper 预览协议拆分、Mine 登录根状态联动、GalleryFeed 链接手势与图片无障碍标签。

## 第三轮已完成：课表专项测试组

文件：

- `BIT101-iOSTests/ExtendedSchedulePolicyTests.swift`
- `BIT101-iOSTests/ScheduleLogicTests.swift`
- `BIT101-iOSTests/ClassroomAvailabilityTests.swift`
- `BIT101-iOSTests/ScheduleTimelineViewportTests.swift`

agent 结论与改动：

- 移除无效的 `EXTENDED_AUTOMATION` 条件包裹，恢复策略测试参与编译。
- `ScheduleLogicTests` 的并发 ServiceStub 改为 actor fixture，消除搜索记录竞态。
- 修正测试标题与覆盖内容不一致的问题。
- 日历地点、课程匹配、编辑器、分享码、空教室和时间轴断言保持确定性。

主 agent 交叉事项：建筑目录与日历地点断言同步、空教室取消、账号代际和短信 continuation 专项覆盖。

## 第三轮已完成：覆盖补充组

文件：

- `CachedRemoteImage.swift`
- `Paper/PaperSummaryViews.swift`
- `Schedule/ClassroomAvailabilityCalculator.swift`
- `Schedule/CourseScheduleTabViewActions.swift`
- `Schedule/FreeClassroomViews.swift`
- `Schedule/ScheduleDDLViews.swift`
- `Score/ScoreCacheStore.swift`

agent 结论与改动：

- 图片缓存取消竞态、原始图片内存容量和缓存文件名实现完成收敛。
- 文章摘要卡片补充无障碍语义与可点击区域。
- 空教室空时间表返回空结果，避免误判全部空闲。
- 课程分享路径安全编码、账号代次和预取状态清理完成。
- 空教室节次筛选、全选判断、DDL 手动记录展示与无障碍语义完成修正。
- 成绩缓存支持空结果与变更通知，详细成绩时间戳清理完成。

主 agent 交叉事项：缓存旧文件迁移、空云端成绩语义、空时间表刷新状态、DDL 数据层过滤。
