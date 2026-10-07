# 构建与测试

## 执行约定

- 构建使用 Xcode 27.x、有效签名和已连接并受信任的真机，默认完成 Release 构建、装机与启动。
- 本机构建、装机和启动统一使用 `Scripts/build-install-device.sh`；脚本封装所需 Xcode 流程。
- iOS / watchOS 验收与日常 UI 复验使用真机；包级逻辑测试使用 macOS 原生宿主，Catalyst 行为测试使用 macOS runtime。
- 测试、静态审计、网络 Smoke 和 iCloud Smoke 按用户明确授权的范围执行。失败修复后重跑受影响的分组。
- 界面验证使用既有 UI 测试、截图脚本与命令行流程。设备自动化授权由 iOS 管理，系统要求时由用户在设备上输入密码，设备继续保留密码保护。
- `BIT101-iOSTests/Fixtures/` 和测试 target 内的样例、fixture、校准及人工准备数据属于长期资产，沿用固定路径。清理或改写前确认来源、用途和恢复方式，并取得用户明确同意。

## 脚本入口

脚本按完整工作流组织，公共设备选择与日志处理集中在 `Scripts/script-support.sh`。入口数量保持精简，同一工作流通过参数选择操作；优化以执行耗时、重复调用和终端信息价值为依据。静态审计复用索引器并缓存路径判断。

| 工作流 | 入口 |
| --- | --- |
| 构建、装机、截图、设备信息 | `Scripts/build-install-device.sh` |
| 模块、App、UI、Catalyst 与聚合验证 | `Scripts/run-extended-tests.sh` |
| 语法、工程、依赖、文档与设计规则审计 | `Scripts/run-static-audit.sh` |
| 网络探针与范围选择 | `Scripts/release-network-smoke.sh 范围` |
| iCloud 双向验证、报告与恢复 | `Scripts/run_icloud_cross_device_smoke.sh` |
| Issues、CI 失败与反馈报告管理 | `Scripts/fetch-issues-and-reports.sh` |

输出处理器自测覆盖诊断展示阈值、CI 失败诊断、完整留档、信号退出状态及执行期间改写源码的故障注入。CI 失败时展示过滤后的完整诊断，供远端直接定位错误。Xcode 默认临时错误结果包在命令结束后自动清理。测试结果保存在既有固定日志与结果包中；`Scripts/run-extended-tests.sh report` 读取最近一次模块、App 或 UI 测试结果。

构建分派自测使用内存替身，UI 运行配置处理通过内存 plist 验证最新产物选择、诊断设置和业务 target 配置保留，并覆盖冷缓存中的运行配置完整性检查。

构建、测试、Smoke 和报告管理入口均提供 `--help`。质量、UI、模块边界、文档引用与版本检查器保留独立入口，便于针对单项问题执行；统一审计通过共享 SwiftSyntax 索引执行质量与 UI 检查，并输出解释文案审查候选。地图 fixture 生成使用 `Scripts/generate_campus_map_fixture.py <教务导出.xlsx>`，沿用既有人工审核和固定数据路径约定。

## 构建、装机与截图

```sh
Scripts/build-install-device.sh
Scripts/build-install-device.sh build
Scripts/build-install-device.sh screenshot
```

所有真机入口共用 `Scripts/script-support.sh`，自动识别已配对的真实设备：依据一次 CoreDevice 设备快照优先选择 USB 有线设备，再选择当前可发现的无线设备，同类连接优先使用已建立隧道的设备。构建、装机、启动、截图、测试、网络 Smoke 与 iCloud Smoke 共用所选设备。终端显示设备名称，设备标识由脚本内部传递；连续工作流复用同一次快照。

设备选择在构建与测试启动前完成，连接类型回退由当前可发现状态触发。设备全部离线时立即退出并提示连接方式。设备发现沿用 CoreDevice 默认参数，执行一次列表读取。

[无线调试](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)要求 iPhone 与 Mac 完成 Xcode 配对、开启开发者模式并连接同一局域网。通过既有脚本读取设备详情，验证当前连接：

```sh
Scripts/build-install-device.sh info
```

输出显示设备名称、USB / 无线连接和解锁状态。

Mac Catalyst 构建与安装沿用同一入口：

```sh
Scripts/build-install-device.sh mac
```

Catalyst 安装路径为 `~/Applications/BIT101-iOS.app`。截图固定覆盖 `.build/screenshot.png`。课表模型和共享展示改动同时关注主 App、Widget、Watch App 与 Watch Widget。

