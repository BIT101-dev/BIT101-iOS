# 构建与测试

## 执行约定

- 构建使用 Xcode 27.x、有效签名和已连接并受信任的真机，默认完成 Release 构建、装机与启动。
- 本机构建、装机和启动统一使用 `Scripts/build-install-device.sh`；脚本封装所需 Xcode 流程。
- iOS / watchOS 验证使用真机；包级逻辑测试使用 macOS 原生宿主，Catalyst 行为测试使用 macOS runtime。
- 测试、静态审计、网络 Smoke 和 iCloud Smoke 按用户明确授权的范围执行。失败修复后重跑受影响的分组。
- 界面验证使用既有 UI 测试、截图脚本与命令行流程。设备自动化授权由 iOS 管理，系统要求时由用户在设备上输入密码，设备继续保留密码保护。
- `BIT101-iOSTests/Fixtures/` 和测试 target 内的样例、fixture、校准及人工准备数据属于长期资产，沿用固定路径。清理或改写前确认来源、用途和恢复方式，并取得用户明确同意。

## 脚本入口

脚本按完整工作流组织，公共设备选择与日志处理集中在 `Scripts/script-support.sh`。入口数量保持精简，同一工作流通过参数选择操作；优化以执行耗时、重复调用和终端信息价值为依据。主工作流及 Cloudflare 发布脚本合计 14 个文件；本机静态审计基线为 64.15 秒，复用索引器并缓存路径判断后的后续运行约 20 秒。

| 工作流 | 入口 |
| --- | --- |
| 构建、装机、截图、设备信息 | `Scripts/build-install-device.sh` |
| 模块、App、UI、Catalyst 与聚合验证 | `Scripts/run-extended-tests.sh` |
| 语法、工程、依赖、文档与设计规则审计 | `Scripts/run-static-audit.sh` |
| 网络探针与范围选择 | `Scripts/release-network-smoke.sh --scope 范围` |
| iCloud 双向验证、报告与恢复 | `Scripts/run_icloud_cross_device_smoke.sh` |
| Issues、CI 失败与反馈报告管理 | `Scripts/fetch-issues-and-reports.sh` |

输出处理器验收覆盖 1000 / 1001 行、完整留档、信号退出状态及执行期间改写源码的故障注入。报告列表实际读取 29 条，终端直接展示可读内容。测试计数与 Smoke 实测结果见下方集成验证记录；UI 结果通过 `Scripts/run-extended-tests.sh --report` 汇总，结果包沿用固定路径。

构建、测试、Smoke 和报告管理入口均提供 `--help`。质量、UI、模块边界、文档新鲜度与版本检查器保留独立入口，便于针对单项问题执行；统一审计通过共享 SwiftSyntax 索引执行质量与 UI 检查，并输出解释文案审查候选。地图 fixture 生成使用 `Scripts/generate_campus_map_fixture.py <教务导出.xlsx>`，沿用既有人工审核和固定数据路径约定。

## 构建、装机与截图

```sh
Scripts/build-install-device.sh
Scripts/build-install-device.sh --compile-only
Scripts/build-install-device.sh --compile-only <真机设备ID>
Scripts/build-install-device.sh --compile-only --generic
Scripts/build-install-device.sh --screenshot
```

所有真机入口共用 `Scripts/script-support.sh`：依据一次 CoreDevice 设备快照优先选择可用的 USB 有线设备，有线设备缺席时立即选择已配对、当前可发现的无线设备。快照同时提供 CoreDevice UUID 和设备 UDID，构建、装机、启动、截图、测试、网络 Smoke 与 iCloud Smoke 使用同一台设备。显式传入设备 ID 时按该设备选择，支持 UDID 和 CoreDevice UUID。

设备选择在构建与测试启动前完成，连接类型回退由当前可发现状态触发。设备全部离线时立即退出并提示连接方式。设备发现沿用 CoreDevice 默认参数，执行一次列表读取。

[无线调试](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)要求 iPhone 与 Mac 完成 Xcode 配对、开启开发者模式并连接同一局域网。通过既有脚本读取设备详情，验证当前连接：

```sh
Scripts/build-install-device.sh --device-info
Scripts/build-install-device.sh --device-info <真机设备ID>
```

检查输出中的 `wired` 表示有线连接，`localNetwork` 表示无线连接。

Mac Catalyst 构建与安装沿用同一入口：

