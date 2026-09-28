# BIT101-iOS 代码质量审查

更新时间：2026-09-27

## 当前工程约束

- 主 App、Widget、Watch App、Watch Widget 与测试 target 按各自平台边界组织。
- 网络请求通过 `HTTPClient`、`CommunityAPIClient` 或场景化 Service 发送。
- 任务取消、账号隔离存储、日期展示、错误分类和网络诊断复用 `Shared/Client` 中的公共入口。
- UI 令牌与组件位于 `Shared/DesignSystem`；课表、课程、话廊使用所属模块的专用设计文件。
- ViewModel 通过场景化 `Servicing` 协议依赖 Service，页面负责状态呈现与交互。
- 账号切换会取消过期任务并隔离缓存、诊断提示与页面状态。

## 结构审查结论

- 日程服务按同步、缓存、认证、空教室、DDL、日历和编解码职责拆分。
- 课表界面按网格、线性时间轴、课程卡片、周次控件和详情分工。
- Gallery、Paper、Course、Mine 与 Settings 按各自页面流程分层。
- 登录模块由认证 Service、会话状态、Keychain 存储、CAS 解析和 API 客户端组成。
- HTTP 传输、社区请求、网络诊断、错误报告和更新检查归 `Shared/Client`。
- 加载、空态、失败提示和操作恢复由共享组件提供。

## 跨页面约定

- 课表、成绩与可信成绩单共用短信验证表单；各业务 Service 维护独立 challenge。
- 评论、头像、标签、列表、搜索、刷新、比例数据行和浮动按钮通过设计系统组件复用。
- 课程、话廊、文章和消息的日期文案由 `AppDateText` 提供。
- 社区分页由 `PagedItemsState` 管理；课程、话廊、文章、我的页面通过场景协议维护独立业务状态。
- 错误报告脱敏与载荷由 `ErrorReportSupport.swift` 维护；原生弹窗、恢复操作和报告 Sheet 由 `AppErrorPresentation.swift` 维护。

## Apple 平台桥接

- `Map/CampusMapScreen.swift` 使用 `MKMapView` 管理相机、定位和地图 overlay。
- `Gallery/GalleryImageViewer.swift` 使用 Quick Look 呈现原图，并维护低清到高清的预览切换。
- `Schedule/ScheduleCalendarViews.swift` 使用 `UIContextMenuInteraction` 定位空白课表区域的原生菜单，并通过 `UIActivityViewController` 提供系统分享面板。
- `Schedule/ScheduleLinearCalendarViews.swift` 使用 `UIScrollView` 和 `UIHostingController` 实现双指缩放与可见中心保持。
- `Schedule/ScheduleCourseCardViews.swift` 使用 `UILabel` 排列独立的课程名称、完整地点和动态字体。
- `Paper/PaperDetailView.swift` 使用 `UITextView` 呈现 HTML 富文本。
- `Gallery/GalleryAnimatedImage.swift` 使用 ImageIO 和 `UIImageView` 解码、播放 GIF。
- `Shared/Client/KeyboardDismissSupport.swift` 使用 UIKit 手势和输入附件处理跨页面键盘收起。
- `Gallery/GalleryRootView.swift` 提供原生话廊与用户可选的 WKWebView 入口。

## 检查入口

- `Scripts/check-ui-consistency.sh`：视觉令牌、字体、布局、页面角色、公共组件、控件修饰器归属、系统触感和错误报告入口。
- `Scripts/check-code-quality.sh`：客户端网络、存储、日期、并发、源码与脚本规范；结构契约通过 Xcode toolchain 自带的 SwiftSyntax 解析声明、调用、类型、作用域和成员访问。
- `Scripts/check-code-quality.py --self-test` 与 `Scripts/check-ui-consistency.py --self-test`：用内存样例验证规则边界，统一审计入口逐项执行。
- `Scripts/run-static-audit.sh`：统一运行静态检查、阻塞式文档新鲜度检查和锁定依赖漏洞审计，并汇总各检查组结果。
- `Scripts/run-extended-tests.sh`：默认与分组自动化测试。

各项检查从当前源码和项目测试 target 获取状态。此文档维护结构边界和公共入口说明。
所有脚本的人类可读命令输出按同一阈值处理：不超过 1000 行直接显示在 terminal，超过阈值才覆盖固定类别报告路径并显示路径。测试结果包、Smoke JSON、截图等结构化或二进制产物继续使用既有固定路径。