`build` 使用通用 iOS 目的地编译 Release App 及扩展，产物覆盖 `build/DeviceInstall/`。真机行为、系统权限和实际跨端传输由设备测试验证。

## 包级与 App 行为测试

| 分组 | 宿主与范围 |
| --- | --- |
| `modules` | macOS 原生 Release；本地模块的领域、服务、存储和场景状态 |
| 直接运行 | 真机 App 完整行为与平台适配 |
| `schedule` | 日程、编辑、缓存、分享和同步策略 |
| `infrastructure` | 网络、存储、取消和账号隔离 |
| `login` | 登录恢复、CAS、学校认证与短信 challenge |
| `extensions` | Widget / Watch 共用快照、传输、状态与时间线 |
| `catalyst` | Mac Catalyst 行为测试 |

```sh
Scripts/run-extended-tests.sh modules
Scripts/run-extended-tests.sh
Scripts/run-extended-tests.sh schedule
Scripts/run-extended-tests.sh infrastructure
Scripts/run-extended-tests.sh login
Scripts/run-extended-tests.sh extensions
Scripts/run-extended-tests.sh catalyst
```

包级测试由 `Package.swift` 的 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个消费者 target 管理，代码位于 `ModuleTests/`，使用内存传输、文件服务、偏好和实例级变更流。覆盖话廊分页去重、预取游标与搜索代际，主页刷新、分页失败重试和账号场景隔离，日程整体格式迁移、课程编辑及权威快照，发帖编辑与上传生命周期、草稿损坏和格式版本保护、历史草稿及图片迁移、账号目录与文件保存失败保护、社区身份与恢复隔离、日程保存排队、精确版本往返与过期比较令牌、文件损坏和账号切换、生产成绩服务注入、独立成绩与消息存储端口、变更流的实例及账号归属、共享草稿图片准备和版本清理、同步冲突及地图身份规则。社区持久化测试通过 `CommunityPersistence` 的公共入口运行。测试用内存文件服务集中于 `ModuleTests/Support`，直接依赖 StorageCore。学校课表解析沿用 `BIT101-iOSTests/Fixtures/schedule-service-response.json`。课程与文章服务契约测试覆盖分页、特殊课程号路径、Snake Case 解码、认证恢复、评论及文章写入；课程详情场景覆盖刷新代际、失败保留、评论去重、历史成绩重试、回复身份及点赞；学校响应测试覆盖业务失败、认证失效、格式变化和 HTTP 状态分类，教学中心会话覆盖认证、预热复用和短信 challenge，乐学订阅覆盖安全 URL 与已完成日程保留。云同步测试同时验收成功、待同步、失败和账号不可用状态。MapKit 页面、UIKit、Quick Look 和可信成绩单展示通过 App 宿主验证。

`FeatureCompositionTests` 在 App 宿主组合不同的环境依赖，验证课程、Gallery → Paper、Paper、Mine、Profile、Schedule 的构造归属，并验证同一宿主中 Paper / Gallery 依赖替换的场景重建。`MediaDependencyTests` 验证内存存储、静态 / GIF 解码和预览字节；`SuggestionDependencyTests` 验证草稿及提交归属；同文件的 `AppLocalDataOwnershipTests` 与 `SettingsDependencyOwnershipTests` 验证清理动作顺序、失败汇总、后端隔离和设置媒体 / 账号归属。`PreferenceMergeTests` 使用独立设备偏好与云存储验证离线字段合并、已读并集、同版本收敛、可选字段清除与重载。`LoginStorageTests` 使用注入凭据后端验证事件代际、实例隔离、迁移和写入失败；提醒规划及同步状态呈现通过纯输入与账号事件验证。`ExperimentalPreferenceCloudSyncTests` 使用独立账号事件流和平台替身验证生命周期实例隔离及所选课程源向成绩场景传递。

按现有测试类或方法选择范围，多个筛选项在同一次调用执行。Swift Testing 方法名保留 `()`，suite 名称用于整组运行；脚本按实际用例数量验收选择范围：

```sh
Scripts/run-extended-tests.sh \
  ExperimentalPreferenceCloudSyncTests \
  ScheduleModuleBoundaryTests \
  NetworkClientTests
```

`build` 编译所选宿主的测试产物，默认使用 Release；iOS 宿主自动使用通用目的地，CI 覆盖正式 Release、UI、网络 Smoke 与 iCloud Smoke 四种编译条件：

```sh
Scripts/run-extended-tests.sh build release
Scripts/run-extended-tests.sh build ui
Scripts/run-extended-tests.sh build network-smoke
Scripts/run-extended-tests.sh build icloud-smoke
```

