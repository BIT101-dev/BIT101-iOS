# 构建与测试

首次准备开发电脑时，按 [新电脑开发环境](SETUP.md)安装工具并配置 Xcode、账号和签名。

## 执行约定

- 构建使用 Xcode 27.x、有效签名和已连接并受信任的真机，默认完成 Release 构建、装机与启动。
- 本机构建、装机和启动统一使用 `Scripts/build-install-device.sh`；脚本封装所需 Xcode 流程。
- iOS / watchOS 验收与日常 UI 复验使用真机；包级逻辑测试使用 macOS 原生宿主，Catalyst 行为与正式组装测试使用 macOS runtime，测试宿主采用本机免签名构建。
- `all` 与 Catalyst 离线行为宿主使用空场景、内存凭据及云偏好、独立偏好域和固定隔离文件根目录。默认传输核对回环地址，消费者测试显式提供受控响应；真实网络由专项 Smoke 验收。正式运行时合同沿 `release-runtime` 的生产编译条件执行。
- 测试、静态审计、网络 Smoke 和 iCloud Smoke 按用户明确授权的范围执行。失败修复后重跑受影响的分组。
- 界面验证使用既有 UI 测试、截图脚本与命令行流程。设备自动化授权由 iOS 管理，系统要求时由用户在设备上输入密码，设备继续保留密码保护。
- `BIT101-iOSTests/Fixtures/` 和测试 target 内的样例、fixture、校准及人工准备数据属于长期资产，沿用固定路径。清理或改写前确认来源、用途和恢复方式，并取得用户明确同意。

## 脚本入口

脚本按完整工作流组织，公共设备选择与日志处理集中在 `Scripts/script-support.sh`。入口数量保持精简，同一工作流通过参数选择操作；优化以执行耗时、重复调用和终端信息价值为依据。静态审计复用索引器并缓存路径判断。

iCloud 验收在同一主机共用用户级流程锁，每次运行沿所属标识选择独立云端验收账号，恢复使用固定报告中的所属标识。构建安装、行为测试和独立 Smoke 共用流程锁，锁覆盖宿主安装、执行、固定报告写入及常规 App 恢复；聚合验证的子流程复用所持有的锁。iCloud 后台任务加载共享阶段函数，阶段计数沿宿主的结构化测试结果读取，通过阶段完成归集后清理生成结果；失败阶段将原始结果包及附件保留到所属宿主 `Logs/Test/test-results.xcresult`，阶段报告记录诊断位置。iCloud 清理结果及其阶段计数单独保存，独立恢复形成 `icloud-cleanup` 证据，业务阶段用于双向同步验收。

iCloud 成绩验收使用无害的合成完整载荷、独立验收账号和磁盘仓库，覆盖成绩 KVS 与课表 CloudKit，成绩密文沿真实 iCloud 钥匙串传递密钥，同步接收与发布后重新打开日程和成绩仓库核对完整载荷，完成后清理验收云端键、密钥、独立磁盘目录及偏好。重置验收偏好前完成遗留密钥删除，删除失败时保留密钥标识。跨设备阶段共享五分钟传播期限，外部变更通知与钥匙串等待驱动重新核对，KVS 同步请求沿启动和写入触发。采样宿主独立启动，网络与 iCloud 专项各自组装所需服务。学校网络探针使用独立内存 Cookie 容器和已保存凭据重新启动认证，各认证目的保留实际短信挑战与业务继续证据。原始课表响应采样由当前 Smoke 服务实例持有。双端清理验收从远端确认验收 KVS 键、协调键与 CloudKit 记录均已删除。

| 工作流 | 入口 |
| --- | --- |
| 构建、装机、截图、设备信息 | `Scripts/build-install-device.sh` |
| 模块、App、UI、Catalyst 与聚合验证 | `Scripts/run-extended-tests.sh` |
| 语法、工程、依赖、文档与设计规则审计 | `Scripts/run-static-audit.sh` |
| 网络探针与范围选择 | `Scripts/release-network-smoke.sh 范围` |
| iCloud 双向验证、报告与恢复 | `Scripts/run_icloud_cross_device_smoke.sh` |
| Issues、CI 失败与反馈报告管理 | `Scripts/fetch-issues-and-reports.sh` |

输出处理器自测覆盖诊断展示阈值、CI 失败诊断、完整留档、信号退出状态及执行期间改写源码的故障注入。CI 从 Worker 锁文件安装直接声明的测试依赖，再执行静态审计。CI 失败时展示过滤后的完整诊断，供远端直接定位错误。Xcode 默认临时错误结果包在命令结束后自动清理。测试结果保存在既有固定日志与结果包中；`Scripts/run-extended-tests.sh report` 读取最近一次模块、App 或 UI 测试结果，`report coverage` 读取 Xcode 原始覆盖率 JSON。

验证组、产物归属、默认验收顺序与平台覆盖率基线通过 [验证策略](../Scripts/validation_policy.py) 集中登记；模块边界核对覆盖率登记与生产模块集合，ActivityKit 合同归属 iOS 覆盖率验收。网络验证分组共用登记集合，完整链路自测覆盖各组成功与失败报告的记录及 `check-group` 验收。构建分派自测使用内存替身，UI 运行配置处理通过内存 plist 验证最新产物选择、诊断设置和业务 target 配置保留，并覆盖冷缓存中的运行配置完整性检查。审计接线自测核对每个分组对应的实际回调，替换模块边界或产物维护回调的变异样例必须触发检查失败。内嵌 Python 语法审计覆盖 heredoc 的单引号、双引号、无引号、空格及制表符剥离写法，正确与错误语法分别校验。静默异常检测通过 SwiftSyntax 读取空 catch 语句体，覆盖通配、绑定及类型匹配写法。生命周期请求审计沿跨文件方法、构造器、工厂返回类型与保存的方法引用传播；闭包参数按直接调用和参数传递识别执行关系，成员构造器保存的闭包与交互回调按登记边界处理。

工作流沿 Python 默认优化级别执行自测；独立验证器核对断言执行环境。发布 CI 的验收与汇总共用证据记录环境。构建、测试、Smoke 和报告管理入口均提供 `--help`。质量、UI、模块边界、文档引用与版本检查器保留独立入口，便于针对单项问题执行；统一审计通过共享 SwiftSyntax 索引执行质量与 UI 检查，并输出解释文案审查候选。地图 fixture 生成使用 `Scripts/generate_campus_map_fixture.py <教务导出.xlsx>`，按校区及原始地点合并保留历史案例。`--allow-new` 将新增地点写为 `review=pending`，人工审核后选择 `mapped` 并填写 `expected`，或选择 `excluded` 并保留 `expected=null`；静态审计与回归测试要求审核完成。历史案例清理沿既有人工审核和固定数据路径约定。

## 构建、装机与截图