```sh
BIT101_INSTALL_TARGET=macCatalyst Scripts/build-install-device.sh
```

Catalyst 安装路径为 `~/Applications/BIT101-iOS.app`。截图固定覆盖 `.build/screenshot.png`。课表模型和共享展示改动同时关注主 App、Widget、Watch App 与 Watch Widget。

`--compile-only --generic` 使用通用 iOS 目的地编译 Release App 及扩展，产物覆盖 `build/DeviceInstall/`。真机行为、系统权限和实际跨端传输由设备测试验证。

## 包级与 App 行为测试

| 分组 | 宿主与范围 |
| --- | --- |
| `modules` | macOS 原生 Release；本地模块的领域、服务、存储和场景状态 |
| `default` | 真机 App 常规行为与平台适配 |
| `schedule` | 日程、编辑、缓存、分享和同步策略 |
| `infrastructure` | 网络、存储、取消和账号隔离 |
| `login` | 登录恢复、CAS、学校认证与短信 challenge |
| `extensions` | Widget / Watch 共用快照、传输、状态与时间线 |
| `catalyst` | Mac Catalyst 行为测试 |

```sh
Scripts/run-extended-tests.sh modules
Scripts/run-extended-tests.sh default
Scripts/run-extended-tests.sh schedule
Scripts/run-extended-tests.sh infrastructure
Scripts/run-extended-tests.sh login
Scripts/run-extended-tests.sh extensions
Scripts/run-extended-tests.sh catalyst
```

包级测试由 `Package.swift` 的 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个消费者 target 管理，代码位于 `ModuleTests/`，使用内存传输、文件服务、偏好和实例级变更流。覆盖社区身份与恢复隔离、日程保存排队、精确版本往返与过期比较令牌、文件损坏和账号切换、生产成绩服务注入、独立成绩与消息存储端口、变更流的实例及账号归属、共享草稿图片准备和版本清理、同步冲突及地图身份规则。社区持久化测试通过 `CommunityPersistence` 的公共入口运行。测试用内存文件服务集中于 `ModuleTests/Support`，直接依赖 StorageCore。学校课表解析沿用 `BIT101-iOSTests/Fixtures/schedule-service-response.json`。MapKit 页面、UIKit、Quick Look 和可信成绩单展示通过 App 宿主验证。

`FeatureCompositionTests` 在 App 宿主组合不同的环境依赖，验证课程、Gallery → Paper、Paper、Mine、Profile、Schedule 的构造归属，并验证同一宿主中 Paper / Gallery 依赖替换的场景重建。`MediaDependencyTests` 验证内存存储、静态 / GIF 解码和预览字节；`SuggestionDependencyTests` 验证草稿及提交归属；同文件的 `AppLocalDataOwnershipTests` 与 `SettingsDependencyOwnershipTests` 验证清理动作顺序、失败汇总、后端隔离和设置媒体 / 账号归属。`ExperimentalPreferenceCloudSyncTests` 使用独立通知中心和平台替身验证生命周期实例隔离及所选课程源向成绩场景传递。

按现有测试类或方法选择范围，多个筛选项在同一次调用执行。Swift Testing 方法名保留 `()`，suite 名称用于整组运行；脚本按实际用例数量验收选择范围：

```sh
Scripts/run-extended-tests.sh default \
  --only-testing ExperimentalPreferenceCloudSyncTests \
  --only-testing ScheduleModuleBoundaryTests \
  --only-testing NetworkClientTests
```

`--build-only` 编译所选宿主的测试产物。通用 iOS 编译使用 `--build-only --generic`，CI 覆盖正式 Release、UI、网络 Smoke 与 iCloud Smoke 四种编译条件：

```sh
Scripts/run-extended-tests.sh release --build-only --generic
Scripts/run-extended-tests.sh ui --build-only --generic
Scripts/run-extended-tests.sh network-smoke --build-only --generic
Scripts/run-extended-tests.sh icloud-smoke --build-only --generic
```

`--clean-build` 清理固定测试产物目录后执行所选流程。全量逻辑测试使用 `Scripts/run-extended-tests.sh`。

## UI 自动化

