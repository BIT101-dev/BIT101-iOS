# 构建与测试

首次开发按 [新电脑开发环境](SETUP.md)准备工具链、签名和设备。本文维护命令入口、验证边界和结果读取方法；业务结构见 [架构与数据边界](ARCHITECTURE.md)，控件与用例映射见 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)。

## 选择验证范围

开发回归按改动涉及的模块、状态转换和平台选择范围。失败后先修复并重跑对应用例，问题收敛后安排完整验收。多个筛选项合并为一次调用，共用宿主与增量编译缓存。

| 改动范围 | 常用命令 |
| --- | --- |
| 领域、服务、文件仓库、场景状态 | `Scripts/run-extended-tests.sh modules 测试类` |
| App 组装与平台适配 | `Scripts/run-extended-tests.sh 测试类` |
| 日程、基础设施、登录、扩展行为 | `Scripts/run-extended-tests.sh schedule`、`infrastructure`、`login`、`extensions` |
| 页面交互 | `Scripts/run-extended-tests.sh ui 用例关键词...` |
| 正式编译条件下的 App 组装 | `Scripts/run-extended-tests.sh release-runtime` |
| Catalyst 行为与正式组装 | `Scripts/run-extended-tests.sh catalyst`、`catalyst-release-runtime` |
| 语法、架构、设计系统、脚本、文档 | `Scripts/run-static-audit.sh` |
| 线上接口与跨端同步 | 本文的网络和 iCloud 专项入口 |

包级测试使用 macOS 原生宿主，集中维护共享快照编解码、排序、时间线与文件仓库合同；iOS 行为、系统权限、真实设备交互和跨端能力按所属平台验收。各入口的 `--help` 提供完整参数。网络、短信、线上写入、iCloud 和模拟器按会话授权执行。

静态审计支持按分组定向执行，例如 `Scripts/run-static-audit.sh docs python-parse`、`Scripts/run-static-audit.sh dependency-audit`。`--help` 列出全部分组；定向执行保留完整验收记录，默认入口和 CI 负责记录完整静态审计结果。

## 执行环境与数据边界

- 使用 Xcode 27.x。`Scripts/build-install-device.sh toolchain` 显示当前工具链；`DEVELOPER_DIR` 和 `TOOLCHAINS` 选择由项目脚本传递给 Apple 工具。
- 构建、测试、归档、装机和截图统一通过项目脚本执行。Swift / Clang 警告作为构建错误处理，SwiftPM 与工程共用既有编译缓存。
- 真机入口自动选择已配对设备，已连接设备优先，同等连接状态下 USB 优先，最后按 UDID 稳定排序。设置 `BIT101_XCODE_DEVICE_ID=设备UDID` 后沿指定设备执行，聚合流程复用该设备的两种标识。设备需完成配对、信任、开发者模式和解锁；`Scripts/build-install-device.sh info` 显示连接状态。
- 离线行为和 UI 宿主采用隔离凭据、偏好、文件与受控传输。系统副作用通过注入端口验收，实际系统能力由真机专项补充。
- 真机排查保留测试宿主、结果包和采样现场。相关测试通过后统一执行 `Scripts/build-install-device.sh`，安装并启动常规 Release App。
- `BIT101-iOSTests/Fixtures/` 等固定夹具属于长期资产。清理或改写前核实来源、用途和恢复方式，并取得对应授权。

## 构建、装机与截图

```sh
Scripts/build-install-device.sh
Scripts/build-install-device.sh build
Scripts/build-install-device.sh archive
Scripts/build-install-device.sh screenshot
Scripts/build-install-device.sh mac
```

默认命令完成真机 Release 构建、安装与启动；`build` 编译 App、Widget、Watch App 和 Watch Widget；`archive` 使用工程正式归档配置，保存 dSYM。常规 App 使用正式业务组装与空工作流条件。Catalyst 安装到 `~/Applications/BIT101-iOS.app`，复制和原子交换在固定事务路径完成。

装机就绪采样覆盖写入 `.build/extended-automation/restore.log`，包含设备复制、App 身份、初始化、会话恢复与进程状态。超时展示最后一次采样的原因和日志路径。

归档覆盖 `build/DeviceInstall/BIT101-iOS.xcarchive`，已有签名归档可用于升级安装：

```sh
Scripts/build-install-device.sh install-archive /absolute/path/BIT101-iOS.xcarchive
```