```sh
Scripts/build-install-device.sh
Scripts/build-install-device.sh build
Scripts/build-install-device.sh archive
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

`build` 使用通用 iOS 目的地编译 Release App 及扩展，产物覆盖 `build/DeviceInstall/`。行为测试、专项 Smoke、恢复安装和归档沿工程编译及符号设置执行，Release 使用整模块优化。`archive` 使用工程正式归档配置验证整模块优化及 dSYM，归档固定覆盖 `build/DeviceInstall/BIT101-iOS.xcarchive`，CI 同样执行该入口。真机行为、系统权限和实际跨端传输由设备测试验证。

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
| `catalyst-release-runtime` | Mac Catalyst 正式编译条件下的生产行为及组装合同 |
| `release-runtime` | 真机正式编译条件；生产账号会话、网络状态、警告中心与反馈环境组装 |

```sh
Scripts/run-extended-tests.sh modules
Scripts/run-extended-tests.sh
Scripts/run-extended-tests.sh schedule
Scripts/run-extended-tests.sh infrastructure
Scripts/run-extended-tests.sh login
Scripts/run-extended-tests.sh extensions
Scripts/run-extended-tests.sh catalyst
Scripts/run-extended-tests.sh catalyst-release-runtime
Scripts/run-extended-tests.sh release-runtime
```

快捷行为分组沿 `Scripts/validation_test_areas.py` 的显式领域归属选择全部 suite；静态审计核对新增 suite 的归属及失效登记，学校账号隔离同时属于登录和基础设施。完整分组核对实际执行方法集合；手选类或方法保留为定向范围。编译条件由当前 Swift 编译器沿宿主目标、SDK 与工作流标志求值，支持框架可用性及 Swift / 编译器版本谓词。包级测试由 `Package.swift` 的 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个消费者 target 管理，代码位于 `ModuleTests/`，使用内存传输、文件服务、偏好和实例级变更流。

覆盖话廊分页去重、预取游标与搜索代际，主页刷新、分页失败重试和账号场景隔离，日程整体格式迁移、课程编辑及权威快照，发帖编辑与上传生命周期、草稿损坏和格式版本保护、历史草稿及图片迁移、账号目录与文件保存失败保护、社区身份与恢复隔离、日程保存排队、精确版本往返与过期比较令牌、文件损坏和账号切换、生产成绩服务注入、独立成绩与消息存储端口、变更流的实例及账号归属、共享草稿图片准备和版本清理、同步冲突及地图身份规则。本地文件元数据故障测试验证读取能力及旧内容保留。社区持久化测试通过 `CommunityPersistence` 的公共入口运行。测试用内存文件服务集中于 `ModuleTests/Support`，直接依赖 StorageCore。学校课表解析沿用 `BIT101-iOSTests/Fixtures/schedule-service-response.json`。

课程与文章服务契约测试覆盖分页、特殊课程号路径、Snake Case 解码、认证恢复、评论及文章写入；课程详情场景覆盖刷新代际、失败保留、评论去重、历史成绩重试、回复身份及点赞；学校响应测试覆盖业务失败、认证失效、格式变化和 HTTP 状态分类，教学中心会话覆盖认证、预热复用和短信 challenge，乐学订阅覆盖安全 URL 与已完成日程保留。云同步测试同时验收成功、待同步、失败和账号不可用状态。MapKit 页面、UIKit、Quick Look 和可信成绩单展示通过 App 宿主验证。

`FeatureCompositionTests` 在 App 宿主组合不同的环境依赖，验证课程、Gallery → Paper、Paper、Mine、Profile、Schedule、Score 的构造归属，恢复所选课表与成绩缓存，并验证同一宿主中 Paper / Gallery 依赖替换的场景重建。`MediaDependencyTests` 验证内存存储、静态 / GIF 解码和预览字节；`SuggestionDependencyTests` 验证草稿及提交归属；同文件的 `AppLocalDataOwnershipTests` 与 `SettingsDependencyOwnershipTests` 验证清理动作顺序、失败汇总、后端隔离和设置媒体 / 账号归属。`PreferenceMergeTests` 使用独立设备偏好与云存储验证离线字段合并、已读并集、同版本收敛、可选字段清除与重载。`LoginStorageTests` 使用注入凭据后端验证事件代际、实例隔离、迁移和写入失败；提醒规划及同步状态呈现通过纯输入与账号事件验证。`ExperimentalPreferenceCloudSyncTests` 使用独立账号事件流和平台替身验证生命周期实例隔离及所选课程源向成绩场景传递。

按现有测试类或方法选择范围，多个筛选项在同一次调用执行。Swift Testing 方法名保留 `()`，suite 名称用于整组运行；脚本展开并保存请求清单，逐项核对实际执行集合与通过数量：

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

`BIT101-iOSUITests` 使用 `BIT101-iOS-UIAutomation` Release scheme 和真机宿主。`BIT101_UI_TESTING` 构建隔离 Keychain、偏好、账号文件和媒体缓存，使用合成会话及离线服务。测试文件归 App 内固定的 `Application Support/BIT101-UITests/` 根目录，系统日历与提醒动作使用内存端口，偏好云同步使用内存云存储。正式 App 由生产组装入口启动。UI 宿主在前台保持屏幕常亮。渲染查询归 `Login/UITestAccessibilityActions.swift`，启动配置与响应夹具归 `Login/AppUITestBootstrap.swift`。交互流程默认通过 XCTest 原生触摸、滚动和系统键盘执行，触达判断、快速控件动作和字段输入共用 XCTest 原生可触达状态；公共查询合同覆盖页面内遮挡并显式选择快速控件动作。测试窗口沿用系统默认动画速度。测试默认关闭 UIKit 动画；连续编辑、短信重试、媒体预览和多层弹窗场景启用系统动画，验证导航与输入生命周期。动画场景核对实际窗口速度及动画启用状态。

日常 UI 复验使用 `Scripts/run-extended-tests.sh ui`，用例关键词直接接在 `ui` 后面，按测试类与方法名匹配并合并为一个批次，完整测试类/方法同样适用。关键词选择、文档库存与执行清单共用递归 SwiftSyntax 库存。例如 `ui About` 执行关于页面，`ui DDL Calendar` 合并 DDL 和日历相关流程。测试宿主编译使用 `build ui`。56 项通过 `UIAutomationTestCase` 串行复用一个 App 进程，每次场景配置校验进程 ID；完整映射见交互覆盖表。

真机运行期间保持 BIT101 前台并暂停手动操作。场景切换时，后台 App 通过 `activate()` 返回前台，并继续校验原进程 ID。第三方输入法可能提供键盘画面而缺少 XCTest 键盘元素；输入助手通过系统“下一个键盘”按钮切换到原生键盘，再执行输入与完整字段值断言。

UI 用例按页面组合连续交互；公共组件完整合同集中验收一次，各页面验证入口、绑定和业务结果，每项独立重置隔离数据；持久化场景重新创建模型和根视图，从文件与偏好重新读取。测试 App 与 Runner 通过 TransportCore 内测试专用的 `127.0.0.1:19101` 通道更新夹具配置，全部场景保持同一 App 进程。测试 App 使用简体中文和中国地区，系统控件文案与日期格式保持一致。覆盖目标包括每个点击、滑动、输入、VoiceOver 自定义动作和键盘快捷键入口，并验证交互后的业务状态。自定义动作调用已渲染控件的公开无障碍动作，键盘默认操作通过 XCTest 发送 Return 键；交互库存分别核对所属动作证据。当前定义 56 项用例，公共组件合同和页面接入共同承接完整交互，逐项映射和运行验收状态见 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)：

| 页面 | 交互范围 |
| --- | --- |
| 登录与主导航 | 必填字段、键盘及按钮提交、滚动收起键盘、账号隔离、五个 Tab、浅深色辅助功能大字号 |
| 课表 | 周次按钮及拖动、分栏横滑、长按菜单、添加 / 编辑 / 删除日程、日期时间选择器、课程补录 / 调课 / 删除、日期放假 / 调休确认、上下滑切换分享课表、线性时间轴滚动和双指缩放 |
| 日程设置 | 时间轴、时间表校验 / 保存 / 取消、学期切换 / 下拉刷新、日期滚轮、开关 / 提醒阈值持久化、名称、编码复制 / 粘贴导入 / 分享、新版本编码更新提示、分享课表改名 / 左滑删除、整学期及单项日历导入 / 移除 |
| DDL 与空教室 | 学校双来源、详情、完成状态、手动待办增改删、日期时间及详情编辑、学校刷新 / 订阅链接刷新 / SSO 短信继续、校区 / 楼宇选择、教室刷新、节次多选 / 全选 / 清除 |
| 成绩与课程 | 查询及刷新短信错误重试 / 取消、逐项及批量筛选、排序、已出分 / 未出分详情、课程评价路由、可信成绩单多页预览、课程搜索 / 清除、数据清洗、历史图拖动、点赞、半星评分 / 匿名评论 / 回复 / 评论图片 / 分享 |
| 地图 | 校区、图层、平移、缩放、定位 / 单次权限授权、课程地点路由、下一节课系统地图导航、重新装载恢复 |
| 话廊与文章 | 分类点击及横滑、搜索 / 清除 / 排序 / 结果路由、消息横滑 / 分类 / 已读 / 详情、列表及详情下拉刷新、发布校验 / 标签 / 声明 / 开关 / 草稿、编辑器下拉关闭保护与后台返回输入保留、发布 / 修改 / 删除、图片预览 / 上传重试 / 图片移除、正文链接、点赞、评论排序 / 点赞 / 回复、长按复制 / 举报 / 删除及确认 / 取消、分享、离线重试及恢复 |
| 我的与设置 | 个人统计列表 / 刷新、公开主页统计显示与帖子入口、关注状态、头像预览 / 选择器取消、个人帖子详情 / 删除、标识显示 / 隐藏、资料保存 / 取消 / 登录检查 / 退出、屏蔽 UID 校验、网页话廊 / 滚动 / 切回原生、偏好及缓存上限持久化、建议草稿 / 图片 / 提交确认 / 成功 / 失败、错误报告模式及提交分支、开源声明 / 外部链接 / 更新提示全部动作 / 缓存清理 / 确认重置、网络诊断 |

`BIT101_UI_TEST_CONTENT=1` 选择内存 HTTP 固定响应，并经过生产社区 Service 的解码与状态逻辑；默认场景使用离线失败响应。响应维护当前测试场景的点赞、评论、关注、资料和文章 / 话题增改删状态，新增内容可以在后续详情请求中读取。学校、媒体、单次失败和更新响应配置见交互覆盖文档。页面发出的外部 URL 在 UI 宿主显示完整目标地址，地图导航使用系统 Maps。普通控件通过 App 内当前渲染的无障碍树读取标识、文案、布局和状态，可触达判断结合窗口命中测试、当前呈现页面范围及原生查询；同一显示帧内复用渲染快照，控件事件、原生操作记录及场景切换立即使缓存失效。

SwiftUI 控件通过公开的无障碍激活动作执行真实事件，UIKit 按钮通过命中位置的实际控件事件执行，导航栏按钮发送实际 UIBarButtonItem 的 target/action 或实际控件的 UIAction，菜单入口通过实际 UIControl 的 performPrimaryAction 或 XCTest 操作，消费页面使用当前可见菜单的实际 UIAction，共享菜单合同保留原生选项点击；系统界面、日期选择器、链接和滚轮使用 XCTest 查询与操作，同页普通控件沿用各自的快速查询；同一界面状态中的 App 查询按完整查询范围复用结果，场景就绪核对实际渲染树中的场景标识、初始入口与选中状态，并通过原生快照补充读取；滚动定位和导航返回共用原生快照；界面操作与等待轮询刷新读取，原生存在性复用当前快照中的目标，快照缺少目标时通过 XCTest 实时查询确认。

普通字段通过实际 UITextInput 设置完整选区并 insertText，随后核对完整字段值和业务结果；公共字段合同核对真实触摸聚焦、键盘完成及聚焦前后的输入绑定，登录、密码、键盘提交及公共 TextView 合同保留系统键盘输入，输入前点击控件中心并等待完成按钮附件就绪；替换已有文本时选中全文，通过系统键盘删除并核对空值，再输入新文本。键盘收起通过实际按钮动作与系统键盘通知验证，原生键盘合同同时核对 XCTest 界面状态。查询合同逐项与原生 XCTest 比较，并核对场景标识、窗口坐标及确认框控件；明确限定确认框的查询共用实际渲染树，渲染树缺少的控件与底层页面存在性通过原生查询确认；提示关闭使用明确的“知道了”动作。按钮合同同时覆盖原生点击和无障碍激活，共享开关合同比较实际触摸、控件事件与持久化；各页面继续验证自身绑定和确认流程，大字号可触达范围采用原生检查。

多个筛选项共享一次 Runner 和 App 会话，结束后恢复常规 App：

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

稳定的 `accessibilityIdentifier` 用于字段、编辑入口和共用搜索排序菜单（`search.sort`）定位；主 Tab 使用实际标签栏内的按钮名称。普通按钮定位与状态读取复用 App 内渲染查询，原生 XCTest 核对可触达状态并执行触摸、滚动、输入和平台控件操作。公共查询合同显式切换快速动作路径，并与原生状态比较。动态列表按当前查询位置重新定位，导航动作等待目标页面。手势从同一次快照读取滚动范围，通过 App 原点与固定坐标执行，横向标签列表依据高度排除。失败的原生元素树和截图保存在既有 `.xcresult`，状态等待失败同样采集附件。

UI 组采集逐用例结果、耗时及生产源码行覆盖率，交互覆盖依据 `docs/UI_INTERACTION_COVERAGE.md`；逻辑测试组采集生产源码行覆盖率。UI 测试构建启用行覆盖率插桩，宿主关闭系统调试日志，测试计划通过 `uiTestingScreenshotsLifetime: keepNever` 关闭自动截屏 / 录屏。业务断言失败时仍手动保存截图和元素树，附件和摘要复用同一次元素树快照。[Apple 的 Xcode 发行说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes/)说明了自动录屏及测试计划配置。

UI 专用 scheme 使用 Release 直接启动配置，脚本先增量构建测试宿主，再通过生成的同一份 `.xctestrun` 执行 `test-without-building`；目标 App 的主线程及线程性能诊断选项由运行配置统一设置。此流程沿用共享编译缓存和固定产物路径。菜单的控件入口沿用 [UIControl.performPrimaryAction](https://developer.apple.com/documentation/uikit/uicontrol/performprimaryaction()) 的公开行为。[Apple 性能测试指导](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)说明了 Release 和直接启动设置，[命令行测试说明](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)说明了构建与测试分离的执行方式。

场景夹具可指定初始 Tab 和设置页，每个设置入口保留实际点击覆盖；页面控件继续通过真实 UI 操作与业务断言验证。按钮在当前呈现页面解析并激活，每次滚动后重新检查目标可点击状态；图片入口点击画布中心，系统预览直接查询 `QLPreviewControllerView`。出现、消失和值变化等待先核对当前结果，满足断言时立即继续。Quick Look 冷启动采用最长 30 秒的条件等待。关闭预览、草稿或日期弹窗后，确认弹窗消失再继续。日期弹窗定位原生 `PopoverDismissRegion` 按钮，关闭坐标限制在来源表单内并优先选择浮窗左侧；分享浮窗选择面积最大的可见外部区域关闭；日历翻月、年月滚轮、日期网格和逐列时间滚轮均关联状态断言。时间滚轮使用短距离快速拖动并停留后释放，核对变化后通过数字选项恢复原值，再保存合法的起止时间。

耗时记录标注运行平台、构建与运行总时长，以及用例耗时合计；前后比较使用同一平台的实际结果，同时保留独立数据重置、持久化重新读取和全部业务断言。复验通过直接填写多个用例关键词集中到一个批次；常规 Release App 在真机批次结束后恢复。

文章编辑复用详情页已解析的正文，由详情页导航承接；编辑与删除成功后刷新文章列表和搜索结果。回归核对标题、简介与正文恢复、保存后返回详情、再次编辑及取消保留已保存内容，删除验收同时核对原始和修改后的标题。文章评论使用独立输入弹窗。验证码提交先结束输入焦点，逐位输入通过系统键盘验证手动提交；整段验证码通过实际 UITextInput 插入验证自动提交、错误后修改重试及各认证业务继续，模块测试验证插入内容、长度边界及部分编辑策略。验证码输入从 SwiftUI 标准禁用环境读取提交状态，控件状态与焦点遵循同一环境。验证码原生输入合同随键盘合同在 XCTest 阶段串行执行，业务测试沿用 Swift Testing 并行执行。原生组件测试先完成真实聚焦，通过公开布局接口更新当前控件，在用例统一时限内等待状态更新，验证连续填入时的请求去重、验证码快照、输入禁用及提交结束后的重试。

读取本次结果与逐项耗时、检查某项失败的界面元素树：

```sh
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh report json
Scripts/run-extended-tests.sh report 'LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist()'
Scripts/run-extended-tests.sh screenshot 'LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch()'
Scripts/run-extended-tests.sh activities 'LoginAndScheduleUITests/testPaperPublishEditCommentAndDelete()'
Scripts/run-extended-tests.sh diagnostics
```

单项元素树覆盖写入 `.build/extended-automation/failure-hierarchy.txt`，便于编辑器检索；失败截图覆盖写入 `.build/screenshot.png`。`activities` 展示最近 30 条操作和失败记录；`diagnostics` 将完整诊断临时导出到固定 `.build/extended-automation/diagnostics/`，排查结束后清理。UI 指标统计提取 Runner 标准输出并追加到固定 `ui-tests.log`，处理结束即删除诊断副本；下一次测试清理诊断导出目录。

交互列表的左侧标题由 SwiftSyntax 审计检查公共主题色或警示色修饰器、标题组件及样式覆盖；UI 回归裁切“时间轴”的实际字形，检查彩色像素，覆盖源码规则和真实渲染两个层面。

`test-metrics.txt` 保存构建与运行总时长、用例耗时合计、最慢的十项、App 启动次数、进程 ID、系统交互动作、无障碍激活、输入更新和键盘完成动作，用于比较覆盖扩展后的执行成本。开发时通过多个用例关键词合并受影响的场景；完整覆盖验收运行整个 UI 组。真机专项验证承接真实照片选取、日历 / 提醒权限、外部邮件 / 浏览器交接、网页自身交互及 Widget / Watch 界面。UI Runner 的设备自动化初始化超时单独记录为环境阻塞；iOS 出现 Enable UI Automation 验证时，在手机端输入设备密码后重试，实际执行和通过数由 `.xcresult` 汇总。

仓库代码、测试、脚本、配置和文档文件最多 1000 行。`Scripts/check-file-lengths.py` 在静态审计与提交钩子中校验全部维护文件，职责拆分保持原有测试类与用例选择契约。质量和 UI 入口分别委托规则、自测与语法事实模块；公共组件规则验收组件声明和通用语义，业务交互沿 UI 用例验收。提交钩子的文件行数与文档链接检查读取完整暂存区，故障用例覆盖暂存内容与工作树不同、暂存删除及文件仅存在于暂存区的情况。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/check-module-boundaries.py
```

