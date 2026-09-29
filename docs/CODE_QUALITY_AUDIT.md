# BIT101-iOS 代码质量审查

更新时间：2026-09-29

## 模块化实施记录

实施基线：`59f9437`。本轮授权范围包括新增模块文件、相关离线测试、静态审计和既有真机构建装机流程。

完成判据按评估中的依赖、状态和编译边界逐项核验：

- [x] 地图页面接收下一节课地点快照，课表读取由 Shell 适配。
- [x] 学业状态对象由 App 生命周期持有，通过 SwiftUI 环境传递。
- [x] 社区传输的登录恢复通过应用认证适配层注入。
- [x] 基础传输、诊断记录与应用提示完成依赖分离。
- [x] 跨业务诊断与偏好云同步归应用协调层，调用链与文档同步。
- [x] 共享快照、编解码、时间线计算接入独立编译模块并通过各消费 target 编译验证。
- [x] 设计令牌与公共组件建立编译边界，保留平台适配及统一样式来源。
- [x] 社区公共模型与媒体展示具备独立归属，页面跳转通过路由接口协调。
- [x] 日程课表、DDL、空教室分别拥有状态，持久化与外部同步通过明确契约协作。
- [x] 核心模块具备独立离线验证入口，现有测试资产沿用固定路径。
- [x] 架构、文件索引与验证文档对齐，完成模块及 App 逻辑测试、静态审计和真机构建装机。

`Package.swift` 在仓库内声明四个模块；源码沿用固定路径。`ClientCore` 承载网络与存储基础能力，`ScheduleContracts` 承载跨设备契约，`CommunityCore` 承载公共社区模型，`DesignSystemKit` 承载设计令牌与组件。迁移以账号隔离、数据编码、持久化键、请求时序和现有交互稳定为约束。

基础模块由 Swift 编译器检查依赖和公开接口，业务功能继续以 App 内的 service / state / view 分层组织。Shell 集中组装账号、页面工厂、地图适配和持久化副作用。后续业务 Package 提取可沿当前协议与数据边界逐个推进；新增边界应对应独立维护或复用需求。

本轮验证记录：

- `Scripts/run-extended-tests.sh modules`：原生 macOS Release，13 项通过，覆盖 HTTP 注入、共享快照、时间线、社区编解码及账号存储。
- `Scripts/run-extended-tests.sh all`：iPhone Release，222 项通过；`catalyst`：222 项通过。包含 6 项日程仓库与 DDL 边界回归。
- `Scripts/run-static-audit.sh`：检查器自测、源码、UI 契约、文档、依赖与产物检查全部通过。
- `Scripts/build-install-device.sh`：本轮源码通过 iPhone Release 构建，完成安装与启动；UI 测试退出后的恢复流程使用同一入口。
- `Scripts/run-extended-tests.sh ui`：设备自动化已恢复，七项用例逐项通过：全套五项通过后，修正余下两项的菜单定位与 Tab 就绪断言，合并定向复测 2/2 通过。
- 模块测试入口已接入现有 GitHub Actions 静态审计 job，远端执行结果由后续 CI 运行记录。

Watch 与 Widget 的本轮证据覆盖编译和共享逻辑测试；外部设备交互验收沿用专用验证流程。CI 工作流改动已通过本地静态门禁，远端执行结果由后续 CI 运行记录。

## 自动化输入与执行效率

审查范围覆盖 `Scripts/` 全部 19 个入口与辅助程序、GitHub Actions 工作流、pre-commit 钩子、Xcode target 依赖，以及逻辑测试和 UI 测试的启动、等待、清理与重试路径。