用户明确授权清洁安装时追加 `--clean`。覆盖安装保留应用容器，发布验收分别记录全新安装与从商店正式版覆盖升级的结果。截图覆盖 `.build/screenshot.png`。

## 包级与 App 行为测试

```sh
Scripts/run-extended-tests.sh modules SchedulePersistenceTests ScoreFeatureTests
Scripts/run-extended-tests.sh modules
Scripts/run-extended-tests.sh
Scripts/run-extended-tests.sh LoginStorageTests NetworkClientTests
Scripts/run-extended-tests.sh release-runtime
Scripts/run-extended-tests.sh catalyst
Scripts/run-extended-tests.sh catalyst-release-runtime
```

`modules` 对应 `Package.swift` 中 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个测试 target；名称筛选按测试类或完整方法选择。App 行为入口同样支持多个类与方法，Swift Testing 方法名保留 `()`。快捷领域分组的归属集中在 [测试库存](../Scripts/validation_test_areas.py)。

完整运行对照源码库存核对逐例执行、参数实例、通过、失败和跳过状态。定向运行保存请求清单及实际执行集合，并标注定向范围。测试结果与覆盖率分别按 macOS、iOS 和 Catalyst 的实际可执行源码统计。

异步回归使用共享 `waitForTestEvent` 等待实际状态，并处理取消、超时及 continuation 释放。Swift Testing 套件或方法设置执行期限，XCTest 入口启用系统超时管理。账号、文件和偏好夹具按固定用途隔离；真实系统共享资源由所属测试组串行验收。

正式组装合同使用生产编译条件，覆盖登录恢复、凭据保存、退出清理、账号代际、页面依赖、生命周期同步、提醒上下文和网络环境。生产专用 suite 的库存沿 [验证策略](../Scripts/validation_policy.py)登记。发布归档另行验证工程正式优化与符号配置。

编译宿主时可使用：

```sh
Scripts/run-extended-tests.sh build release
Scripts/run-extended-tests.sh build ui
Scripts/run-extended-tests.sh build network-smoke
Scripts/run-extended-tests.sh build icloud-smoke
```

## UI 自动化

```sh
Scripts/run-extended-tests.sh ui CustomSchedule DDLEditor
Scripts/run-extended-tests.sh ui About
Scripts/run-extended-tests.sh ui
```

关键词按测试类与方法匹配，多个关键词合并为一批。UI 宿主使用 Release 配置、隔离存储与合成会话，测试 App 和 Runner 经固定回环通道配置场景。生产组装启动性能场景使用同一隔离资源和受控 HTTP 响应。

页面流程验证入口、绑定、业务结果与持久化重载；公共组件合同集中覆盖原生触摸、键盘、菜单、滚动、可触达状态和辅助功能。页面默认通过 XCTest 原生触摸与滚动执行，字段操作核对实际输入控件及完整值；系统键盘合同由对应专项验证。快速事件通道由独立组件合同验证，并与当前原生控件状态对照。原生快照与 App 渲染查询共同核对身份、文案、状态和几何；模态关闭及滚动恢复后等待对应内容就绪。

常规场景复用 App 进程并核对进程身份。连续编辑、短信重试、媒体预览和多层弹窗场景使用系统动画；字体与启动配置变化时重新启动所属场景。持久化断言重新读取文件与偏好。验证码覆盖逐位输入、整段自动提交、失败重试、取消和原业务继续。

交互库存按场景、祖先行与稳定控件标识区分身份，访问证据核对实际动作及业务断言。完整门禁按源码控件、动作类型和归属用例核对覆盖；挂载实例的待访问项用于诊断，日期等值域和互斥分支由所属测试断言验收。完整覆盖表包含各页面、平台专项及对应夹具，维护入口为 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)。

真机执行期间保持 App 前台并暂停手动操作。设备要求 Enable UI Automation 验证时，在设备上完成系统授权后重试。失败附件保留原生元素树和截图；实际执行与通过数量沿原始 XCTest 结果验收。

## 授权后的模拟器验收

模拟器入口按当次会话的明确授权执行：