## 2026-09-27 错误报告与发布差异

截至 2026-09-28 汇总入口已收录 Cloudflare 远端 18 份报告，接收时间为 9 月 23 日至 28 日，其中 17 份错误报告、1 份建议；正式版 1.8.1（37）共 16 份，1.8.2（38）共 2 份。sanitized 报告的业务正文与完整重定向头证据有限，报告份数代表提交次数。

Apple Lookup 于 9 月 27 日返回线上版本 1.8.1，发布时间为 `2026-09-10T17:42:11Z`。源码比对基线为发布准备提交 `801da08`；具体归档与提交的对应关系以发布归档记录为准。准备发布的工程版本为 1.8.3（40），开发版安装与 App Store 发布分别管理。

| 报告组 | 份数 | 归因与证据 | 当前代码与处理决定 |
| --- | ---: | --- | --- |
| `jxzxehall: 解析 service url 失败` | 12 | 9 月 25 日 1 份、26 日 7 份、27 日 4 份。BIT-Login 公开源码 `JxzxehallLogin.kt` 通过 `substringAfter("?service=", "")` 提取预请求 Location，结果为空时抛出同名错误。故障点位于认证桥接与学校重定向协议的衔接处；实际部署版本和原始 Location 仍需服务维护者核对。学校页面变化、重定向格式变化与桥接解析适配均属待确认因素。 | 工作区 `ScheduleServiceTeachingCenter.swift` 已将此错误纳入学校 SSO 直连恢复，并在双路线失败时保留两条错误。该修改仍在工作区。校外直连的可达性决定恢复效果；服务端根因处理交由对应维护者。保留现有改动。 |
| 课表同步失败，消息为“查询成功” | 1 | 9 月 26 日。课程接口 HTTP 200，随后另外两项并发任务取消。发布基线会把任意层级的非标准 code 与 msg 组合当作业务失败，存在成功消息误判路径；报告现象与该路径一致，精确响应结构有待原始正文确认。 | `4a0c341`（9 月 15 日）已加入成功语义识别，晚于线上版本发布时间。当前工作区进一步区分 JSON 布尔值、业务封装层与普通记录字段。现有 `ErrorReportAndSchedulePolicyTests` 包含成功码、成功消息和固定真机响应样例。沿用已有修复。 |
| CAS 1320009 / 401，备注“验证框闪退” | 1 | 9 月 24 日。短信接口 HTTP 200 表示请求得到响应；challenge 中携带 CAS 失败。具体认证失败原因仍需认证服务日志。客户端把 `failed` 映射为 `challengeInvalid`，ViewModel 随即清空 `smsChallenge`，形成验证窗口关闭的体验。 | 本次将 `failed` 归入 `authenticationFailed`。短信提交时保留窗口并展示原因及取消后重新同步的提示；challenge 到期与 403/404/409 仍走失效流程。 |
| WebVPN TLS 握手失败 | 1 | 9 月 23 日。认证 Cookie 获取成功后，学校 WebVPN 接口连续在 25 ms、12 ms 返回 TLS 错误。证据指向学校端点或用户到端点的 TLS 链路；证书、代理、设备信任状态仍需更详细的系统错误确认。 | 当前代码已有 TLS 错误分类与学校直连恢复。保留系统证书校验和既有恢复策略。 |
| 教学中心直连与 WebVPN 超时 | 1 | 9 月 24 日。直连与 WebVPN 请求均超时，WebVPN 约 44 秒。另一条记录约 127 分钟；诊断耗时采用墙钟差值，后台挂起等因素也会计入，具体网络等待时长待确认。 | 发布基线已经设置 30 秒请求、60 秒资源超时并关闭连接等待。当前代码包含更完整的路线切换。沿用超时设置与恢复流程，保留网络链路问题的归因范围。 |
| Core Location `locationUnknown` | 1 | 9 月 28 日，版本 1.8.2（38），10 条 BIT101 API 请求均返回 HTTP 200；定位错误来自操作系统 Core Location。 | 1.8.3（40）已递归检查 `NSUnderlyingErrorKey` 并过滤瞬时 `locationUnknown`，其它定位故障仍会显示提示。 |
| 课程详情建议 | 1 | 9 月 27 日，版本 1.8.2（38），用户称更新后无法打开课程详情。与透明长按交互覆盖课程点击的回归吻合。 | 1.8.3（40）使用 `UITapGestureRecognizer` 处理短按，长按分享由 UIKit 默认识别顺序处理；build 39 的同时识别版本曾干扰菜单，build 40 已撤回。 |