| 范围与文件 | 重复开销及原因 | 当前处理 |
| --- | --- | --- |
| UI：`LoginAndScheduleUITests.swift`、登录测试适配层 | 每项页面用例经表单登录，会话恢复另起用例；账号 B 输入追加到保留的账号 A | 页面用例注入隔离会话，账号输入先清空并断言完整值；七项用例启动次数从 12 降为 9，表单登录从 9 降为 2；持久化与会话恢复共用一次重启 |
| 编排：`run-extended-tests.sh` | 分别执行 UI、网络测试时重复发现设备并恢复常规包；逐项复测重复启动构建流程 | `verify` 批次共用设备标识，退出时恢复常规包一次；重复分组去重；支持多项 `--only-testing` 合并执行；测试汇总按总计输出，移除重复计数 |
| iCloud：`run_icloud_cross_device_smoke.sh` | 手机上传、验证和清理各自执行构建测试命令；隐式结果包按时间累积；zsh 函数内错误退出跳过清理钩子 | 手机 `build-for-testing` 一次，各阶段复用产物；结果包覆盖固定路径；显式退出触发清理；提供独立结果读取与清理入口，失败路径通过 Shell 复现核验，真机清理通过 |
| CI：`.github/workflows/ci.yml` | App 已沿依赖图构建 Watch 和两个 Widget，随后三个 scheme 再次构建；版本与 plist 校验跨步骤重复 | iOS 父 target 统一构建 App、扩展和测试；静态门禁核验完整依赖图；版本基线与发布参数传给统一审计，版本校验执行一次 |
| 平台：`project.pbxproj` | App 到 Watch 的依赖缺少平台过滤，Catalyst 构建牵连 Watch | 依赖与嵌入阶段统一使用 iOS 平台过滤；自动审计覆盖过滤条件 |
| 审计：`check-code-quality.py`、`check-ui-consistency.py` | 同轮审计重复执行检查器自测，多条规则反复读源码、屏蔽字符串和注释 | 共用 SwiftSyntax 索引；自测结果复用一次；源码、文件清单和纯文本解析在单次进程内复用 |
| 文档：`check_stale_docs.py` | 每篇文档单独调用 Git 查询修改状态 | 一次获取全部 Markdown 修改集合；最后提交时间仍按文档查询，保持日期判断语义 |
| 报告：`fetch-issues-and-reports.sh` | 每次汇总重新下载最近 20 次失败运行的相同日志 | 保留固定路径汇总，按运行 ID、更新时间和提交复用成功读取的日志；更新后重新读取；相同运行、运行更新、首次读取和读取失败四项离线验证通过 |
| 截图：`capture-screenshot-device.sh`、`device-support.sh` | 截图前运行 Xcode 目标解析，工作与屏幕捕获无关 | 截图直接使用 CoreDevice 发现；构建继续核对设备 UDID 与工程目标；真机截图执行通过 |
| 并发测试：`ScheduleModuleBoundaryTests.swift` | 三处循环调用 `Task.yield()` 等待测试服务进入请求 | 使用 continuation 通知请求已进入，等待期间挂起任务；6 项边界回归定向复测通过 |
| 网络：`release-network-smoke.sh` 及两个范围包装入口 | 装机前额外执行按 bundle ID 终止进程的命令；失败后重跑全套扩大开销 | 系统安装处理进程替换；按 `ddl` 等业务范围复测；全量网络探针由一次宿主运行完成 |
| 语法门禁：`run-static-audit.sh` | Shell、Node 多文件参数写法实际覆盖首个文件，批量外观与检查范围存在偏差 | 逐文件检查 Shell 与 Worker，补充内嵌 Python 语法编译；覆盖范围随优化保留 |

其余入口的审查结论：`build-install-device.sh` 复用固定 DerivedData，增量构建交给 Xcode；常规装机保留一次安装和启动。`error-reports.sh` 单份查询与 `generate_campus_map_fixture.py` 人工生成入口按需执行。Cloudflare 汇总沿用已处理键的增量读取。两个独立检查器包装入口服务局部审计，统一审计调用合并入口。pre-commit 执行文档新鲜度检查一次。

等待路径保留具体用途：iCloud 轮询等待跨设备传播；网络采样轮询等待结果文件；Mac 安装等待旧进程退出，各项均设截止条件。课堂超时用例中的 30 秒休眠由 5 毫秒超时取消，用于验证取消行为。其余有限次调度等待用于观察异步状态，当前逻辑套件运行结果正常。

实测记录：同机统一静态审计优化前为 47 秒，优化后的两轮为 28.85 秒、29.60 秒，全部检查通过；耗时受机器负载与依赖审计响应影响。模块 13 项、iPhone 222 项、Catalyst 222 项已通过。并发等待改动的 6 项回归及截图入口已通过；UI 首轮 5 项通过，剩余 2 项合并定向复测通过，耗时 44.82 秒（Xcode 测试阶段）。全量网络执行 47 个探针，其中乐学订阅地址超时，关联 DDL 下载跳过；DDL 定向复测再次超时。iCloud 手机上传和 Mac 接收通过，手机等待 `macRestored` 协调状态 30 秒超时；独立清理测试通过，常规 Release App 已完成安装与启动。该轮保留失败状态，跨设备传播原因待进一步定位。