`BIT101-iOSUITests` 使用 `BIT101-iOS-UIAutomation` Release scheme 和真机宿主。`BIT101_UI_TESTING` 构建隔离 Keychain、偏好、账号文件和媒体缓存，使用合成会话及离线服务。测试文件归 App 内固定的 `Application Support/BIT101-UITests/` 根目录，系统日历与提醒动作使用内存端口，偏好云同步使用内存云存储。正式 App 由生产组装入口启动。测试默认关闭 UIKit 动画，文章连续编辑场景启用系统动画，验证导航与输入生命周期。

UI 用例按页面组合连续交互，每项独立重置隔离数据；持久化场景在同一项内重启 App。覆盖目标包括每个点击、滑动和输入入口，并验证交互后的业务状态。当前定义 76 项用例，逐项映射和运行验收状态见 [UI 交互覆盖](UI_INTERACTION_COVERAGE.md)：

| 页面 | 交互范围 |
| --- | --- |
| 登录与主导航 | 必填字段、键盘及按钮提交、滚动收起键盘、账号隔离、五个 Tab、浅深色辅助功能大字号 |
| 课表 | 周次按钮及拖动、分栏横滑、长按菜单、添加 / 编辑 / 删除日程、日期时间选择器、课程补录 / 调课 / 删除、日期放假 / 调休确认、上下滑切换分享课表、线性时间轴滚动和双指缩放 |
| 日程设置 | 时间轴、时间表校验 / 保存 / 取消、学期切换 / 下拉刷新、日期滚轮、开关 / 提醒阈值持久化、名称、编码复制 / 粘贴导入 / 分享、新版本编码更新提示、分享课表改名 / 左滑删除、整学期及单项日历导入 / 移除 |
| DDL 与空教室 | 学校双来源、详情、完成状态、手动待办增改删、日期时间及详情编辑、学校刷新 / 订阅链接刷新 / SSO 短信继续、校区 / 楼宇选择、教室刷新、节次多选 / 全选 / 清除 |
| 成绩与课程 | 查询及刷新短信错误重试 / 取消、逐项及批量筛选、排序、已出分 / 未出分详情、课程评价路由、可信成绩单多页预览、课程搜索 / 清除、数据清洗、历史图拖动、点赞、半星评分 / 匿名评论 / 回复 / 评论图片 / 分享 |
| 地图 | 校区、图层、平移、缩放、定位 / 单次权限授权、课程地点路由、下一节课系统地图导航、重启恢复 |
| 话廊与文章 | 分类点击及横滑、搜索 / 清除 / 排序 / 结果路由、消息横滑 / 分类 / 已读 / 详情、列表及详情下拉刷新、发布校验 / 标签 / 声明 / 开关 / 草稿、发布 / 修改 / 删除、图片预览 / 上传重试 / 图片移除、正文链接、点赞、评论排序 / 点赞 / 回复、长按复制 / 举报 / 删除及确认 / 取消、分享、离线重试及恢复 |
| 我的与设置 | 个人及公开主页统计列表 / 刷新、关注 / 取消关注、头像预览 / 选择器取消、个人帖子详情 / 删除、标识显示 / 隐藏、资料保存 / 取消 / 登录检查 / 退出、屏蔽 UID 校验、网页话廊 / 滚动 / 切回原生、偏好及缓存上限持久化、建议草稿 / 图片 / 提交确认 / 成功 / 失败、错误报告模式及提交分支、开源声明 / 外部链接 / 更新提示全部动作 / 缓存清理 / 确认重置、网络诊断 |

`BIT101_UI_TEST_CONTENT=1` 选择内存 HTTP 固定响应，并经过生产社区 Service 的解码与状态逻辑；默认场景使用离线失败响应。响应维护当前会话的点赞、评论、关注、资料和文章 / 话题增改删状态，新增内容可以在后续详情请求中读取。学校、媒体、单次失败和更新响应配置见交互覆盖文档。页面发出的外部 URL 在 UI 宿主显示完整目标地址，地图导航使用系统 Maps。元素和状态先读取当前值，异步变化采用条件等待。输入前识别系统键盘，第三方键盘通过键盘切换按钮切换，输入后核对完整字段值。测试按页面合并操作、按场景启动，多个筛选项共享一次串行 Runner 会话，结束后恢复常规 App：

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh ui <真机设备ID>
Scripts/run-extended-tests.sh ui \
  --only-testing LoginAndScheduleUITests/testLongPressOpensScheduleContextMenuAndImportSheet \
  --only-testing LoginAndScheduleUITests/testManualSchedulePersistsAcrossAppRelaunch