缓存整理使用 `Scripts/run-extended-tests.sh cache`。全量逻辑测试使用 `Scripts/run-extended-tests.sh`。

## UI 自动化

`BIT101-iOSUITests` 使用 `BIT101-iOS-UIAutomation` Release scheme 和真机宿主。`BIT101_UI_TESTING` 构建隔离 Keychain、偏好、账号文件和媒体缓存，使用合成会话及离线服务。测试文件归 App 内固定的 `Application Support/BIT101-UITests/` 根目录，系统日历与提醒动作使用内存端口，偏好云同步使用内存云存储。正式 App 由生产组装入口启动。UI 宿主在前台保持屏幕常亮。自动化控制和渲染查询归 `Login/UITestAccessibilityActions.swift`，启动配置与响应夹具归 `Login/AppUITestBootstrap.swift`。测试窗口沿用系统默认动画速度。测试默认关闭 UIKit 动画；连续编辑、短信重试、媒体预览和多层弹窗场景启用系统动画，验证导航与输入生命周期。动画场景核对实际窗口速度及动画启用状态；登录键盘提交和建议草稿往返通过原生触摸及系统键盘执行。

日常 UI 复验使用 `Scripts/run-extended-tests.sh ui`，用例关键词直接接在 `ui` 后面，按测试类与方法名匹配并合并为一个批次，完整测试类/方法同样适用。例如 `ui About` 执行关于页面，`ui DDL Calendar` 合并 DDL 和日历相关流程。测试宿主编译使用 `build ui`。56 项通过 `UIAutomationTestCase` 串行复用一个 App 进程，每次场景配置校验进程 ID；完整映射见交互覆盖表。

真机运行期间保持 BIT101 前台并暂停手动操作。场景切换时，后台 App 通过 `activate()` 返回前台，并继续校验原进程 ID。第三方输入法可能提供键盘画面而缺少 XCTest 键盘元素；输入助手通过系统“下一个键盘”按钮切换到原生键盘，再执行输入与完整字段值断言。

UI 用例按页面组合连续交互；公共组件完整合同集中验收一次，各页面验证入口、绑定和业务结果，每项独立重置隔离数据；持久化场景重新创建模型和根视图，从文件与偏好重新读取。测试 App 与 Runner 通过 TransportCore 内测试专用的 `127.0.0.1:19101` 通道更新夹具配置，全部场景保持同一 App 进程。测试 App 使用简体中文和中国地区，系统控件文案与日期格式保持一致。覆盖目标包括每个点击、滑动和输入入口，并验证交互后的业务状态。当前定义 56 项用例，公共组件合同和页面接入共同承接完整交互，逐项映射和运行验收状态见 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)：

| 页面 | 交互范围 |
| --- | --- |
| 登录与主导航 | 必填字段、键盘及按钮提交、滚动收起键盘、账号隔离、五个 Tab、浅深色辅助功能大字号 |
| 课表 | 周次按钮及拖动、分栏横滑、长按菜单、添加 / 编辑 / 删除日程、日期时间选择器、课程补录 / 调课 / 删除、日期放假 / 调休确认、上下滑切换分享课表、线性时间轴滚动和双指缩放 |
| 日程设置 | 时间轴、时间表校验 / 保存 / 取消、学期切换 / 下拉刷新、日期滚轮、开关 / 提醒阈值持久化、名称、编码复制 / 粘贴导入 / 分享、新版本编码更新提示、分享课表改名 / 左滑删除、整学期及单项日历导入 / 移除 |
| DDL 与空教室 | 学校双来源、详情、完成状态、手动待办增改删、日期时间及详情编辑、学校刷新 / 订阅链接刷新 / SSO 短信继续、校区 / 楼宇选择、教室刷新、节次多选 / 全选 / 清除 |
| 成绩与课程 | 查询及刷新短信错误重试 / 取消、逐项及批量筛选、排序、已出分 / 未出分详情、课程评价路由、可信成绩单多页预览、课程搜索 / 清除、数据清洗、历史图拖动、点赞、半星评分 / 匿名评论 / 回复 / 评论图片 / 分享 |
| 地图 | 校区、图层、平移、缩放、定位 / 单次权限授权、课程地点路由、下一节课系统地图导航、重新装载恢复 |
| 话廊与文章 | 分类点击及横滑、搜索 / 清除 / 排序 / 结果路由、消息横滑 / 分类 / 已读 / 详情、列表及详情下拉刷新、发布校验 / 标签 / 声明 / 开关 / 草稿、发布 / 修改 / 删除、图片预览 / 上传重试 / 图片移除、正文链接、点赞、评论排序 / 点赞 / 回复、长按复制 / 举报 / 删除及确认 / 取消、分享、离线重试及恢复 |
| 我的与设置 | 个人统计列表 / 刷新、公开主页统计显示与帖子入口、关注状态、头像预览 / 选择器取消、个人帖子详情 / 删除、标识显示 / 隐藏、资料保存 / 取消 / 登录检查 / 退出、屏蔽 UID 校验、网页话廊 / 滚动 / 切回原生、偏好及缓存上限持久化、建议草稿 / 图片 / 提交确认 / 成功 / 失败、错误报告模式及提交分支、开源声明 / 外部链接 / 更新提示全部动作 / 缓存清理 / 确认重置、网络诊断 |