统一入口汇总 SwiftSyntax 契约、UI 规则、客户端工程规范、模块依赖、文档链接、工程配置和锁定依赖检查。源码质量扫描覆盖 App、模块、扩展、`ModuleTests/`、App 行为测试和 UI 测试，统一检测强制解包、强制错误处理、强制类型转换和并发逃逸。客户端日志、社区日期和统一取消识别规则依据当前模块目录执行。Swift 词法扫描保留普通、原始、多行及嵌套字符串的插值表达式，全局资源访问在插值中同样接受检查。模块检查器自测导入解析、循环、依赖方向及全局资源访问约束，校验声明、实际导入、测试依赖以及 App 和扩展的直接产品依赖。源码事实由 `Scripts/swift_source_index.py` 提供共享 SwiftSyntax 索引。同一编译单元的类型继承与职责统一合并，View 请求和平台适配器资源检测覆盖跨文件扩展及嵌套类型作用域。门禁维护依赖方向、资源归属、并发安全和设计系统通用规则；业务行为与同步合并由行为测试验证，文件规模进入人工审查候选。文档门禁校验仓库内引用，文档内容随永久代码变化维护。规则按职责由对应检查器维护；设计系统的入口与规则见 [设计系统](DESIGN_SYSTEM.md)。

模块检查器同时校验服务实现归属，覆盖生产源码中的直接网络发送、会话及网络缓存访问、重复系统网络监听、文件读写、元数据和符号链接解析，以及偏好默认实例选择。包级 `ClientCoreTests` 验证连接断开、恢复与实例隔离；App 的 `NetworkClientTests` 验证诊断文字消费所选网络状态。

`Scripts/SwiftSyntaxIndexer.swift` 维护编译器提供的 SwiftSyntax 事实采集，`swift_source_index.py` 承接编译缓存与事实查询，模块边界的回归样例归 `module_boundary_tests.py`。SwiftSyntax 共享索引入口通过 `.build/static-audit/swift-syntax-indexer.lock` 串行使用源码及可执行产物，代码质量和 UI 检查器共用同一入口。源码更新、编译和索引读取在同一次锁内完成。`swift_type_index.py` 沿模块、访问范围及完整嵌套类型解析继承、别名与调用关系，泛型实参参与语法解析后保留其后续成员路径。