Scripts/run-extended-tests.sh ui \
  --only-testing LoginAndScheduleUITests/testSchoolDDLSourcesAndCompletionPersistAcrossAppRelaunch \
  --only-testing LoginAndScheduleUITests/testDDLEmptyStateExplainsTheRetentionWindow
```

稳定的 `accessibilityIdentifier` 用于字段、主 Tab 和编辑入口定位；列表定位核对导航栏、Tab 和弹窗的可见边界，滚动从列表边缘开始。失败的元素树和截图保存在既有 `.xcresult`，状态等待失败同样采集附件。

文章编辑复用详情页已解析的正文，由详情页导航承接；编辑与删除成功后刷新文章列表和搜索结果。回归核对标题、简介与正文恢复、保存后返回详情、再次编辑及取消保留已保存内容，删除验收同时核对原始和修改后的标题。文章评论使用独立输入弹窗。验证码提交先结束输入焦点，回归覆盖错误重试、查询成功及成绩筛选与详情。

读取本次结果与逐项耗时、检查某项失败的界面元素树：

```sh
Scripts/run-extended-tests.sh --report
Scripts/run-extended-tests.sh --report 'LoginAndScheduleUITests/testCalendarSettingsPickersTogglesAndRenamePersist()'
Scripts/run-extended-tests.sh --report 'LoginAndScheduleUITests/testLinearScheduleTimelineScrollAndPinch()' --screenshot
Scripts/run-extended-tests.sh --report 'LoginAndScheduleUITests/testPaperPublishEditCommentAndDelete()' --activities
```

单项元素树覆盖写入 `.build/extended-automation/failure-hierarchy.txt`，便于编辑器检索；失败截图覆盖写入 `.build/screenshot.png`。`--activities` 展示最近 30 条操作和失败记录。

交互列表的左侧标题由 SwiftSyntax 审计检查公共主题色或警示色修饰器、标题组件及样式覆盖；UI 回归裁切“时间轴”的实际字形，检查彩色像素，覆盖源码规则和真实渲染两个层面。

`test-metrics.txt` 保存用例耗时合计和最慢的十项，用于比较覆盖扩展后的执行成本。开发时通过多个 `--only-testing` 合并受影响的场景；完整覆盖验收运行整个 UI 组。真机专项验证承接真实照片选取、日历 / 提醒权限、外部邮件 / 浏览器交接、网页自身交互及 Widget / Watch 界面。UI Runner 的设备自动化初始化超时单独记录为环境阻塞，实际执行和通过数由 `.xcresult` 汇总。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/check-module-boundaries.py
```

统一入口汇总 SwiftSyntax 契约、UI 规则、客户端工程规范、模块依赖、文档链接、工程配置和锁定依赖检查。源码质量扫描覆盖 App、模块、扩展和 `ModuleTests/`；语法检查同时覆盖 UI 测试。客户端日志、社区日期和状态模型取消规则依据当前模块目录执行。Swift 词法扫描保留普通、原始、多行及嵌套字符串的插值表达式，全局资源访问在插值中同样接受检查。模块检查器自测导入解析、循环、依赖方向及全局资源访问约束，校验声明、实际导入、测试依赖以及 App 和扩展的直接产品依赖。规则按职责由对应检查器维护；设计系统的入口与规则见 [设计系统](DESIGN_SYSTEM.md)。

模块检查器同时校验服务实现归属，覆盖生产源码中的直接网络发送、会话及网络缓存访问、重复系统网络监听、文件读写、元数据和符号链接解析，以及偏好默认实例选择。包级 `ClientCoreTests` 验证连接断开、恢复与实例隔离；App 的 `NetworkClientTests` 验证诊断文字消费所选网络状态。

SwiftSyntax 共享索引入口通过 `.build/static-audit/swift-syntax-indexer.lock` 串行使用源码及可执行产物，代码质量和 UI 检查器共用同一入口。源码更新、编译和索引读取在同一次锁内完成。

静态审计入口通过 `.build/static-audit/audit.lock` 串行维护固定日志，整个分组流程在同一次锁内执行。

## 网络与 iCloud Smoke

网络 Smoke 使用正式 App 保存的会话、Cookie 与缓存，专用 Release 宿主完成探针后恢复常规 App：

```sh
Scripts/release-network-smoke.sh --scope bit101
Scripts/release-network-smoke.sh --scope school
Scripts/release-network-smoke.sh --scope ddl
```