`BIT101_UI_TEST_CONTENT=1` 选择内存 HTTP 固定响应，并经过生产社区 Service 的解码与状态逻辑；默认场景使用离线失败响应。响应维护当前测试场景的点赞、评论、关注、资料和文章 / 话题增改删状态，新增内容可以在后续详情请求中读取。学校、媒体、单次失败和更新响应配置见交互覆盖文档。页面发出的外部 URL 在 UI 宿主显示完整目标地址，地图导航使用系统 Maps。普通控件通过 App 内当前渲染的无障碍树读取标识、文案、布局和状态，可触达判断结合窗口命中测试、当前呈现页面范围及原生查询；同一显示帧内复用渲染快照，控件事件、原生操作记录及场景切换立即使缓存失效。SwiftUI 控件通过公开的无障碍激活动作执行真实事件，UIKit 按钮通过命中位置的实际控件事件执行，导航栏按钮发送实际 UIBarButtonItem 的 target/action 或实际控件的 UIAction，菜单入口通过实际 UIControl 的 performPrimaryAction 或 XCTest 操作，消费页面使用当前可见菜单的实际 UIAction，共享菜单合同保留原生选项点击；系统界面、日期选择器、链接和滚轮使用 XCTest 查询与操作，同页普通控件沿用各自的快速查询；同一界面状态中的 App 查询按完整查询范围复用结果，场景就绪核对实际渲染树中的场景标识、初始入口与选中状态，并通过原生快照补充读取；滚动定位和导航返回共用原生快照；界面操作与等待轮询刷新读取，原生存在性复用当前快照中的目标，快照缺少目标时通过 XCTest 实时查询确认。普通字段通过实际 UITextInput 设置完整选区并 insertText，随后核对完整字段值和业务结果；公共字段合同核对真实触摸聚焦、键盘完成及聚焦前后的输入绑定，登录、密码、键盘提交及公共 TextView 合同保留系统键盘输入，输入前点击控件中心并等待完成按钮附件就绪；替换已有文本时选中全文，通过系统键盘删除并核对空值，再输入新文本。键盘收起通过实际按钮动作与系统键盘通知验证，原生键盘合同同时核对 XCTest 界面状态。查询合同逐项与原生 XCTest 比较，并核对场景标识、窗口坐标及确认框控件；明确限定确认框的查询共用实际渲染树，渲染树缺少的控件与底层页面存在性通过原生查询确认；提示关闭使用明确的“知道了”动作。按钮合同同时覆盖原生点击和无障碍激活，共享开关合同比较实际触摸、控件事件与持久化；各页面继续验证自身绑定和确认流程，大字号可触达范围采用原生检查。多个筛选项共享一次 Runner 和 App 会话，结束后恢复常规 App：

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh ui LongPress CustomSchedule
Scripts/run-extended-tests.sh ui SchoolDDL DDLEmpty
```

快速开发时，将本次改动涉及的场景合并到一次真机调用。例如日期编辑的两项复验，耗时以该批次的 `test-metrics.txt` 为准：

```sh
Scripts/run-extended-tests.sh ui CustomSchedule DDLEditor
```

完整交互验收执行 `Scripts/run-extended-tests.sh ui`。用例与控件映射、平台专项范围见 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)；运行结果与耗时保存在固定日志和 `test-metrics.txt` 中。

稳定的 `accessibilityIdentifier` 用于字段、编辑入口和共用搜索排序菜单（`search.sort`）定位；主 Tab 使用实际标签栏内的按钮名称。普通按钮定位、状态和可触达检查共用 App 内渲染查询，原生查询承接平台界面、链接、滚轮、枚举操作及渲染查询缺少的目标；动态列表按当前查询位置重新定位，按钮事件使用查询命中的实际控件，导航动作等待目标页面。准备定位时使用真实 UIScrollView 的可见区域滚动；显式滚动与刷新合同保留 XCTest 手势。手势从同一次快照读取滚动范围，通过 App 原点与固定坐标执行，横向标签列表依据高度排除。失败的原生元素树和截图保存在既有 `.xcresult`，状态等待失败同样采集附件。

UI 组采集逐用例结果和耗时，交互覆盖依据 `docs/UI_INTERACTION_COVERAGE.md`；逻辑测试组采集生产源码行覆盖率。UI 测试构建关闭行覆盖率插桩，宿主关闭系统调试日志，测试计划通过 `uiTestingScreenshotsLifetime: keepNever` 关闭自动截屏 / 录屏。业务断言失败时仍手动保存截图和元素树，附件和摘要复用同一次元素树快照。[Apple 的 Xcode 发行说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes/)说明了自动录屏及测试计划配置。

UI 专用 scheme 使用 Release 直接启动配置，脚本先增量构建测试宿主，再通过生成的同一份 `.xctestrun` 执行 `test-without-building`；目标 App 的主线程及线程性能诊断选项由运行配置统一设置。此流程沿用共享编译缓存和固定产物路径。菜单的控件入口沿用 [UIControl.performPrimaryAction](https://developer.apple.com/documentation/uikit/uicontrol/performprimaryaction()) 的公开行为。[Apple 性能测试指导](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)说明了 Release 和直接启动设置，[命令行测试说明](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)说明了构建与测试分离的执行方式。

场景夹具可指定初始 Tab 和设置页，每个设置入口保留实际点击覆盖；页面控件继续通过真实 UI 操作与业务断言验证。按钮在当前呈现页面解析并激活，每次滚动后重新检查目标可点击状态；图片入口点击画布中心，系统预览直接查询 `QLPreviewControllerView`。出现、消失和值变化等待先核对当前结果，满足断言时立即继续。Quick Look 冷启动采用最长 30 秒的条件等待。关闭预览、草稿或日期弹窗后，确认弹窗消失再继续。日期弹窗定位原生 `PopoverDismissRegion` 按钮，关闭坐标限制在来源表单内并优先选择浮窗左侧；分享浮窗选择面积最大的可见外部区域关闭；日历翻月、年月滚轮、日期网格和逐列时间滚轮均关联状态断言。时间滚轮使用短距离快速拖动并停留后释放，核对变化后通过数字选项恢复原值，再保存合法的起止时间。

耗时记录标注运行平台、构建与运行总时长，以及用例耗时合计；前后比较使用同一平台的实际结果，同时保留独立数据重置、持久化重新读取和全部业务断言。复验通过直接填写多个用例关键词集中到一个批次；常规 Release App 在真机批次结束后恢复。

文章编辑复用详情页已解析的正文，由详情页导航承接；编辑与删除成功后刷新文章列表和搜索结果。回归核对标题、简介与正文恢复、保存后返回详情、再次编辑及取消保留已保存内容，删除验收同时核对原始和修改后的标题。文章评论使用独立输入弹窗。验证码提交先结束输入焦点，逐位输入通过系统键盘验证手动提交；整段验证码通过实际 UITextInput 插入验证自动提交、错误后修改重试及各认证业务继续，模块测试验证插入内容、长度边界及部分编辑策略。验证码输入从 SwiftUI 标准禁用环境读取提交状态，控件状态与焦点遵循同一环境。验证码原生输入合同随键盘合同在 XCTest 阶段串行执行，业务测试沿用 Swift Testing 并行执行。原生组件测试先完成真实聚焦，通过公开布局接口更新当前控件，在用例统一时限内等待状态更新，验证连续填入时的请求去重、验证码快照、输入禁用及提交结束后的重试。

读取本次结果与逐项耗时、检查某项失败的界面元素树：

```sh
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh report 'LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist()'
Scripts/run-extended-tests.sh screenshot 'LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch()'
Scripts/run-extended-tests.sh activities 'LoginAndScheduleUITests/testPaperPublishEditCommentAndDelete()'
Scripts/run-extended-tests.sh diagnostics
```

单项元素树覆盖写入 `.build/extended-automation/failure-hierarchy.txt`，便于编辑器检索；失败截图覆盖写入 `.build/screenshot.png`。`activities` 展示最近 30 条操作和失败记录；`diagnostics` 将完整诊断临时导出到固定 `.build/extended-automation/diagnostics/`，排查结束后清理。UI 指标统计提取 Runner 标准输出并追加到固定 `ui-tests.log`，处理结束即删除诊断副本；下一次测试清理诊断导出目录。

交互列表的左侧标题由 SwiftSyntax 审计检查公共主题色或警示色修饰器、标题组件及样式覆盖；UI 回归裁切“时间轴”的实际字形，检查彩色像素，覆盖源码规则和真实渲染两个层面。

`test-metrics.txt` 保存构建与运行总时长、用例耗时合计、最慢的十项、App 启动次数、进程 ID、系统交互动作、无障碍激活、输入更新和键盘完成动作，用于比较覆盖扩展后的执行成本。开发时通过多个用例关键词合并受影响的场景；完整覆盖验收运行整个 UI 组。真机专项验证承接真实照片选取、日历 / 提醒权限、外部邮件 / 浏览器交接、网页自身交互及 Widget / Watch 界面。UI Runner 的设备自动化初始化超时单独记录为环境阻塞；iOS 出现 Enable UI Automation 验证时，在手机端输入设备密码后重试，实际执行和通过数由 `.xcresult` 汇总。

仓库代码、测试、脚本、配置和文档文件最多 1000 行。`Scripts/check-file-lengths.py` 在静态审计与提交钩子中校验全部维护文件，职责拆分保持原有测试类与用例选择契约。质量和 UI 入口分别委托规则、自测与语法事实模块；公共组件规则验收组件声明和通用语义，业务交互沿 UI 用例验收。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/check-module-boundaries.py
```