检测器由 App 维护者负责工具链升级与规则评审，规则作者维护触发、合规和故障回归样例。语法事实以当前 Xcode 的 SwiftSyntax 为来源，词法扫描用于编译条件与源码片段；类型解析覆盖模块、文件访问范围、继承、泛型嵌套类型及别名，调用分析覆盖已登记的实例、工厂返回值、协议实现和保存回调。编译生成的宏实现、动态分派与第三方二进制行为沿正式编译条件测试和真机验收核对。新增语法或规则在所属自测文件补充最小故障样例，并复用已有事实入口。

静态审计入口通过 `.build/static-audit/audit.lock` 串行维护固定日志；产物检查完成后，独立检查组并行执行并统一汇总失败。SwiftUI 规则共用语法树和已解析的渲染范围，词法扫描直接跳转到字符串、正则或注释，三元表达式正则参与自测。学校生命周期请求图覆盖实例属性初始化，保存的手动回调沿实际调用接入执行图；解释文案候选归 UI 源码事实模块维护。

正式运行组 `release-runtime` 沿正式 Release 编译条件执行组装合同，验收账号会话、实际网络状态、公共警告中心及反馈环境。完整验收同时核对实际执行用例与生产代码行覆盖率。`validation_evidence.py` 维护 macOS 可执行模块、iOS 可执行模块和 App 宿主的覆盖率基线；新增模块同步补充基线与消费者测试。`validation_test_areas.py` 登记账号代际、后台会话验证、取消、同步冲突、上传失败恢复及成绩快照比较的关键状态转换合同，静态审计核对其行为用例持续存在。UI 和 Catalyst 的验收分别沿用控件库存及平台测试结果。学校自动请求审计沿 App 与账号生命周期调用链追踪生产学校请求入口，故障注入覆盖入口改名和包装方法。通知回归核对时区与绝对触发时间，日历事务回归核对失败批次清理与后续提交隔离。

## 网络与 iCloud Smoke

学校采样报告记录 `requestedTerm`、`currentTerm`、`validatedTerm`，同步响应沿请求学期核对。`BIT101_NETWORK_SMOKE_TERM` 指定学期的网络及短信采样登记为定向验证；完整网络及学校短信验收沿服务端当前学期执行。

网络 Smoke 使用正式 App 保存的会话、Cookie 与本地业务缓存，专用 Release 宿主完成探针后恢复常规 App。探针 HTTP 传输关闭 URLCache，并逐请求强制从远端读取；学校业务缓存审计沿原有存储端口执行。Smoke 组装使用只读业务端口、外部 HTTP 客户端及反馈探针依赖，离线回归验证完整成功、中段失败、后续探针继续、报告保存与下一范围状态重置：

```sh
Scripts/release-network-smoke.sh bit101
Scripts/release-network-smoke.sh school
Scripts/release-network-smoke.sh ddl
```

可选范围为 `all`、`bit101`、`school`、`transcript`、`schedule` 和 `ddl`。每个范围均维护必需探针清单，报告分别记录服务健康、执行探针和覆盖完整度。覆盖判定核对该范围的完整清单与实际执行记录，部分覆盖返回状态码 2。学校短信 challenge 记录为认证受阻，短信输入由真机流程验证；反馈探针在同一请求内创建、读取并清理临时报告。

AASA 探针使用终止重定向的独立传输，核对原始 URL、HTTP 200、JSON 内容类型、128 KB 大小上限及三个分享路径的完整配置。离线编排用例覆盖重定向、响应类型及路径排除配置错误。发布版本查询与 App 更新查询通过请求时间参数及缓存刷新头获取商店版本。