```sh
BIT101_SIMULATOR_AUTHORIZED=1 Scripts/run-extended-tests.sh simulator info
BIT101_SIMULATOR_AUTHORIZED=1 Scripts/run-extended-tests.sh simulator prepare
BIT101_SIMULATOR_AUTHORIZED=1 Scripts/run-extended-tests.sh simulator app 测试类
BIT101_SIMULATOR_AUTHORIZED=1 Scripts/run-extended-tests.sh simulator ui 用例关键词
BIT101_SIMULATOR_AUTHORIZED=1 Scripts/run-extended-tests.sh simulator verify
```

入口复用唯一项目设备、公共缓存和固定结果目录，并准备所选 Xcode 所需的官方运行时。`app`、`release-runtime`、`ui` 省略筛选时执行各自完整库存；`verify` 聚合模块、iOS 行为、正式组装、UI、静态审计、结果合并、覆盖率及常规 App 恢复。Catalyst、归档、线上服务与实体设备验收分别由所属流程承接。

适配特定设备时，通过 `BIT101_SIMULATOR_DEVICE_TYPE='iPhone Duo' Scripts/run-extended-tests.sh simulator prepare` 选择设备类型；该配置接受 Xcode 库存中的名称或标识，准备对应的官方运行时，并沿固定设备记录复用后续测试与恢复。Duo 布局沿 [Apple 适配指南](https://developer.apple.com/iphone-duo/prepare/)核对内外屏、旋转、折叠切换和非对称安全区；Device Hub 负责切换姿态，课表旋转合同验收选中周次、主导航和内容操作区。

`simulator build-ui` 构建共享 UI 宿主；`simulator merge` 归集 CI 分片。测试结束后恢复常规 Release；`simulator restore` 支持独立恢复，`simulator inspect` 读取安装身份与实际屏幕。恢复结果核对进程、会话和活跃场景。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/run-static-audit.sh --self-test
Scripts/check-module-boundaries.py
python3 Scripts/check-python-syntax.py .
python3 Scripts/check-docs.py
```

本地默认入口执行工作区当前内容的全部静态规则，提交钩子检查暂存区内容。组合审计先报告当前源码的检查结果，源码通过后执行检查器自测。修改检查器或验证协议后，使用 `--self-test` 同时验收规则自身的回归合同；CI 和发布检查自动执行完整自测。解析结果按[静态事实缓存](#静态事实缓存)规则复用。

依赖安全检查可独立执行 `(cd Cloudflare/EmergencyUpdateWorker && npm audit --audit-level=high)`。统一审计将该组结果保存到独立依赖日志。完整静态审计汇总各组状态；离线开发沿对应语法、架构与文档入口执行定向检查，完整验收获取当前依赖安全结果。

统一入口检查 Swift 语法、SwiftSyntax 事实合同、模块依赖及资源归属、设计系统、UI 交互登记、并发规范、脚本接线、文件长度、文档链接、版本和锁定依赖。Swift 类型与隔离语义由实际构建验收；行为、恢复与跨平台差异由对应测试验收。

规则维护者为新增规则提供触发、合规与故障样例，并复用编译器事实入口。动态分派、宏及第三方二进制行为结合正式编译条件测试和设备观察核对。检查器职责和资源边界见 [架构与数据边界](ARCHITECTURE.md)，通用界面规范见 [设计系统](DESIGN_SYSTEM.md)。

仓库维护文件上限为 1000 行。提交钩子沿完整暂存内容检查长度和文档引用；Python 与嵌入 Python 的语法及名称检查覆盖变更脚本，Python 依赖图沿暂存模块核对。检查入口变更触发完整脚本库存检查。工作树检查用于日常开发。文档随永久接口与流程维护，脚本内部解析细节沿对应源码和回归样例维护。检查器自身回归通过 `--self-test` 在统一审计中执行；日常检查与提交钩子验收当前输入。

独立检查组并行运行，固定日志由审计锁协调。退出时回收所属工作进程并保留原始退出状态；终端显示失败组和有效诊断，完整日志继续保存在固定路径。

## 固定产物与结果读取

| 类别 | 固定路径 |
| --- | --- |
| 公共编译缓存 | `.build/compiler-cache/` |
| 测试构建、日志与指标 | `.build/extended-automation/` |
| 原始测试结果 | `.build/extended-automation/test-results.xcresult` |
| 验证报告 | `.build/extended-automation/validation-evidence.json` |
| 设备截图 | `.build/screenshot.png` |
| 网络 Smoke | `.build/release-network-smoke/report/release-network-smoke.json` |
| 社区验收配置 | `.build/release-network-smoke/community-configuration.json` |
| iCloud Smoke | `.build/icloud-cross-device-smoke/report.json` |

```sh
Scripts/run-extended-tests.sh report
Scripts/run-extended-tests.sh report json
Scripts/run-extended-tests.sh report coverage
Scripts/run-extended-tests.sh report '测试类/方法()'
Scripts/run-extended-tests.sh activities '测试类/方法()'
Scripts/run-extended-tests.sh screenshot '测试类/方法()'
Scripts/run-extended-tests.sh diagnostics
Scripts/run-extended-tests.sh cache
```

默认 `report` 显示结果、耗时摘要、完整指标与失败记录路径。排查单个失败时，传入 `测试类/方法()` 读取附件数量和文本路径。

`activities` 读取原始操作记录；`screenshot` 列出当前用例的截图标识，指定标识后导出一张截图。`diagnostics` 导出当前失败包，排查完成后清理导出副本并保留原始结果。

同类日志、截图和报告覆盖固定路径。本地与 CI 的失败摘要共用行数和字符预算，长文本保留首尾；完整诊断沿日志路径和 CI 产物读取。缓存占用与维护通过 `cache` 入口查看，资源复用规则集中在[公共缓存与工作流资源](#公共缓存与工作流资源)。

## 网络与 iCloud Smoke

### 网络读取与学校认证

自动网络采样遇到学校 CAS 短信验证时返回认证阻塞。`--sms` 使用统一的短信续接回调，并在控制台输出等待验证码的用途，方便人工接续。

```sh
Scripts/release-network-smoke.sh prepare
Scripts/release-network-smoke.sh bit101
Scripts/release-network-smoke.sh school
Scripts/release-network-smoke.sh ddl
Scripts/release-network-smoke.sh all sms
```

读取范围为 `all`、`bit101`、`school`、`transcript`、`schedule`、`ddl`。宿主使用授权账号的正式会话与业务服务，并按探针强制远端读取。学校范围执行对应认证；短信模式在设备面板完成服务端提出的 challenge，随后验证原业务继续。指定学期的 `BIT101_NETWORK_SMOKE_TERM` 形成定向结果。

`prepare` 从当前会话及列表采集专用账号、维护对象和已关注目标，保存到 `.build/release-network-smoke/community-configuration.json`。后续 `all`、`bit101`、`community-writes` 自动读取这份配置，宿主在执行社区操作前核对当前账号。环境变量可显式指定账号、维护对象和关注目标。配置与采样报告分别维护，连续采样沿用已准备对象。

也可通过 `BIT101_COMMUNITY_SMOKE_ACCOUNT` 和 `BIT101_NETWORK_SMOKE_FIXTURES` 显式指定账号及包含 `posterID`、`courseID`、`courseNumber`、`paperID` 的维护对象。对象需提供对应文本、图片、评论、搜索与分页样本。消息读取会影响服务端未读数，使用具备历史分页样本的专用账号。

报告分别记录服务健康、必需探针、认证、请求合同和样本覆盖。空业务结果保持其真实语义；完整验收继续核对所属探针需要的样本，覆盖缺口以状态码 2 呈现。独立探针继续归集结果。端点、方法、参数、实体与分页合同沿 [网络请求合同](../Scripts/network_request_contracts.py)及实际响应验收。

实网验收豁免 `community.report-types`、`message.follow`、`message.system`、`message.like`、`message.comment`：对应样本依赖外部服务端配置、管理员权限及其他账号互动。报告通过 `exemptedProbes` 单独记录原因；必需探针清单按其余项目验收。消息列表真实跨页由订阅消息验收，公开帖子评论分页独立验收。

外部后端由对应维护者处理，iOS 保存脱敏请求与响应证据，并验收协议适配、错误呈现和恢复行为。失败探针可通过 `Scripts/run-extended-tests.sh network-smoke NetworkSmokeRegressionTests` 执行受控回归。

### 社区线上写入与恢复

```sh
BIT101_COMMUNITY_SMOKE_ACCOUNT=验收账号ID \
BIT101_COMMUNITY_FOLLOW_TARGET=已关注目标UID \
Scripts/release-network-smoke.sh community-writes
Scripts/release-network-smoke.sh community-cleanup
```

写入专项按授权账号创建帖子、文章、评论和回复，验证图片、编辑、点赞与关注恢复，再逐对象删除并读回确认。每次线上副作用先保存固定恢复记录；账号、对象归属、完整验收标记与请求代际共同约束清理范围。

异常、中断或响应丢失时保留恢复记录，沿 `community-cleanup` 继续确认和清理。各对象独立保存进度，账号变化后按身份边界处理。长期待确认的服务端尝试由维护者提供对应请求已结束的凭据，再通过 `BIT101_COMMUNITY_RECOVERY_CONFIRMATION` 提交恢复确认。恢复字段及验收逻辑见 [社区写入恢复](../BIT101-iOS/Shared/Client/CommunityWriteSmokeJournal.swift)。

### iCloud 双端

完整往返核对手机与 Mac 的真实云端读写及删除传播。中断后的恢复由 Mac 确认云端记录删除，手机清理本机验收文件、钥匙串和 KVS 状态；每次恢复在各端执行一次，并保留失败结果供后续恢复。

```sh
Scripts/run_icloud_cross_device_smoke.sh
Scripts/run_icloud_cross_device_smoke.sh report
Scripts/run_icloud_cross_device_smoke.sh cleanup
```

iPhone 与 Catalyst 使用同一 Apple ID，并可访问 KVS、CloudKit Production 和 iCloud 钥匙串。两个专用宿主使用独立验收账号、偏好与磁盘目录，通过生产协调器完成手机到 Mac 再到手机的成绩、日程、设置、筛选与已读状态往返。

完整验收核对两端版本、实际业务载荷、冲突与清理结果。手机离线时先完成 Mac 恢复，再沿原设备身份继续手机清理；报告保留待恢复状态。双端清理观察对端删除，独立清理记录各自的提交范围。测试完成后保留采样现场，相关回归通过后统一恢复常规 App。

## CI 与覆盖率

日常 PR、main 推送与默认手动工作流执行完整静态审计。该范围由项目维护策略确定。语义编译和原生行为在本地定向回归、手动完整验收及发布工作流执行。

```sh
gh workflow run ci.yml --ref main -f full_check=true
gh run rerun 运行编号 --failed
```

手动 `full_check` 按 [CI 工作流](../.github/workflows/ci.yml)执行登记的模块、编译与行为验证。UI 交互沿本地验收入口执行，发布所需的真机、线上服务与跨端证据由对应专项提供。版本标签和 `release_check` 核对发布回执，手动发布同时填写 `validation_tag`。新增提交自动取消同分支常规旧运行，发布流程保留设备恢复时间。

操作者选择 `full_check`、`release_check` 或发布标签时，授权对应 GitHub 运行器准备并执行工作流中的模拟器范围。开发代理执行本机模拟器流程时，沿当前会话的明确授权设置入口标记。

托管任务采用工作流登记的 Apple 工具链镜像；真机验收通过本地 Mac 与已连接的 iPhone 执行。外部 PR 的运行器准入和审批由仓库及组织设置管理。维护者审查外部 PR 时，使用 GitHub 实际 merge 提交创建 `review-validation` 分支，并填写 `review_pr`；提交与目标分支变化后重新验收。

版本标签和 `release_check` 按所属验证组复用成功结果和公共缓存；`full_check` 在当次执行全部组。

性能目标为完整工作流 30 分钟以内，计时包含准备、编译、缓存传输、测试、恢复和汇总；单个阶段的超时预算属于执行上限。验证证据和模拟器生产记录的 `durationSeconds` 保存所属入口的实际耗时，CI 诊断产物保留这些采样以便比较。取消任务上传有大小限制的文本诊断，常规成功与失败沿所属清单上传完整诊断。

[验证策略](../Scripts/validation_policy.py)维护 macOS、iOS、App 及 UI 的版本化行覆盖门槛，目标提交门槛参与合并验收。行覆盖、实际状态断言和控件交互分别提供各自证据。关键失败、账号变化、取消和恢复路径按 [状态合同库存](../Scripts/validation_test_areas.py)维护；新增行为同步补充对应回归。平台数据沿各自的实际编译范围解释。

## 发布与人工专项

获得对应专项授权后，`Scripts/run-extended-tests.sh verify` 聚合自动组，包含真机、社区线上写入、iCloud 往返和正式归档。入口在执行前显示实际分组；可显式选择分组，例如 `verify audit modules`、`verify all ui`。`--self-test` 为审计附加检查器回归，`--sms` 启用学校短信专项，两个选项可以组合。最终发布同时核对网络、学校短信、社区写入、iCloud、正式归档、设备恢复及人工专项。核心设备与外部采样采用 24 小时有效期。

人工专项覆盖最低系统、分发签名、首次登录、安装路径、系统自动填充、照片、日历、定位、通知、外部交接、网页、Widget、Watch、消息、资料写入、举报、iPad 布局和反馈送达。每项保存实际操作、观察结果、通过或失败状态、观察时间和原始附件。`manual-schema` 按场景专项输出字段说明、附件编码、能力观察和动作结构；缺失字段显示完整路径，专项合同失败时标明所属场景。[人工证据合同](../Scripts/validation_manual.py)维护具体校验规则。发布证据核对当前分发二进制、归档与可执行 UUID，整包输入共同约束实际安装产物的验收身份。

```sh
python3 Scripts/validation_evidence.py manual-schema photos
python3 Scripts/validation_evidence.py manual 检查项 \
  --operation "实际操作" --result "观察结果" --outcome passed \
  --observed-at "实际观察的 ISO 8601 时间" --evidence 本地附件路径
```

系统权限专项覆盖授权、拒绝、设置撤销与恢复。最低平台和安装专项记录实际设备、系统、应用版本、构建、分发来源和可执行 UUID。照片、Widget、Watch 和真实系统投递通过设备观察验收；邮件送达绑定正式报告、存储记录与实际收件头。

分发验收先执行 `Scripts/build-install-device.sh archive-signed`，再通过 Xcode 的 App Store 导出流程取得最终 `.app`，运行 `python3 Scripts/validate_distribution.py 导出应用路径`。签名、描述文件、团队、版本、平台、最低系统、扩展归属、权益和最终隐私清单共同形成 `build/DeviceInstall/distribution-signing.json`，并登记到 `distribution-signing` 人工专项。发布上传同时向 App Store Connect 交付当前归档中的 App 与各扩展 dSYM，沿 [Apple 的符号上传说明](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)操作；在对应版本的处理结果中确认符号接收，将平台回执登记为该专项的证据。固定归档路径在下一次归档时覆盖，后续商店崩溃报告沿该版本已上传的符号解析。

性能采样使用 [性能负载](../BIT101-iOSTests/PerformanceWorkloads.json)和原始 XCTest 指标，比较同设备、系统、工具链及生产配置下的耗时与内存。完整行为和 UI 运行后，通过 `Scripts/run-extended-tests.sh performance baseline 批准人` 保存批准基线，后续候选使用 `performance current`；迁移工作区使用 `python3 Scripts/ci_evidence.py import-baseline CI运行编号`。

提交全部改动后，`python3 Scripts/validation_evidence.py bind` 绑定完整本地证据，`python3 Scripts/validation_evidence.py check` 核对当前输入、环境、结果和提交。发布回执通过 `python3 Scripts/ci_evidence.py publish v公开版本号` 生成固定 `release-receipt.json` 附件，沿发布授权上传。公开回执保存必要的版本、提交、执行状态及采样身份，完整设备、邮件和影像证据沿本地报告审阅。

## 验证输入与结果协议

### 输入与结果复用

编译验收覆盖完整产品输入。网络与 iCloud 的已完成采样沿生产能力及其模块依赖绑定，壳层组装、资源、manifest 和所属脚本共同参与输入；独立模块的改动按实际依赖决定专项复验。静态审计实现沿审计流程验收，网络与 iCloud 业务采样绑定采集实现及协议合同，现有请求与响应继续接受当前规则校验。完整行为组与 UI 组沿同一固定结果路径事务合并，各组保留自己的原始执行身份与性能采样。定向回归保留有效完整验收包，并覆盖 `diagnostics/test-results.xcresult` 中的当前诊断；完整验收继续使用 `test-results.xcresult`。报告、活动记录与截图按原始结果的写入时间选择当前包，元素树与崩溃日志汇集到同一份带来源说明的诊断文本。覆盖率按平台的实际可执行源码验收，账号切换、取消、存储故障和内容恢复由关键合同逐例检查。

本地验证直接比较所属文件内容、执行权限和环境，相同内容在提交前后沿用身份。共享证据以稳定的匿名身份交换本机路径与设备标识。已提交输入按 Git 第一父提交链读取相关差异，合并提交纳入相对第一父提交的改动；所属组与 Worker 共用这一身份口径，范围外改动保留相关结果。公开发布回执核对已提交输入和工具链。大型文件等维护候选保存在固定代码质量报告中，按需打开审阅。

### 原始结果与批次

同类日志、截图和报告覆盖固定路径。`test-metrics.txt` 保存构建与运行耗时、逐例结果、最慢用例、进程及交互统计。`report json` 和 `report coverage` 沿当前批次读取模块事件及模块覆盖率，或原生结果包。报告按指标和结果包的完成顺序选择当前来源；新构建结果优先于旧测试指标，构建诊断沿所属结果包呈现。

模块测试失败时同样生成当前批次指标，`report` 与 `report json` 呈现本次失败和模块日志；事件采集失败会说明原因。模块覆盖率沿成功执行生成。

原生结果保存到固定结果包，中断时恢复前序结果。相邻完整测试组共同汇总，同组再次完整执行时开启新批次；`verify` 从首组开始组织完整验收批次。定向复验保留相同输入和环境下的完整结果，发布验收核对采样时效。性能采样按所属输入和工作负载复用。

输入变化、相关失败或证据过期时，所属完整组进入重新验收。模块测试及诊断整理保留当前原始失败包，新的结果生产流程覆盖所属诊断。CI 汇总完成后清理远端缓存，并上传构建失败的原始诊断包。

### 公共缓存与工作流资源

缓存维护保留增量编译所需文件，共享 SDK、模块、原生 CompilationCache 和索引，保留当前产物与测试宿主的配套符号；孤立符号按产物生命周期回收。CompilationCache 容量采用工具链默认策略，完整静态审计的产物准备阶段集中执行原生回收；显式缓存维护展示占用统计，并按构建依赖保留所需模块。远端缓存按来源提交与工具链选择，恢复失败后沿当前源码编译。缓存与诊断保持原始形式，CI 产物使用零压缩传输。

构建与静态条件求值共享编译缓存的读锁，缓存目录迁移和回收持有写锁。中断工作流时先归集当前用户的子进程所属的进程组，完成后台任务清理后释放工作流锁。

App 与扩展沿 Release 编译配置验收，XCTest 和 UI 测试包采用增量编译，定向修复复用其他测试文件的编译产物。

工作流先取得工作副本产物锁，再取得用户级共享资源锁。模块与 Catalyst 测试的固定系统偏好沿共享锁串行验收；聚合流程继承锁、设备及总时钟。网络采样和反馈读取采用通用终端输出预算，长报告显示首尾内容及完整报告路径。

聚合验收的首个 XCTest 组沿完整验收入口保留可复用的其他组原始结果，后续组继续合并到同一结果包。

CI 的行为库存选择数字型号 iPhone 的最新运行时与最新标准机型，并复用相同设备类型。UI 交互在本地真机验收，CI 配置检查器拒绝 UI 测试入口及包含 UI 的默认全量测试命令。

超时和取消沿整个工作流进程组回收后台工作，设备及产物锁覆盖恢复与回收过程。工作流自然或失败退出时，所属进程组的遗留工作完成回收并登记失败；监督器异常退出沿同一回收路径处理。审计 worker 提前结束时同样核对所属进程组。远端缓存按 HTTP 分段流式接收，状态、范围及长度在所属分段中校验，整次下载共用五分钟期限。

### 静态事实缓存

SwiftSyntax 事实保存在固定 SQLite 数据库中，跨审计复用。语法文本通过 UTF-8 字节区间引用共享源文件，调用清单按调用节点编号还原，语义字段保留编译器表示。索引器源码、工具链和交互规则共同决定缓存版本；版本变化后重建事实并回收旧存储页，源码按实际内容更新，已删除文件的条目同步回收。

并行检查按文件读取事实，各次请求持有独立对象。测试继承按当前请求的文件集合解析，别名展开等变换内容独立解析。

### CI 结果归集

候选从 main 分支的手动验收历史分页读取，各组通过完整验收后生成独立结果记录，复用时核对来源提交、运行、输入差异、实际 Xcode、编译器、SDK 和宿主系统。

App 行为与正式组装结果核对 iOS 模拟器的系统版本与构建号，并以完整库存及覆盖率归集的结果为依据。模拟器成功记录沿独立字段保存；发布流程核对本地真机生成的 UI 验收证据。

CI 归集核对行为测试的全部用例、参数实例、来源提交、实际设备和合并覆盖率。