统一入口汇总 SwiftSyntax 契约、UI 规则、客户端工程规范、模块依赖、文档链接、工程配置和锁定依赖检查。源码质量扫描覆盖 App、模块、扩展和 `ModuleTests/`；语法检查同时覆盖 UI 测试。客户端日志、社区日期和统一取消识别规则依据当前模块目录执行。Swift 词法扫描保留普通、原始、多行及嵌套字符串的插值表达式，全局资源访问在插值中同样接受检查。模块检查器自测导入解析、循环、依赖方向及全局资源访问约束，校验声明、实际导入、测试依赖以及 App 和扩展的直接产品依赖。源码事实由 `Scripts/swift_source_index.py` 提供共享 SwiftSyntax 索引。门禁维护依赖方向、资源归属、并发安全和设计系统通用规则；业务行为与同步合并由行为测试验证，文件规模进入人工审查候选。文档门禁校验仓库内引用，文档内容随永久代码变化维护。规则按职责由对应检查器维护；设计系统的入口与规则见 [设计系统](DESIGN_SYSTEM.md)。

模块检查器同时校验服务实现归属，覆盖生产源码中的直接网络发送、会话及网络缓存访问、重复系统网络监听、文件读写、元数据和符号链接解析，以及偏好默认实例选择。包级 `ClientCoreTests` 验证连接断开、恢复与实例隔离；App 的 `NetworkClientTests` 验证诊断文字消费所选网络状态。