## 权限提示与自动化会话

2026-09-29 根据现有构建产物及系统日志核查：

- Mac 权限日志在 17:13 和 17:18 记录 BIT101 签名身份匹配失败，随后请求桌面和文稿访问。归因是临时签名与开发者签名交替运行。当前本机 Catalyst 测试沿用工程自动开发签名；`CODE_SIGNING_ALLOWED=NO` 限定在 `GITHUB_ACTIONS=true` 分支。本机 Catalyst 测试、iCloud Catalyst 测试及常规 Mac 安装的 App 签名要求完全一致，三份产物的严格交叉校验通过。现有 iPhone UI Runner 继续使用固定标识 `BIT101-dev.BIT101-iOSUITests.xctrunner` 和同一开发团队。
- 手机 UI Runner 在 15:50、15:54、16:00、16:19、16:30、17:15 分别安装并启动，最短间隔约 3 分 38 秒。记录对应六次独立测试调用。App 在同一套件内的启动次数与自动化会话数量分别统计。
- 用户报告的密码提示频率显著高于每天一次。新自动化会话是重点排查方向；逐次弹窗与会话的对应关系仍需设备端事件确认。复测沿用多个失败用例合并执行的入口，验证记录区分执行次数、Runner 安装次数和用户授权次数。
- `ui --build-only` 提供签名编译检查；`verify --ui-test` 支持在同一批次选择多个 UI 用例并去重，统一结束时恢复常规 App。UI 执行显式采用串行配置；编译产物由 Xcode 增量复用。离线脚本检查覆盖本机与 CI 签名分支、批量用例筛选与去重、预编译、批次恢复及参数错误处理，全部通过。本轮完成 Catalyst 签名构建与产物校验，手机 UI 会话启动次数为零。