参考：[App Store](https://apps.apple.com/cn/app/bit101/id6761147125)、[BIT-Login 重定向解析源码](https://github.com/BIT101-dev/BIT-Login/blob/d1b3c403/bit-login/src/commonMain/kotlin/cn/bit101/bitlogin/service/JxzxehallLogin.kt)。本轮验证范围为构建装机与代码对照，交互手感由实机操作确认。

## 2026-09-28 GitHub Actions 汇总

汇总脚本拉取 0 条开放 GitHub Issue 与 17 条历史失败运行。当前 HEAD `60ca01a` 对应运行 `36372154871` 失败在工具链预检：`macos-latest` 提供 Xcode 26.6，项目预检要求 Xcode 27；Release job 因依赖预检失败而跳过。`.github/workflows/ci.yml` 两个 job 已固定为 GitHub 官方 `xcode-27` runner。其它失败运行对应更早提交，需结合各次提交历史判断，不计入当前 HEAD 失败。

## 周次控件与 Mac 装机

周次刻度通过 `contentMargins` 设置滚动内容两侧的居中边距，刻度直接注册为系统滚动目标。iOS 26 及后续版本使用系统 `ViewAlignedScrollTargetBehavior(anchor: .center)` 对齐实际刻度视图；iOS 17/18 使用系统视图吸附，内容边距将有效对齐区域居中。Catalyst 鼠标拖动的位移按手势起点周数计算。Mac 装机脚本在替换应用前结束安装路径对应的进程，再安装并启动新构建；构建产物、安装包及运行进程共同确认安装结果。

## 2026-09-28 用户报告回归修复

- 课程详情点击建议来自 1.8.2（38）。该版本将课程卡片触摸交由带 `UIContextMenuInteraction` 的透明 `UIControl`，其 `.touchUpInside` 动作未稳定触发。当前改用 `UITapGestureRecognizer` 响应短按，并沿用系统默认手势仲裁处理长按分享；build 39 的同时识别尝试影响了原生长按菜单，build 40 移除同时识别配置。
- 最新「定位失败」报告包含 `kCLErrorDomain` 代码 1，即 `locationUnknown`；10 条网络记录均为 HTTP 200。MapKit 可能将该 Core Location 错误包装在 `NSUnderlyingErrorKey` 中，当前已递归检查错误链并过滤该瞬时状态，保留其它定位失败的提示。
- 版本提升为 1.8.3（40）；启动公告和更新文案已同步。iPhone Release 真机构建、安装和启动通过。当前尚未取得课程点击与地图错误提示的实机录屏反馈。

## 1.8.2（38）全量验证

2026-09-27 执行结果：

| 验证入口 | 结果 |
| --- | --- |
| `Scripts/run-static-audit.sh` | 全部通过，版本、文档、UI、源码与依赖检查通过 |
| `Scripts/run-extended-tests.sh` | iPhone 真机 202 项通过，0 失败，0 跳过 |
| `Scripts/run-extended-tests.sh catalyst` | Mac Catalyst 202 项通过，0 失败，0 跳过 |
| `BIT101_NETWORK_SMOKE_SCOPE=all Scripts/release-network-smoke.sh` | 48 项执行，0 失败，0 认证阻塞，0 跳过，覆盖完整 |
| `Scripts/run_icloud_cross_device_smoke.sh` | iPhone 上传、Mac 接收、iPhone 确认及清理三个阶段全部通过 |

iCloud 专用 XCTest 类采用 `nonisolated` 初始化与方法级 `@MainActor`，通过 Swift 6 编译并完成双端运行。真机测试主 App 行覆盖率为 20.32%；Catalyst runtime 的覆盖率归档由真机结果补充。网络 smoke 的短信验证覆盖手机号预检；验证码输入和周条手势体验由实机人工操作确认。Catalyst 构建仍报告 Watch target 的 App Category 元数据警告。