SwiftSyntax 共享索引入口通过 `.build/static-audit/swift-syntax-indexer.lock` 串行使用源码及可执行产物，代码质量和 UI 检查器共用同一入口。源码更新、编译和索引读取在同一次锁内完成。

静态审计入口通过 `.build/static-audit/audit.lock` 串行维护固定日志；产物检查完成后，独立检查组并行执行并统一汇总失败。SwiftUI 规则共用语法树和已解析的渲染范围，词法扫描直接跳转到字符串或注释。

## 网络与 iCloud Smoke

网络 Smoke 使用正式 App 保存的会话、Cookie 与缓存，专用 Release 宿主完成探针后恢复常规 App：

```sh
Scripts/release-network-smoke.sh bit101
Scripts/release-network-smoke.sh school
Scripts/release-network-smoke.sh ddl
```

可选范围为 `all`、`bit101`、`school`、`transcript`、`schedule` 和 `ddl`。每个范围均维护必需探针清单，报告分别记录服务健康、执行探针和覆盖完整度。覆盖判定核对该范围的完整清单与实际执行记录，部分覆盖返回状态码 2。学校短信 challenge 记录为认证受阻，短信输入由真机流程验证；反馈探针在同一请求内创建、读取并清理临时报告。

DDL 范围覆盖社区登录、课程中心原生认证、课程中心作业读取、乐学订阅发现和 ICS 下载。原生认证探针使用独立 Cookie 容器，携带学校 SSO 会话完成课程中心认证。报告的 `eclassDDL` 记录认证结果、课程数、活动类型、有效截止时间数量、近期与未来作业数量及作业截止字段缺失数量，同时记录账号滞留天数、窗口内作业数量、课程中心缓存数量和截止时间范围。