参考：[Apple 签名身份与权限记录](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[XCUITest 驱动关于新会话密码提示的说明](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/troubleshooting/index.md)、[Apple 工程师关于自动化授权的历史说明](https://developer.apple.com/forums/thread/693273)。历史说明中的约每天一次用于理解授权机制，当前设备频率以实际观察和日志为准。

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
- HTTP 传输与社区请求归 `ClientCore`；网络记录、错误报告和更新检查归 `Shared/Client`；跨业务诊断编排归 Shell。
- 加载、空态、失败提示和操作恢复由共享组件提供。

## 跨页面约定

- 课表、成绩与可信成绩单共用短信验证表单；各业务 Service 维护独立 challenge。
- 评论、头像、标签、列表、搜索、刷新、比例数据行和浮动按钮通过设计系统组件复用。
- 课程、话廊、文章和消息的日期文案由 `AppDateText` 提供。
- 社区分页由 `PagedItemsState` 管理；课程、话廊、文章、我的页面通过场景协议维护独立业务状态。
- 错误报告脱敏与载荷由 `ErrorReportSupport.swift` 维护；原生弹窗、恢复操作和报告 Sheet 由 `AppErrorPresentation.swift` 维护。

## Apple 平台桥接

- `Map/CampusMapScreen.swift` 使用 `MKMapView` 管理相机、定位和地图 overlay。
- `Shared/Media/ImagePreview.swift` 使用 Quick Look 呈现原图，并维护低清到高清的预览切换。
- `Schedule/ScheduleCalendarViews.swift` 使用 `UIContextMenuInteraction` 定位空白课表区域的原生菜单，并通过 `UIActivityViewController` 提供系统分享面板。
- `Schedule/ScheduleLinearCalendarViews.swift` 使用 `UIScrollView` 和 `UIHostingController` 实现双指缩放与可见中心保持。
- `Schedule/ScheduleCourseCardViews.swift` 使用 `UILabel` 排列独立的课程名称、完整地点和动态字体。
- `Paper/PaperDetailView.swift` 使用 `UITextView` 呈现 HTML 富文本。
- `Shared/Media/RemoteAnimatedImage.swift` 使用 ImageIO 和 `UIImageView` 解码、播放 GIF。
- `Shared/Client/KeyboardDismissSupport.swift` 使用 UIKit 手势和输入附件处理跨页面键盘收起。
- `Gallery/GalleryRootView.swift` 提供原生话廊与用户可选的 WKWebView 入口。

## 检查入口

- `Scripts/check-ui-consistency.sh`：SwiftSyntax 节点范围内的视觉令牌、字体、布局、页面角色、递归公共组件契约、控件修饰器归属、系统触感、错误报告入口与图片型操作控件无障碍名称；动态 SF Symbol、固定几何和主题例外均由自动契约约束。
- `Scripts/check-code-quality.sh`：客户端网络、存储、日期、并发、源码与脚本规范；结构契约通过 Xcode toolchain 自带的 SwiftSyntax 解析声明、调用、类型、作用域和成员访问。
- `Scripts/check-code-quality.py --self-test` 与 `Scripts/check-ui-consistency.py --self-test`：用内存样例验证规则边界，统一审计入口在共享进程内各执行一次。
- `Scripts/run-static-audit.sh`：统一运行静态检查、阻塞式文档新鲜度检查和锁定依赖漏洞审计，并汇总各检查组结果。
- `Scripts/run-extended-tests.sh`：默认与分组自动化测试。

各项检查从当前源码和项目测试 target 获取状态。此文档维护结构边界和公共入口说明。
所有脚本的人类可读命令输出按同一阈值处理：不超过 1000 行直接显示在 terminal，超过阈值才覆盖固定类别报告路径并显示路径。测试结果包、Smoke JSON、截图等结构化或二进制产物继续使用既有固定路径。

## 2026-09-29 学期起始日期建议

汇总入口增量拉取 1 条正式版用户建议（1.8.3，build 40，报告编号
`4d11da92-ebf0-4905-96c5-393f7179e502`）。用户描述研究生 9 月 21 日开学，
并希望自行设置学期起始日期；报告的诊断列表与附件为空，个人课表的具体数据对应关系待实机核对。

依据维护者确认的本科生课表正确基线，本次改动集中于“课程表设置”的日期选择、
账号缓存中的学期日期覆盖值，以及同步完成后应用该覆盖值。学校周次解析、小学期校正、
课程记录及学校学期快照继续沿用现有逻辑。默认使用学校日期；手动选择归一化为周一，
按本机账号和学期保存，并提供“使用学校日期”操作。设置入口采用名称与当前日期组成的
列表行，编辑沿用原生滚轮面板和顶部“取消 / 完成”。“使用学校日期”位于面板内，
与手动日期统一在点击“完成”时保存。现有缓存保存流程更新小组件与提醒。

定向验证覆盖 22 项相关用例：首轮 21 项通过，新增日期用例修正测试资源读取路径后，
两项日期用例合并复测 2/2 通过。覆盖默认学校日期、原始课程记录保留、周一归一化、
刷新与学期切换、恢复学校日期、账号隔离、持久化和重复解码。Swift Testing 方法筛选
使用包含 `()` 的完整标识；本轮一次筛选返回 0 项，按空执行记录，随后以完整标识完成复测。
统一静态审计全部通过；Release 真机构建、安装与启动完成。本轮交互行为由本机逻辑回归验证。

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

## 2026-09-29 成绩请求账号隔离与职责分层

- `ScoreViewModel` 在成绩刷新、短信提交和缓存恢复开始时捕获账号 session 与 generation；账号切换递增 generation 并取消当前受管请求。异步结果和错误状态回写前校验 session 与 generation，成绩和关联课表缓存读取沿用捕获的账号 session。
- `InfrastructureTests` 新增延迟认证 challenge 回归用例，覆盖账号切换后丢弃旧账号 challenge 的路径。
- 话廊消息状态机与本地已读仓库位于 `Gallery/GalleryMessageViewModel.swift`；话廊 feed 与搜索状态保留在 `Gallery/GalleryViewModel.swift`。
- CloudKit 载荷、冲突策略和缓存合并位于 `Schedule/ScheduleCloudSyncSupport.swift`；CloudKit 请求编排保留在 `Schedule/ScheduleCloudSyncManager.swift`。
- `Scripts/build-install-device.sh` 真机 Release 构建、安装和启动流程完成。

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