可选范围为 `all`、`bit101`、`school`、`transcript`、`schedule` 和 `ddl`。每个范围均维护必需探针清单，报告分别记录服务健康、执行探针和覆盖完整度。覆盖判定核对该范围的完整清单与实际执行记录，部分覆盖返回状态码 2。学校短信 challenge 记录为认证受阻，短信输入由真机流程验证；反馈探针在同一请求内创建、读取并清理临时报告。

DDL 范围覆盖社区登录、课程中心原生认证、课程中心作业读取、乐学订阅发现和 ICS 下载。原生认证探针使用独立 Cookie 容器，携带学校 SSO 会话完成课程中心认证。报告的 `eclassDDL` 记录认证结果、课程数、活动类型、有效截止时间数量、近期与未来作业数量及作业截止字段缺失数量，同时记录账号滞留天数、窗口内作业数量、课程中心缓存数量和截止时间范围。

课程中心接口参考 [Android PR #24](https://github.com/BIT101-dev/BIT101-Android/pull/24) 与[全课程分页提案](https://github.com/Star2121-1/BIT101-Android/pull/1)。`ModuleTests/Transport/EclassDDLTests.swift` 覆盖分页、作业字段、时间格式、并发、原生会话恢复、取消及生产服务到持久化的完整链路；`ModuleTests/Schedule/EclassDDLSyncTests.swift` 覆盖完成状态、部分失败、账号状态和过期窗口；`ModuleTests/Sync/ScheduleSyncTests.swift` 验证学校正文与完成状态的云同步边界。

### 检查器与 Smoke 集成验证记录

2026-10-01 至 2026-10-02 的集成验证结果：

| 验证 | 结果与证据 |
| --- | --- |
| 包级测试 | 157 项通过；七个消费者 target 的完整执行记录见 `module-tests.log` |
| 模块生产源码覆盖率 | 25 个模块，6522 / 17085 行，38.17%；汇总七个消费者的覆盖率对象 |
| iPhone 完整行为 | 245 项通过，失败与跳过均为 0；App 宿主行覆盖率 31.82% |
| Catalyst 完整行为 | 245 项通过，失败与跳过均为 0；固定结果包成功保存 |
| UI 交互 | 35 项全部通过，失败与跳过均为 0；UI 分组 788 秒，用例耗时合计 741 秒；App 宿主行覆盖率 39.78% |
| 真机完整网络 Smoke | 50 项必需探针通过；失败、认证受阻、覆盖缺口和跳过均为 0 |
| iCloud 双向 Smoke | 真机发布、Catalyst 接收及发布、真机回收三个阶段均通过；独立清理验证通过 |
| CI 编译条件 | 正式 Release、UI、网络 Smoke、iCloud Smoke 四种通用 iOS 测试宿主编译通过 |
| 静态审计 | 10 组通过，耗时 17 秒；覆盖语法、模块依赖、UI 规范、工程配置、文档及固定产物 |
| 恢复故障注入 | Smoke、聚合验证及 UI 流程覆盖函数内部失败、恢复失败与中断；验证恢复次数、顺序和原始状态码 |
| 日程交互回归 | 线性时间轴缩放与滚动、空白区长按菜单、自定义日程编辑及删除三项通过；课程编辑及详情用例通过 |

真实课程中心探针读取 48 门课程、1 项作业和 1 个有效截止时间，账号缓存包含对应课程中心事件。账号当前滞留窗口为 30 天，窗口内数量为 1。空列表提示显示缓存数量与当前滞留天数，便于用户调整设置。真机网络报告保存具体截止时间与窗口计数。

模块测试使用受控响应验证未来作业经过生产服务、ViewModel、账号仓库、编码解码和重新加载后的显示与完成状态；真机 UI 使用隔离缓存验证实际交互。模块行覆盖率以 macOS 原生可执行源码为分母，App 与 UI 宿主分别采集覆盖率。学校短信分支通过共享 challenge 和原生会话测试验证，真实网络探针采用 preflight 模式。真实短信输入、系统权限、Widget / Watch 界面及真实照片选择由专项真机流程承接。

iCloud 双向验证要求 iPhone 与 Catalyst 使用同一 Apple ID，手机处于解锁状态、已登录 BIT101 账号并保存成绩缓存：

```sh
Scripts/run_icloud_cross_device_smoke.sh
Scripts/run_icloud_cross_device_smoke.sh --report
Scripts/run_icloud_cross_device_smoke.sh --cleanup
```

该专用流程通过 `ICLOUD_CROSS_DEVICE_SMOKE` 条件编译执行“真机 → Catalyst → 真机”。手机发布完整成绩缓存及本次业务域版本，Mac 核对完整载荷摘要和接收版本，再发布更新的业务域版本；手机核对 Mac 的新版本及完整载荷摘要。成绩正文与查询时间由现有缓存提供，同步版本由生产协调器生成。手机账号和有效成绩缓存作为准入条件。Mac 宿主通过公共存储端口注入手机账号会话，使用生产文件服务、偏好和同步协调器完成接收与发布。

各宿主通过测试运行环境注入的同一运行标记选择本次协调记录。每个阶段要求一项用例执行并通过；阶段结果汇总到 `.build/icloud-cross-device-smoke/report.json`，完整结果包保存最近的业务验证阶段。异常清理保留该结果包并记录独立清理状态。错误钩子覆盖函数内部失败，信号钩子处理执行中断；故障注入自测验证恢复顺序和状态码。流程结束时恢复实验开关、协调数据和常规 Release App；聚合验证由外层统一恢复 App。中断后的恢复使用既有 `--cleanup` 入口。`ICloudSmokeEvidenceTests` 通过离线用例验证旧版本、空缓存和同数量内容变化的验收边界。

获得全量测试及网络、iCloud 授权后，通过 `Scripts/run-extended-tests.sh verify` 聚合验证；可选择分组，UI 筛选通过重复的 `--ui-test 测试类/方法` 参数合并到同一批次。

## 固定产物与 CI

| 类别 | 固定路径 |
| --- | --- |
| 测试构建、结果与日志 | `.build/extended-automation/`，结果包 `test-results.xcresult` |
| 测试指标 | `.build/extended-automation/test-metrics.txt` |
| 包级测试日志 | `.build/extended-automation/module-tests.log` |
| 设备截图 | `.build/screenshot.png` |
| 网络 Smoke | `.build/release-network-smoke/report/release-network-smoke.json` |
| iCloud Smoke | `.build/icloud-cross-device-smoke/`，阶段报告 `report.json` |

同类产物覆盖既有路径，文件名使用稳定类别名。终端直接展示测试汇总、审查候选与失败诊断，过滤重复进度、空章节和例行通过信息。整理后的输出在 1000 行以内时完整展示，超过阈值时提示固定文件位置。完整日志和报告覆盖既有路径。
完整测试输出写入对应固定日志，终端显示汇总和失败摘要；模块日志保留 Swift Testing 的 suite、用例及参数执行记录。模块测试汇总七个消费者二进制，采集逐模块生产源码行覆盖率，真机测试采集逐 target 行覆盖率，指标固定覆盖 `test-metrics.txt`。模块覆盖率统计 macOS 宿主编译的可执行源码，iOS 界面由真机行为与 UI 用例补充。覆盖率采集异常进入失败状态；Catalyst 使用 runtime 提供的测试汇总。
测试入口通过 `.build/extended-automation.lock` 串行使用固定产物目录，聚合验证内的分组继承同一次执行锁和设备快照，结束时统一恢复常规 App。聚合验证与独立 UI 流程的恢复钩子覆盖函数内部错误和执行中断，并保留原始失败状态码。编译宿主时保留既有测试结果包、指标和运行日志，编译日志使用固定 `<分组>-build.log`。长流程从入口读取完整脚本到内存后执行，加锁等待结束时读取当前版本，保证执行期间的文件编辑与当前流程各自稳定。SwiftSyntax 索引器在 `.build/static-audit/` 编译并复用，源码或工具链变化时覆盖重编译，编译与调用共用文件锁。

GitHub Actions 的 `.github/workflows/ci.yml` 使用 `xcode-27` runner，执行静态审计与包级测试，编译正式 Release、UI 和两种 Smoke 的 iOS 测试宿主，并运行 Catalyst 行为用例。App 依赖图同时编译 Watch 和两种 Widget，Swift / Clang 警告按错误处理。版本、plist 和 PR 基线在静态 job 校验，手动 `release_check` 校验公开版本。

本机承接真机行为、UI、网络和 iCloud 验证；发布操作按对应授权执行。