课程中心接口参考 [Android PR #24](https://github.com/BIT101-dev/BIT101-Android/pull/24) 与[全课程分页提案](https://github.com/Star2121-1/BIT101-Android/pull/1)。`ModuleTests/Transport/EclassDDLTests.swift` 覆盖分页、作业字段、时间格式、并发、原生会话恢复、取消及生产服务到持久化的完整链路；`ModuleTests/Schedule/EclassDDLSyncTests.swift` 覆盖完成状态、部分失败、账号状态和过期窗口；`ModuleTests/Sync/ScheduleSyncTests.swift` 验证学校正文与完成状态的云同步边界。

模块测试使用受控响应验证未来作业经过生产服务、ViewModel、账号仓库、编码解码和重新加载后的显示与完成状态；真机 UI 使用隔离缓存验证实际交互。模块行覆盖率以 macOS 原生可执行源码为分母，App 与 UI 宿主分别采集覆盖率。学校短信分支通过共享 challenge 和原生会话测试验证，真实网络探针采用 preflight 模式。真实短信输入、系统权限、Widget / Watch 界面及真实照片选择由专项真机流程承接。

iCloud 双向验证要求 iPhone 与 Catalyst 使用同一 Apple ID，手机处于解锁状态、已登录 BIT101 账号并保存成绩缓存：

```sh
Scripts/run_icloud_cross_device_smoke.sh
Scripts/run_icloud_cross_device_smoke.sh report
Scripts/run_icloud_cross_device_smoke.sh cleanup
```

该专用流程通过 `ICLOUD_CROSS_DEVICE_SMOKE` 条件编译执行“真机 → Catalyst → 真机”。手机发布完整成绩缓存及本次业务域版本，Mac 核对完整载荷摘要和接收版本，再发布更新的业务域版本；手机核对 Mac 的新版本及完整载荷摘要。成绩正文与查询时间由现有缓存提供，同步版本由生产协调器生成。手机账号和有效成绩缓存作为准入条件。Mac 宿主通过公共存储端口注入手机账号会话，使用生产文件服务、偏好和同步协调器完成接收与发布。

两个宿主预先构建后并行执行，手机在同一测试进程内发布和接收，Mac 接收手机载荷后发布新版本。测试执行复用已构建宿主，运行阶段释放公共编译缓存锁。各宿主通过测试运行环境注入的同一运行标记选择本次协调记录。每个宿主要求一项用例执行并通过；宿主结果汇总到 `.build/icloud-cross-device-smoke/report.json`，完整结果包保存最近的业务验证阶段。异常清理保留该结果包并记录独立清理状态。错误钩子覆盖函数内部失败，信号钩子处理执行中断；故障注入自测验证恢复顺序和状态码。流程结束时恢复实验开关、协调数据和常规 Release App；聚合验证由外层统一恢复 App。中断后的恢复使用既有 `cleanup` 入口。`ICloudSmokeEvidenceTests` 通过离线用例验证旧版本、空缓存和同数量内容变化的验收边界。

获得全量测试及网络、iCloud 授权后，通过 `Scripts/run-extended-tests.sh verify` 聚合验证；可选择分组，定向 UI 复验使用 `ui 用例关键词...`。

## 固定产物与 CI

| 类别 | 固定路径 |
| --- | --- |
| 共享 SDK、模块与 SDK 状态缓存 | `.build/compiler-cache/` |
| 测试构建、结果与日志 | `.build/extended-automation/`，结果包 `test-results.xcresult` |
| 测试指标 | `.build/extended-automation/test-metrics.txt` |
| 包级测试日志 | `.build/extended-automation/module-tests.log` |
| 设备截图 | `.build/screenshot.png` |
| 网络 Smoke | `.build/release-network-smoke/report/release-network-smoke.json` |
| iCloud Smoke | `.build/icloud-cross-device-smoke/`，阶段报告 `report.json` |

同类产物覆盖既有路径，文件名使用稳定类别名。公共构建入口串行迁移及复用 SDK 缓存，各宿主的缓存目录链接到 `.build/compiler-cache/`，保留必要的增量中间文件。`Scripts/run-extended-tests.sh cache` 清理诊断残留及模拟器编译产物，并在依赖清单完整时清理未引用的 SDK 预编译模块；活跃平台的隐式模块缓存继续保留。文件内容和修改时间保持一致，日常构建直接复用热缓存。静态审计递归核对共享缓存链接及诊断残留，缓存自测覆盖合并、较新模块保留、重复整理、依赖引用、模块内容完整性和真机产物保留。终端直接展示测试汇总、审查候选与失败诊断，过滤重复进度、空章节和例行通过信息。终端展示必要摘要，完整输出保存在固定日志中。完整日志和报告覆盖既有路径。

缓存与诊断保持原始文件形式。工作流条件宏通过 `BIT101_WORKFLOW_CONDITIONS` 限定在 App 工程，共享包模块复用同一编译配置。UI 文件隔离由 App 文件服务提供，账号摘要沿用生产存储规则。脚本开发构建使用 `DEBUG_INFORMATION_FORMAT=dwarf` 和逐文件增量编译，调试信息保留在目标文件与链接产物中；发行归档沿用工程的 dSYM 和整模块优化设置，显式构建参数优先。缓存整理清理独立 dSYM 副本，运行包内部的调试资源继续保留；通过 Clang 模块元数据识别及清理停用平台的隐式模块。真机、Mac 和平台归属待核对的模块继续保留。

完整测试输出写入对应固定日志，终端显示汇总和失败摘要；模块日志保留 Swift Testing 的 suite、用例及参数执行记录。模块测试汇总七个消费者二进制，采集逐模块生产源码行覆盖率，真机测试采集逐 target 行覆盖率，指标固定覆盖 `test-metrics.txt`。模块覆盖率统计 macOS 宿主编译的可执行源码，iOS 界面由真机行为与 UI 用例补充。模块报告记录统计范围及总覆盖行数，CI 将逐模块指标写入 GitHub Job Summary，沿工作流执行记录保留覆盖率趋势。覆盖率采集异常进入失败状态；Catalyst 使用 runtime 提供的测试汇总。
测试入口通过 `.build/extended-automation.lock` 串行使用固定产物目录，聚合验证内的分组继承同一次执行锁和设备快照，结束时统一恢复常规 App。聚合验证与独立 UI 流程的恢复钩子覆盖函数内部错误和执行中断，并保留原始失败状态码。独立 UI 流程从测试执行阶段开始恢复常规 App，宿主编译失败时直接结束。编译宿主时保留既有测试结果包、指标和运行日志，编译日志使用固定 `<分组>-build.log`。长流程从入口读取完整脚本到内存后执行，加锁等待结束时读取当前版本，保证执行期间的文件编辑与当前流程各自稳定。SwiftSyntax 索引器在 `.build/static-audit/` 编译并复用，源码或工具链变化时覆盖重编译，编译与调用共用文件锁。

GitHub Actions 的 `.github/workflows/ci.yml` 使用 `xcode-27` runner，先执行静态审计与包级测试，再并行执行 iOS 宿主构建 Job 和独立的 Catalyst 行为 Job。iOS Job 顺序编译正式 Release、UI 和两种 Smoke 的测试宿主，App 依赖图同时编译 Watch 和两种 Widget，Swift / Clang 警告按错误处理。审计自测核对两个 Job 的默认执行、静态依赖及各自必备入口。版本、plist 和 PR 基线在静态 job 校验，手动 `release_check` 校验公开版本。

本机承接真机行为、UI、网络和 iCloud 验证；发布操作按对应授权执行。

验证证据由 `Scripts/validation_evidence.py` 维护，固定保存为 `.build/extended-automation/validation-evidence.json`。证据文件记录源码摘要，每组保存执行范围、退出状态及独立结果摘要。测试摘要包含总数、通过、失败、跳过和逐模块覆盖率；网络摘要包含执行探针、认证和覆盖情况，iCloud 摘要包含双端阶段结果，CI 记录关联工作流。后续宿主覆盖指标文件时，各组摘要继续保留；源码变化后按当前内容重建证据。`Scripts/run-extended-tests.sh verify` 完整执行模块、真机行为、Catalyst、UI、网络、iCloud 和静态审计，恢复常规 App 后返回聚合结果。发布提交完成后执行 `python3 Scripts/validation_evidence.py bind`，完整通过且源码摘要一致时绑定提交；CI 将各 Job 的已执行结果写入 GitHub Job Summary。手动工作流开启 `release_check` 时，在 `validation_evidence` 输入粘贴绑定后的证据 JSON；`python3 Scripts/validation_evidence.py check` 核对完整分组、当前源码及发布提交。编译组与行为组在证据中分别记录执行范围和结果。