消息列表探针以 `Int.max` 请求历史分页，续页采用前页最小消息 ID，空页采用正值 1，保留服务端未读提醒。[后端消息服务](https://github.com/BIT101-dev/BIT101-GO/blob/main/api/service/message.go) 将 `last_id` 为 0 的最新记录读取关联到未读数清零；离线用例覆盖空页后新消息到达时的提醒保留。报告写入异常进入失败结果，脚本通过真机控制台错误标记及时结束；原始课表采样包含本次运行标记，清理和写入错误进入报告。登录与采样、报告持久化通过依赖端口注入，离线故障用例覆盖采样清理、认证和报告写入失败及连续运行隔离。课表 Smoke 共用 `SmallTermWeekNormalizer` 的三周校正规则，并独立核对原始响应与生产解码结果；边界用例覆盖零、二、三、四周偏移。

DDL 范围覆盖社区登录、课程中心原生认证、课程中心作业读取、乐学订阅发现和 ICS 下载。原生认证探针使用独立 Cookie 容器，携带学校 SSO 会话完成课程中心认证。报告的 `eclassDDL` 记录认证结果、课程数、活动类型、有效截止时间数量、近期与未来作业数量及作业截止字段缺失数量，同时记录账号滞留天数、窗口内作业数量、课程中心缓存数量和截止时间范围。

课程中心接口参考 [Android PR #24](https://github.com/BIT101-dev/BIT101-Android/pull/24) 与[全课程分页提案](https://github.com/Star2121-1/BIT101-Android/pull/1)。`ModuleTests/Transport/EclassDDLTests.swift` 覆盖分页、作业字段、时间格式、并发、原生会话恢复、取消及生产服务到持久化的完整链路；`ModuleTests/Schedule/EclassDDLSyncTests.swift` 覆盖完成状态、部分失败、账号状态和过期窗口；`ModuleTests/Sync/ScheduleSyncTests.swift` 验证学校正文与完成状态的云同步边界。

模块测试使用受控响应验证未来作业经过生产服务、ViewModel、账号仓库、编码解码和重新加载后的显示与完成状态；真机 UI 使用隔离缓存验证实际交互。模块行覆盖率分别以 macOS 和 iOS 宿主的可执行源码为分母，UI 宿主维护交互库存，并沿 Xcode 默认配置执行主线程与性能反模式检测。学校短信分支通过共享 challenge 和原生会话测试验证，常规网络探针采用 preflight 模式。

授权后的完整学校认证与短信继续验收运行 `Scripts/release-network-smoke.sh all sms`，同一次全量结果分别形成 `network` 和按学校探针投影的 `school-sms` 证据；学校专项入口为 `Scripts/release-network-smoke.sh school sms`，在手机共用验证码面板完成输入，由生产服务继续认证和学校请求；四类认证、后续请求和范围探针全部成功时记录独立 `school-sms` 证据，并按成绩、可信成绩单、WebVPN / 课程中心及学校 SSO 的认证 purpose 记录成功的业务探针；服务端提出的每次短信挑战需完成提交与业务继续。已认证会话记录 `not_required`，并保留四类认证探针；存在短信挑战时记录 `verified`，请求 purpose 集合与成功短信证据同时参与完整性校验。

发布绑定核对学校认证及服务端实际提出的短信挑战；`not_required` 表示四类业务认证已完成，`verified` 表示本次请求的短信挑战均已提交并继续业务。系统权限、Widget / Watch 界面及真实照片选择由专项真机流程承接。线上详情探针核对所选列表实体的服务端标识；空列表保留相关探针的验收缺口。

iCloud 双向验证要求 iPhone 与 Catalyst 使用同一 Apple ID，手机处于解锁状态，两端能够访问 iCloud KVS、生产 CloudKit 与 iCloud 钥匙串：

```sh
Scripts/run_icloud_cross_device_smoke.sh
Scripts/run_icloud_cross_device_smoke.sh report
Scripts/run_icloud_cross_device_smoke.sh cleanup
```

该专用流程通过 `ICLOUD_CROSS_DEVICE_SMOKE` 条件编译执行“真机 → Catalyst → 真机”，同时验证成绩 KVS 与课表 CloudKit Production。两个宿主从固定验收签名配置构建，并核对实际签名环境；课表通过生产协调器完成创建、接收、更新和再次接收，旧记录锁通过真实服务端冲突验收。手机发布完整成绩缓存及本次业务域版本，Mac 核对完整载荷摘要和接收版本，修改验收仓库中的课程名称并发布更新的载荷与业务域版本；手机核对 Mac 的新版本及变更后的完整载荷摘要。课表往返同时核对手动调课、自定义日程、DDL 完成状态和显示偏好；KVS 往返同时核对设置、成绩筛选、消息已读取并集及各域版本。两个宿主构造无害的合成成绩与课表，通过公共存储端口选择独立验收账号会话、本机文件服务、固定独立磁盘目录和验收偏好，由生产同步协调器生成版本并完成接收与发布。成绩密文通过真实 KVS 传递，独立密钥通过 iCloud 钥匙串传递。

两个宿主预先构建后并行执行，手机在同一测试进程内发布和接收，Mac 接收手机载荷后发布新版本。测试执行复用已构建宿主，运行阶段释放公共编译缓存锁。各宿主通过测试运行环境注入的同一运行标记选择本次协调记录。每个宿主要求一项用例执行并通过；宿主结果汇总到 `.build/icloud-cross-device-smoke/report.json`，完整结果包保存最近的业务验证阶段。异常清理保留该结果包并记录独立清理状态。错误钩子覆盖函数内部失败，信号钩子处理执行中断；故障注入自测验证恢复顺序和状态码。流程结束时清理验收云端键、偏好和协调数据，并恢复常规 Release App；聚合验证由外层统一恢复 App。中断后的恢复使用既有 `cleanup` 入口。`ICloudSmokeEvidenceTests` 通过离线用例验证旧版本、空缓存和同数量内容变化的验收边界。

获得全量测试及网络、iCloud 授权后，通过 `Scripts/run-extended-tests.sh verify` 聚合验证；可选择分组，定向 UI 复验使用 `ui 用例关键词...`。

## 固定产物与 CI

| 类别 | 固定路径 |
| --- | --- |
| 共享 SDK、模块与 SDK 状态缓存 | `.build/compiler-cache/` |
| 测试构建、结果与日志 | `.build/extended-automation/`，结果包 `test-results.xcresult` |
| 测试指标 | `.build/extended-automation/test-metrics.txt` |
| 包级测试与编译日志 | `.build/extended-automation/modules.log`、`.build/extended-automation/build-modules.log` |
| 设备截图 | `.build/screenshot.png` |
| 网络 Smoke | `.build/release-network-smoke/report/release-network-smoke.json` |
| iCloud Smoke | `.build/icloud-cross-device-smoke/`，阶段报告 `report.json` |

同类产物覆盖既有路径，文件名使用稳定类别名。公共构建入口串行迁移及复用 SDK 缓存，各宿主的缓存目录链接到 `.build/compiler-cache/`，保留必要的增量中间文件。`Scripts/run-extended-tests.sh cache` 清理诊断残留及模拟器编译产物，并在依赖清单完整时清理未引用的 SDK 预编译模块；活跃平台的隐式模块缓存继续保留。文件内容和修改时间保持一致，日常构建直接复用热缓存。静态审计递归核对共享缓存链接及诊断残留，缓存自测覆盖合并、较新模块保留、重复整理、依赖引用、模块内容完整性和真机产物保留。终端直接展示测试汇总、审查候选与失败诊断，过滤重复进度、空章节和例行通过信息。终端展示必要摘要，完整输出保存在固定日志中。完整日志和报告覆盖既有路径。

真机自托管 CI 的 checkout 使用 `clean: false` 保留固定工作区中的共享编译缓存和增量产物。验证输入摘要、产物审计与所属运行标识共同核对每次验收结果；CI 静态审计的失败组沿控制台完整展示诊断，详细日志继续保存到固定产物路径。

缓存与诊断保持原始文件形式。CompilationCache 的 CAS 索引、动作及数据作为完整命名空间迁入共享目录，SDK 统计缓存沿当前使用的平台维护。共享编译入口统一启用 Swift / Clang 警告门禁，覆盖 SwiftPM 模块构建与测试、正式归档和独立 Smoke 构建。工作流条件宏通过 `BIT101_WORKFLOW_CONDITIONS` 限定在 App 工程，共享包模块复用同一编译配置。UI 文件隔离由 App 文件服务提供，账号摘要沿用生产存储规则。脚本开发构建使用 `DEBUG_INFORMATION_FORMAT=dwarf` 和逐文件增量编译，调试信息保留在目标文件与链接产物中；发行归档沿用工程的 dSYM 和整模块优化设置，显式构建参数优先。缓存整理清理独立 dSYM 副本，运行包内部的调试资源继续保留；通过 Clang 模块元数据识别及清理停用平台的隐式模块。真机、Mac 和平台归属待核对的模块继续保留。

完整测试输出写入对应固定日志，终端显示汇总和失败摘要；模块日志保留 Swift Testing 的 suite、用例及参数执行记录。模块测试汇总七个消费者二进制，采集逐模块生产源码行覆盖率，真机测试采集逐 target 行覆盖率，并通过 LLVM 汇总 App 及嵌入框架的生产模块覆盖率；设备 profile 在测试前清理并由本批运行重新生成，指标固定覆盖 `test-metrics.txt`。模块覆盖率统计 macOS 宿主编译的可执行源码，iOS 界面由真机行为与 UI 用例补充。模块报告记录统计范围及总覆盖行数，CI 将逐模块指标写入 GitHub Job Summary，沿工作流执行记录保留覆盖率趋势。各 Job 使用 [upload-artifact](https://github.com/actions/upload-artifact) 的零压缩级别保存完整日志、指标与结果包，采用仓库默认保留周期。覆盖率采集异常进入失败状态；Catalyst 使用 runtime 提供的测试汇总。
测试入口先取得用户级 `~/Library/Caches/BIT101-iOS/device-workflow.lock`，再取得工作副本内 `.build/extended-automation.lock`，串行协调同一 Mac 各工作副本中的 App 安装、启动、执行与恢复，以及固定产物目录。聚合验证内的分组继承这两级锁和设备快照，首个失败结束分组执行并保留其原始结果包、指标与附件，结束时统一恢复常规 App。恢复钩子覆盖函数内部错误和执行中断，保留原始失败状态码；常规 App 恢复结果记录为独立证据。编译宿主时保留既有测试结果包、指标和运行日志，编译日志使用固定 `<分组>-build.log`。长流程从入口读取完整脚本到内存后执行，加锁等待结束时读取当前版本。SwiftSyntax 索引器在 `.build/static-audit/` 编译并复用，源码或工具链变化时覆盖重编译，编译与调用共用文件锁。

GitHub Actions 的 `.github/workflows/ci.yml` 使用带 `self-hosted`、`macOS`、`bit101-xcode-27`、`bit101-ci` 标签的隔离 runner，各 Job 的 checkout 保留公共编译缓存与增量产物，先执行静态审计与包级测试，再并行执行 iOS 宿主构建 Job 和独立的 Catalyst 行为 Job。Catalyst Job 执行行为用例及正式编译条件下的生产行为及组装合同；iOS Job 顺序编译正式 Release、UI 和两种 Smoke 的测试宿主，App 依赖图同时编译 Watch 和两种 Widget，Swift / Clang 警告按错误处理。工作流通过系统 Ruby YAML 解析器核对 pull_request 和 push 自动触发、三个 Job 的默认执行、bash shell 继承、静态依赖及各自必备入口。版本、plist 和 PR 基线在静态 job 校验，手动 `release_check` 校验公开版本。

本机承接真机行为、UI、网络和 iCloud 验证；发布操作按对应授权执行。

验证证据由 `Scripts/validation_evidence.py` 维护，固定保存为 `.build/extended-automation/validation-evidence.json`。证据文件记录源码摘要，自动执行组保存范围、退出状态、独立结果摘要、运行标识和执行环境。工作流先固定设备目标再采集输入摘要；指标与 Smoke 报告携带所属运行标识，成功记录核对开始摘要及结果来源，聚合验证检查已完成的子流程记录。环境包含 Xcode / Swift 编译器、SDK、主机系统与架构，以及真机标识、系统版本和系统构建号；源码和环境共同形成组输入摘要，环境变化触发所属组复验。测试摘要包含总数、通过、失败、跳过、实际用例集合和逐模块覆盖率；完整分组与当前源码用例清单核对。

UI 摘要合并本批全部 App 进程的完整控件标识与访问动作，冷启动前和各用例结束时采样，同进程的后续访问清除对应待访问项，跨进程保持独立身份；已挂载的可交互控件全部访问，并记录禁用状态断言；源码交互清单核对各作用域的声明及有效验收归属。Swift 条件编译过滤按实际换行拆分，保留 CRLF 和 UTF-8 字节位置，Unicode 注释中的分隔字符参与库存回归验证。分页探针在首页具备后续数据时读取一次实际续页，核对跨页正数标识及新增实体，合法部分重叠和末页参与回归；消息使用实际末条标识，推荐及机器人使用返回的源游标与过滤前标识；两次读取共同核对当前账号代际。共享会话探针沿生产 Cookie 与缓存配置读取资料，学校探针复用正式学校状态及传输配置。

网络摘要按分组保存运行标识、输入摘要、具体错误、认证阻塞和覆盖缺口，保存采样起止时间并核对当前范围的必需探针集合、认证和覆盖情况；发布绑定与检查要求网络、学校短信、社区写入、iCloud 双端及全部人工专项在 24 小时有效期内完成，iCloud 摘要包含双端阶段及清理结果，CI 记录关联工作流。模块执行通过 Swift Testing 事件流保存实际用例。独立 Smoke 同样更新证据，源码摘要包含脚本执行权限；记录、读取与提交绑定共用锁和原子替换。原始日志按验证组使用固定路径，聚合流程保留每个宿主的日志；后续宿主覆盖指标文件时，各组摘要继续保留；各组保存实际输入摘要，产品源码、对应测试及执行脚本的变化使所属组进入复验；文档和协作约定的变化由静态审计承接。人工验收沿产品与安装输入保留，UI 交互文档同时属于 UI 组输入。仓库整体摘要继续维护提交追溯。

`Scripts/run-extended-tests.sh verify` 完整执行模块、真机行为、正式运行组装、Catalyst 行为与正式组装、UI、网络、社区写入、iCloud、正式归档和静态审计；学校短信专项通过独立入口执行，完整验证的 `verify --sms` 入口沿 `all sms` 执行全量网络及学校短信验收；恢复常规 App 后返回聚合结果。正式归档编译结果作为 `build-archive` 证据参与绑定，恢复正式 App 沿单一就绪信号核对正式构建输入、运行标识、本地会话恢复、活跃场景与当前进程，形成独立 `restore` 证据。

专项真机证据逐项记录系统自动填充、真实照片、日历权限与写入、通知权限与投递、外部 App 交接、网页交互、Widget 和 Watch；执行 `python3 Scripts/validation_evidence.py manual 检查项 --operation "实际操作" --result "观察结果" --outcome passed --observed-at "实际观察的 ISO 8601 时间" --evidence 本地附件路径` 保存实际验收说明。

检查项为 `minimum-platforms`、`distribution-signing`、`system-autofill`、`photos`、`calendar-permissions`、`notifications`、`external-handoff`、`web-interactions`、`widget`、`watch`、`feedback-delivery`，失败观察以 `--outcome failed` 登记，附件可保留实际影像或结构化诊断，发布门禁继续要求每项成功。记录结构保存操作、结果、明确的 passed/failed 状态、实际观察时间和登记时间、附件路径、完整 Base64 内容、字节数和 SHA-256；发布检查重新解码并核对内容摘要，固定源路径后续覆盖时保留已采集证据，CI 沿同一 JSON 获取完整附件。人工验收的全部检查项共同参与采集区间时效核对。

影像附件通过 ImageIO、Core Graphics 和 AVFoundation 实际解码，视频读取完整视频轨道。`minimum-platforms` 附件使用结构化 JSON，`schemaVersion` 为 1，`platforms` 包含 `iOS` 与 `watchOS`。每端登记 `deviceIdentifier`、`deviceModel`、`systemVersion`、`systemBuild`、`capturedAt`、`checks` 及 `evidence`；系统主版本与小版本匹配对应平台各目标的最高部署要求，补丁版本达到部署要求，当前覆盖 iOS 17.0 与 watchOS 10.0。

iOS 的 `checks` 包含 `cold-start-session`、`offline-persistence`、`media-and-navigation`，Watch 包含 `snapshot-receive`、`timeline-render`、`clear-and-retry`；每项保存 `operation`、`result` 与 `outcome`，成功状态为 `passed`。每端的影像 `evidence` 保存 `path`、`sha256`、`byteCount`、`dataBase64`，与普通附件采用相同解码和时效校验。常规自动化记录所选 iPhone 系统身份，最低部署版本专项补充对应实体设备的核心验收。反馈专项从 App 提交正式报告，核对报告持久化及维护者邮件送达，并将报告编号、存储键和邮件收件证据保存在验收附件。

全部完成后形成 `manual-device` 证据。专项记录读取执行设备的系统身份，源码或执行环境变更后重新验收。发布标签采用 `v` 加工程 `MARKETING_VERSION`，静态审计核对标签与工程版本对应。发布提交完成后执行 `python3 Scripts/validation_evidence.py bind`，仓库内容已完整提交、完整通过且源码摘要一致时绑定提交；CI 将各 Job 的已执行结果写入 GitHub Job Summary。版本发布通过 `v*` 标签触发强制验收，发布 Job 承接静态审计、iOS 编译和 Catalyst 行为结果，并从对应 GitHub Release 下载固定绑定证据附件。手动工作流开启 `release_check` 时填写 `validation_tag`，两个入口沿同一发布验收 Job 消费固定证据路径。

本机 `python3 Scripts/validation_evidence.py check` 核对完整分组、当前源码、执行环境及发布提交。CI 使用 `check --recorded-environment` 消费已绑定证据，按记录环境重算各组输入摘要，并以编译器文件 SHA-256、Xcode、工具链选择及 SDK 核对当前发布编译环境；原验收主机与真机身份继续保留在证据中。编译组与行为组在证据中分别记录执行范围和结果。

社区线上写入通过 `BIT101_COMMUNITY_SMOKE_ACCOUNT=专用验收账号ID BIT101_COMMUNITY_FOLLOW_TARGET=已关注的专用用户ID Scripts/release-network-smoke.sh community-writes` 执行，采用明确授权的专用验收账号、专用关注目标和“功能验收”中性文案。线上写入先通过服务端资料核对明确指定的专用账号，账号确认后恢复待清理记录并记录账号证据；关注探针读取既有关系，执行关注接口并恢复已关注状态；写入前将目标保存到同一清理记录，进程中断后沿该目标恢复。帖子和评论上传实际 JPEG，通过服务端 MID 提交，并读取图片引用；编辑保留同一资源引用，内容删除验收覆盖关联帖子和评论。上传资源遵循服务端媒体保留策略。

创建独立帖子、文章及三个业务域的评论和回复，验证内容编辑、点赞及恢复，点赞与评论写入按服务端一秒冷却推进；课程采用当前可用列表的首个目标。文章探针复用编辑器的 Editor.js 正文序列化与纯文本读取，业务失败报告标注创建、编辑、点赞、评论或回复步骤。评论创建与清理发现共同持久保存评论到父对象的映射，历史格式依据成功创建证据迁移；进程重启后沿所属父对象列表确认已删除评论。历史清理记录补齐已知目标的父对象候选，读取顶级评论后登记其回复父对象，逐个删除记录中的评论标识。成功读取的服务端列表确认评论删除后更新清理记录，评论读取及删除接口的错误保留待确认标识；帖子与文章的缺失判定同时核对业务域及资源缺失文案。未知父对象的待确认标识继续保留。

帖子、文章、评论和回复在提交前登记待确认创建，收到有效对象标识后将标识与创建确认共同保存。响应丢失后保留创建记录，搜索结果为空时继续等待服务端确认；连接恢复后沿同一记录再次发现和清理迟到对象。明确的认证拒绝或业务 HTTP 4xx 响应结束对应创建尝试。历史记录依据已保存对象和创建证据迁移待确认状态。每次写入前将账号和清理标记原子保存到 Application Support 下的 `NetworkSmoke/community-write-journal.json`，保存成功后提交线上请求，创建后登记服务端标识。宿主入口按进程串行执行验收，社区恢复直接读取专用记录。失败或取消时继续清理；脚本异常时调用 `community-cleanup` 恢复待清理记录，原始失败与清理结果共同保存到同一固定报告，控制台保留两个阶段的诊断。删除后重新读取服务端，帖子与文章的明确资源缺失响应沿所属业务域判定，其他返回保留失败。确认全部验收内容清理和点赞恢复后记录 `community-writes` 证据。请求前后核对账号身份与代际，清理过程的账号变化保留恢复记录。回复先删除并在父评论可读时确认，再删除父评论与所属内容。

清理按独立对象推进并保存成功进度，单个对象持续失败时继续清理其他对象，账号变化沿身份边界结束。清理异常保留待清理记录，连接恢复后执行 `Scripts/release-network-smoke.sh community-cleanup`。恢复清理沿独立 `community-cleanup` 范围记录结果，完整写入验收证据继续保留。固定报告保存关注恢复、图片引用、创建标识、写入结果与服务端删除确认，发布门禁核对三个域的点赞恢复、六个不同评论标识的删除、评论及回复的创建关系，以及帖子和文章删除。

正式运行分组沿 `Scripts/validation_policy.py` 的 suite 登记执行 `ReleaseRuntimeContractTests`、`ExtendedLoginTests`、`LoginStorageTests`、`LoginBootstrapTests`、`NetworkClientTests`、`FeatureCompositionTests`、`ExperimentalPreferenceCloudSyncTests` 与 `AppExternalDisplayTests` 与 `ReminderContextTests`，覆盖生产组装、登录恢复、凭据持久化、退出清理、账号代际、页面依赖、生命周期云同步、外部展示及网络请求行为；实际执行方法集合共同参与证据核对。

人工影像证据采用 PNG、JPEG、PDF 或 MP4，记录绑定所属专项；结构化反馈证据采用 JSON，必需字段为 `reportID`、`storageKey`、`storedReport`、`emailRecipient`、`emailMessageID` 与 `emailBody`。报告编号同时对应正式存储键、存储记录及收件正文，邮件 Message-ID 保存实际收件标识。

执行 `Scripts/build-install-device.sh archive-signed` 生成固定签名归档，再沿 Xcode 的 App Store 导出流程取得最终分发产物，从导出载荷中选择 `.app` 目录执行 `python3 Scripts/validate_distribution.py 导出应用路径`。

签名检查核对 App、Watch 和两种 Widget 的签名完整性、App Store 描述文件类型与有效期、实际平台与最低系统版本、团队、版本、嵌套归属、App Group、CloudKit Production 与 KVS 标识，签名归档及编译归档共用固定路径，归档保存源码摘要、运行标识与各可执行文件的 Mach-O UUID；导出签名证据核对同一归档身份及 UUID，保存各 bundle 的 SHA-256 及签名权限到固定 `build/DeviceInstall/distribution-signing.json`。

沿 `python3 Scripts/validation_evidence.py manual distribution-signing --operation "导出与核对分发签名" --result "实际检查结果" --outcome passed --observed-at "实际观察的 ISO 8601 时间" --evidence build/DeviceInstall/distribution-signing.json` 纳入发布证据。分发签名与人工专项共同遵循有效期，发布使用对应摘要的最终产物。通用归档编译与最终分发签名分别提供构建及分发验收证据。

人工专项输入摘要同时覆盖 Cloudflare Worker 实现及部署配置，反馈邮件、网页及外部交接流程的实现变更触发重新验收。学校自动请求检测沿协议符合关系连接具体实现，并保留用户操作与生命周期之间的调用边界。

`MinePagingRecoveryTests`、课程详情合同与服务消费者合同覆盖完整重复页推进、停滞后重试及刷新失败的分页保留。`ScheduleTimeTableTests` 在缓存、分享和设置边界核对节次规则；`ScheduleRepositoryReconciliationTests` 连接实际持久化仓库，在保存队列期间注入同步写入并验证合并、冲突选择和继续保存。共享快照仓库测试覆盖手机恢复后按 Watch 已接受版本推进，媒体依赖测试核对正文链接和展示预算。

核心真机验收参与 PR 合并：完整 `all` 行为、正式 iOS `release-runtime` 合同、完整 `ui` 交互与常规 `restore` 四组需要当前源码与设备输入，并在 24 小时内执行。CI 的 `physical-device` Job 在具有 `self-hosted`、`macOS`、`bit101-xcode-27`、`bit101-device` 标签的专用 Mac 与 iPhone 上执行 `verify modules all release-runtime ui`，恢复常规 App 后执行 `bind-merge`。

`bind-merge` 将当前提交写入本地固定 JSON，Job 通过 `ci_evidence.py export-core` 导出核心组到固定 `core-validation-evidence.json`，再沿 `upload-artifact` 发布同名 `validation-evidence` 产物。完整人工专项保存在本地报告中，核心交换文件承接模块、行为、正式 iOS、UI 与恢复证据。合并 Job 承接静态审计、编译、Catalyst 和真机结果，仓库内 PR 从当前工作流运行获取该产物，核对 GitHub 合并提交、实际记录环境及四组真机验收的一致工具链。自托管运行器按 GitHub 队列承接工作，项目脚本按工作区锁定固定编译产物；真机操作同时取得用户级设备锁。独立工作区的本机测试与编译可并行，核心真机证据按记录环境核对源码及编译条件。

仓库内分支和维护者手动触发执行真机 Job；fork PR 由维护者审查代码后，将 GitHub 的 `refs/pull/编号/merge` 对应提交保存到仓库内 `review-validation` 分支；从该分支手动启动工作流并填写 `review_pr`。工作流核对当前 PR 合并提交，沿其目标提交载入覆盖率基准，再完成四个 Job 和真机证据绑定。维护者随后重新运行原 PR 的合并验收 Job；门禁按原合并 SHA 与 PR 编号查找仓库内成功的手动运行，核对四个实际 Job、有效产物及绑定证据。PR 或目标提交更新后沿新合并提交重新验收。

fork PR 的常规 Job 使用 GitHub 托管的 `xcode-27` 镜像，每项任务沿独立托管环境运行；[官方镜像公告](https://github.com/actions/runner-images/issues/14404)说明工具链与镜像标签。仓库内分支与维护者手动审查任务使用 `bit101-ci` macOS 宿主，复用固定工作区、公共编译缓存与增量产物；手动审查提交核对先于依赖安装。运行器选择按事件及 PR 来源仓库同时判定，静态审计逐项核对五个常规 Job 的选择条件。`bit101-device` 标签归属真机专用宿主，设备连接及 GitHub、Cloudflare、Apple 授权保存在该宿主。自托管工具链标签统一登记为 `bit101-xcode-27`，托管镜像标签 `xcode-27` 归属 GitHub 托管宿主；部署时按这两类标签归属配置运行器。角色、标签与设备授权沿 [GitHub 自托管运行器文档](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow) 和本项目真机流程配置。

完整模块与 iOS 行为组按每模块的整数百分比维护覆盖率基准。`Scripts/validation_policy.py` 保存版本化的 macOS 与 iOS 阈值；完整验收提高覆盖率后同步提高相应阈值并提交评审。PR 的静态与真机 Job 通过 `ci_evidence.py baseline` 从目标提交读取这两组字典，以 Python AST 字面量解析并核对阈值，再由 `validation_evidence.py baseline` 载入。基准随 Git 提交长期保存，读取过程独立于历史工作流、真机状态和产物保留期。筛选复验在统一 JSON 内保留 `coverageBaseline` 和 `lastFullRun`；完整运行按当前版本与目标提交阈值中的较高值验收；本机 `coverageBaseline` 保存覆盖率高水位观察。新宿主与复用缓存的宿主采用同一版本化门禁。

发布证据完成完整验收并执行 `python3 Scripts/validation_evidence.py bind` 后，通过 `python3 Scripts/ci_evidence.py publish v公开版本号` 生成并上传公开回执。固定本地路径与 Release 附件名为 `.build/extended-automation/release-receipt.json` 和 `release-receipt.json`。回执保存版本标签、提交、各组源码摘要、工具链、完整验收状态、原始摘要 SHA-256 与采样时间；截图、视频、邮箱、邮件正文、存储报告及设备身份保存在本地完整报告。发布命令先沿原始报告核对全部验收，再生成回执。发布 CI 下载同一标签的回执，沿 `ci_evidence.py check-release` 核对源码、工具链、全部组及采样有效期；回执表示维护者已完成完整验收的公开确认，发布资产写入权限属于该信任边界。`summaryDigest` 为本地原始摘要的比对标识，复核实际执行来源时读取维护者保留的完整报告及所属 XCTest 结果包；下载后的 CI 沿公开声明验收源码、工具链和采样有效期。详细附件沿明确授权在本地审阅。手动 `release_check` 同时填写 `validation_tag`，标签需要指向当前验收提交。发布资产按可分享的回执范围审阅，上传沿用户明确授权执行。

首次登录、个人资料写入、举报与 iPad 布局使用结构化人工专项，分别登记 `first-login`、`profile-writes`、`gallery-report` 与 `ipad-layout`。`web-interactions` 分别观察网络诊断、启动更新检查、手动更新检查、学校短信续验和学校日历同步。首次登录在正式 App 中清理登录态，分别以已注册账号与授权的新账号完成 WebVPN 初始化、密码校验、注册及进入登录后的页面。资料专项使用专用账号实际保存昵称、上传并绑定头像，随后恢复原资料并重新读取核对；举报专项使用明确授权的专用帖子确认服务端接收。iPad 专项覆盖竖屏、横屏、分屏及窗口调整，核对登录、主要导航、课表、内容详情与键盘操作。iPad 沿系统旋转和窗口管理适配尺寸，配置采用支持多方向的常规模式；迁移依据 [Apple 的 iPad 全屏模式说明](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)。

各专项附件使用 `schemaVersion: 1` 与 `scenarios` 字典，键名沿 `Scripts/validation_manual.py` 的 `MANUAL_SCENARIOS` 登记。每个场景记录 `operation`、`result`、`outcome: "passed"`、实际 `capturedAt` 与 `capture` 使用的影像证据结构。涉及网络能力的场景增加 `capabilities` 字典，键名为 `Scripts/validation_test_areas.py` 的完整所属类型与方法签名，各项记录实际 `operation`、`result` 与 `outcome: "passed"`；`MANUAL_CAPABILITY_SCENARIOS` 登记方法对应场景，新增方法需要独立观察。反馈投递附件在顶层使用相同 `capabilities` 结构，并保留存储与邮件回执。iPad 附件增加 `deviceFamily: "iPad"`、`deviceIdentifier`，各场景记录整数点数的 `windowSize.width/height`，分屏记录 `screenWidth`，调整窗口记录 `previousWindowSize`。结构化附件固定覆盖 `.build/extended-automation/manual-scenarios.json`，每个专项沿 `validation_evidence.py manual 专项名称` 的已有入口提交后再填写下一专项；证据内容由统一报告保存。

日常开发沿模块和场景选择定向测试。发布验收将源码、工具链和完整候选产物共同绑定，实时服务与人工观察沿一天有效期核对；完整输入范围用于维持产物与证据的对应关系。专项采集围绕同一候选产物集中完成，发布流程执行完整验收。

人工附件每份编码前控制在 32 MiB 内，图像解码与视频单帧使用 48 MiB 内存预算；视频长度为 30 秒以内，最多 1800 帧，PDF 最多 16 页。附件解码工具使用 30 秒执行预算，聚合 JSON 的完整编码最多 128 MiB；超出预算时保留已提交证据并呈现验收错误。短视频和系统截图分别记录所属操作与观察结果，全部人工检查共同参与发布验收。

业务网络能力沿 `Scripts/validation_test_areas.py` 登记社区、学校、成绩、登录、资料及更新服务的方法签名与验收入口。模块审计沿 SwiftSyntax 导出的公开函数事实核对新增、移除及无效归属，跨文件扩展沿所属模块和类型合并，属性依赖沿显式类型、构造器和工厂返回类型解析；恒假条件与循环中的调用沿控制流事实排除。网络请求证据核对普通分页的第 1 续页，以及消息续页参数与前一响应最小消息 ID 的对应关系。社区写入合同核对帖子与文章的创建、编辑和删除，五次图片上传，六次评论与回复创建及六个独立评论删除，三类对象的成对点赞和同一目标的关注恢复。请求记录保存所需对象标识，后台采集响应最小消息 ID，正文与凭据沿过滤规则处理。网络探针覆盖列表及三类评论的后续页，话廊评论沿真实源游标继续，课程与文章评论验收重复页和解码失败。反馈预检发送 Origin、POST 和 content-type 请求头，验收浏览器需要的允许方法及允许头字段。关注写入验收同时核对取消关注和恢复关注的接口结果与远端关系。

`community-variants` 人工专项覆盖课程搜索、话廊搜索筛选、帖子与文章的三种评论排序、匿名帖子、匿名文章及创建内容恢复；场景键为 `course-search`、`gallery-search-filters`、`comment-sorting`、`anonymous-poster`、`anonymous-paper`、`restore-content`。使用已授权的专用账号，保存实际请求结果和页面证据，确认验收内容删除。`account-lifecycle` 专项在正式 App 中顺序执行 `sign-in-a`、`refresh-credentials-a`、`sign-out-a`、`sign-in-b`、`restore-a`，核对真实凭据续期、退出清理、资料与业务缓存切换、订阅更新及恢复账号。两个专项复用结构化人工场景格式与固定 `manual-scenarios.json` 附件，参与完整发布验收。

社区图片探针复用 `CommunityWriteMedia` 中固定的一像素 JPEG 字节；上传返回的 MID 在创建帖子或评论前持久记录于同一事务日志，资源记录保存成功后，在提交业务创建请求前保存待确认记录。上传或提交记录保存失败时沿已创建对象完成清理；业务请求结果未知时持续查找并保留恢复记录。公开服务端 [ImageService.Save](https://github.com/BIT101-dev/BIT101-GO/blob/main/api/service/image.go) 按内容 MD5 生成 MID 并复用已存在图片，[路由](https://github.com/BIT101-dev/BIT101-GO/blob/main/api/router.go) 将图片作为独立共享资源提供上传。验收帖子和评论沿服务端读取与删除确认清理，共享验收图片持续复用；恢复证据保留其 MID。实际线上资源策略沿已部署服务端契约核对。

文章与帖子详情的已知缺失响应由服务层转换为明确的错误类型，恢复器沿类型确认缺失；后端业务响应转换集中在各服务的接口错误定义中。通用路由失败与其他服务错误保留验收失败结果。iCloud smoke 阶段、初始身份与退出报告复用证据原子写入器，写入中断时保留原恢复身份。

网络能力审计将公开方法与对应 smoke 入口中的服务调用关联，服务内部的转调沿 SwiftSyntax 函数范围与调用事实继续追踪。新增生产 Client、Repository 或服务沿实际传输依赖与公开函数事实发现，并同步登记验收归属；读探针与写探针分别核对实际调用，人工专项承接有明确外部副作用的变体。接收者与专用工厂沿 smoke 的组装角色登记，动态执行结果继续由真实探针及服务消费者合同验收。

编辑器系统关闭沿 `check_composer_lifecycle` 核对显式关闭入口和提交状态；UI 生命周期用例独立验证下拉关闭与后台返回，控件交互库存继续核对已挂载控件。评论发送期间锁定输入、匿名、评分与关闭操作，服务端成功后客户端取消的交错由模型合同验收。

调用关联从 smoke 的 `run` 入口沿默认依赖回调、显式操作工厂及并行探针调度继续追踪，编译分支采用实际网络宿主条件。闲置函数和闭包形成独立调用节点；公开网络能力采用方法名称、参数标签及参数类型组成的签名，重载调用沿标签与实参类型解析。话廊关注、推荐、最新、热门与机器人分栏共同参与能力审计。

共享预览目录的媒体环境共同接收同一 `MediaPreviewStorage`，文件创建、所有权登记、清理和关闭消费同一协调器。回归合同覆盖创建期间的后台清理，以及不同环境启动清理和关闭预览时保留其他活动消费者。

`MaintenancePerformanceTests` 沿 XCTest 默认测量选项记录实际分页、PNG 解码、256 块复杂内联格式的文章解析与纯文本生成、GIF 解码、Widget 时间线计算、32 MiB URLSession 响应聚合，以及 64 页本地图片的首个预览文件编码与写盘的时钟和物理内存指标。`MaintenancePerformanceUITests` 记录清空夹具存储后的进程结束、启动至课表就绪，以及启用动画的课表往返切周布局；UI 内存指标采集目标 App 进程。性能基线沿同一真机 runner 的 XCTest 默认参数维护。

`performance-baseline` 人工专项登记 `pagination`、`image-decoding`、`startup`、`schedule-layout`、`long-article`、`gif-decoding`、`widget-timeline`、`response-aggregation`、`local-preview` 九个场景的结构化比较及影像，参与完整发布验收。行为场景归属 `all`，启动与课表布局归属 `ui`；每条采样保留所属完整测试组的执行证据。

每个性能场景的 `measurement` 包含 `current` 与 `baseline`。两份记录保存 `testIdentifier`、`sourceCommit`、`capturedAt`、`environment`、`input`、`resultBundle`、`metrics`；当前采样沿实际观察时间登记，批准基线保存 `approvedBy`、`approvedAt`。`environment` 核对相同的设备标识、设备型号、系统版本与构建、Xcode 构建、编译器摘要、Release 配置及 `compilationConditions`。`resultBundle` 保存固定 XCTest 结果包路径和 SHA-256，两个采样拥有各自的摘要。`execution` 保存所属运行、构建输入、源码提交及完整环境；`xcresultMetrics` 保留工具导出的原始指标。

`metrics` 分别记录 `clockSeconds`、`peakPhysicalMemoryBytes` 的原始 `samples` 和 `mean`；登记时将 XCTest 显示单位换算为秒及字节。批准基线的两个指标各自保存 `maximumRegressionPercent`，验收核对采样次数、平均值及批准的退化上限。分页输入为 `pages: 1000`、`itemsPerPage: 100`、`passes: 2`，状态为 `MinePagedState` 与 `GalleryMessageListState`；图片输入为 `width: 1024`、`height: 1024`、`format: PNG`。长文章输入为 40 段、每段重复 64 次；GIF 为 256 × 256、24 帧，每次测量清空解码缓存；时间线为 200 门课程、20 周及 4000 次课程；课表每次测量执行十组往返切周。输入登记共用 `Scripts/validation_manual.py` 的工作负载表。

完整真机行为及 UI 组完成时，将原始性能指标、结果包摘要与运行身份写入统一验证报告。运行 `Scripts/run-extended-tests.sh performance baseline 批准人` 从该报告保存批准基线，退化上限沿 XCTest 实际默认参数提取；显式百分比参数用于经过批准的调整。后续候选完成真机行为与 UI 组或聚合验证后，运行 `Scripts/run-extended-tests.sh performance current`。两份记录统一覆盖 `.build/extended-automation/performance-measurements.json` 的对应字段，再填入人工场景附件。基线批准同时保存到统一验证报告并随核心 CI 证据交换；真机 runner 沿该固定报告保留批准基线。合并门禁从本次完整行为与 UI 组提取九个场景，核对所属运行、源码、设备及工具链，并按批准上限验收耗时与内存退化。首次配置 runner 或变更采样环境时，维护者沿同一命令批准基线并再次执行候选验收。

采集核对工作树及暂存区相对 HEAD 的构建输入、结果包摘要、运行标识、设备与工具链，登记人工附件时核对所属测试组完成时保存的原始指标与批准基线。共享文件服务契约同时验收内存及本机后端的目录、枚举、递归清理与失败注入。文档审计沿当前内容和 Git index 分别核对文件、标题锚点与引用式链接。

SwiftSyntax 索引器缓存沿源码、工具链环境、编译器、SwiftSyntax / SwiftParser 库及模块内容摘要复用。网络能力检测沿编译器类型、初始化表达式、依赖工厂返回值和局部别名识别生产服务，局部同名变量沿词法作用域解析。模块门禁按业务归属限制 Domain、Ports、Core 等依赖；社区功能共用 Community 业务合同，基础 Client、Storage、Transport、DesignSystem、Media 模块承担公共职责。地图通过明确登记的 `MapFeature → ScheduleContracts` 依赖复用地点显示规范化，跨业务合同沿允许依赖表评审。

UI 自动化同时采集交互库存及宿主与 Feature / UI 模块的行覆盖率，完整验收要求各展示模块产生实际执行行。界面状态断言、控件交互记录及行覆盖率共同支撑展示逻辑审查。

工作流锁的等待与执行预算共用 45 分钟默认值，执行超时向进程组发送终止信号并保留恢复清理阶段；恢复结束释放设备及工作区锁。测试执行显式启用 XCTest 超时管理。物理设备 CI Job 使用 60 分钟上限，覆盖 45 分钟工作流预算、5 分钟恢复清理及前后步骤，取消与超时恢复沿脚本锁边界合同验收。编译条件由 `validation_policy.workflow_conditions` 统一提供给执行脚本与源码库存，iCloud 使用 `DEBUG ICLOUD_CROSS_DEVICE_SMOKE`。

成功的关键词复验沿同一输入摘要与环境复用此前完整组的证据，完整证据保留原运行标识、采样时间及性能指标。复验失败或构建输入变化进入对应分组的重新验收。网络 smoke 保存每个探针的实际 HTTP 方法、端点及状态码，端点移除凭据、查询参数及片段；完整验收沿 `Scripts/network_request_contracts.py` 核对业务端点、HTTP 方法、所需调用数量及分页查询。列表首屏为空时继续请求续页，消息空首屏使用零游标验收终止边界；首屏、续页与实际参数共同保存在请求证据中。

`Scripts/run-extended-tests.sh report performance-run` 读取当前 XCTest 结果包中实际执行的性能用例，供 Catalyst 与真机采样检查。响应聚合沿 64 KiB 块追加字节并检查取消，声明长度通过边界检查后预留存储；传输合同分别验收声明长度与实际接收长度。

网络读探针沿独立话廊筛选参数采样，图片下载从采样列表的图片及头像选择有效地址。完整详情验收要求线上课程、文章和话廊各具备可读取内容及图片资源；验收账号的数据准备沿专用账号流程执行，完整报告核对各项实际成功结果。共享社区会话合同顺序核对首次成功、无效凭据的 401 拒绝及恢复成功，正式 App 的完整账号操作沿 `account-lifecycle` 专项验收。

课前提醒计时器在到点时交出等待任务的归属，再执行刷新或结束；回归覆盖刷新期间再次排程与等待阶段取消。图片准备回归覆盖 PNG、HEIC、JPEG 原图，评论、头像和发帖共用后台准备器，将实际上传字节转换为既定像素及字节预算内的 JPEG。成绩仓库回归覆盖受保护读取恢复、最大文件边界、超限保存保留旧快照，以及本地保存后重建同步对象的版本选择。学校认证错误与 HTTP 错误共用字节、字符及正文类型边界。
