# 构建与测试

## 执行约定

- 构建使用 Xcode 27.x、有效签名和已连接并受信任的真机，默认完成 Release 构建、装机与启动。
- 本机构建、装机和启动统一使用 `Scripts/build-install-device.sh`；脚本封装所需 Xcode 流程。
- iOS / watchOS 验证使用真机；包级逻辑测试使用 macOS 原生宿主，Catalyst 行为测试使用 macOS runtime。
- 测试、静态审计、网络 Smoke 和 iCloud Smoke 按用户明确授权的范围执行。失败修复后重跑受影响的分组。
- 界面验证使用既有 UI 测试、截图脚本与命令行流程。设备自动化授权由 iOS 管理，系统要求时由用户在设备上输入密码，设备继续保留密码保护。
- `BIT101-iOSTests/Fixtures/` 和测试 target 内的样例、fixture、校准及人工准备数据属于长期资产，沿用固定路径。清理或改写前确认来源、用途和恢复方式，并取得用户明确同意。

## 构建、装机与截图

```sh
Scripts/build-install-device.sh
Scripts/build-install-device.sh --compile-only
Scripts/build-install-device.sh --compile-only <真机设备ID>
Scripts/build-install-device.sh --compile-only --generic
Scripts/capture-screenshot-device.sh
```

所有真机入口共用 `Scripts/device-support.sh`：依据一次 CoreDevice 设备快照优先选择可用的 USB 有线设备，有线设备缺席时立即选择已配对、当前可发现的无线设备。快照同时提供 CoreDevice UUID 和设备 UDID，构建、装机、启动、截图、测试、网络 Smoke 与 iCloud Smoke 使用同一台设备。显式传入设备 ID 时按该设备选择，支持 UDID 和 CoreDevice UUID。

设备选择在构建与测试启动前完成，连接类型回退由当前可发现状态触发。设备全部离线时立即退出并提示连接方式。设备发现沿用 CoreDevice 默认参数，执行一次列表读取。

[无线调试](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)要求 iPhone 与 Mac 完成 Xcode 配对、开启开发者模式并连接同一局域网。通过既有脚本读取设备详情，验证当前连接：

```sh
Scripts/device-support.sh
Scripts/device-support.sh <真机设备ID>
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

包级测试由 `Package.swift` 的 Transport、Community、Schedule、Contracts、Score、Map、Sync 七个消费者 target 管理，代码位于 `ModuleTests/`，使用内存传输、文件服务、偏好和通知中心。覆盖社区身份与恢复隔离、日程保存排队、精确版本往返与过期比较令牌、文件损坏和账号切换、生产成绩服务注入、公共成绩存储端口、共享草稿图片准备和版本清理、同步冲突及地图身份规则。测试用内存文件服务集中于 `ModuleTests/Support`，直接依赖 StorageCore。学校课表解析沿用 `BIT101-iOSTests/Fixtures/schedule-service-response.json`。MapKit 页面、UIKit、Quick Look 和可信成绩单展示通过 App 宿主验证。

`FeatureCompositionTests` 在 App 宿主组合不同的环境依赖，验证课程、Gallery → Paper、Paper、Mine、Profile、Schedule 的构造归属，并验证同一宿主中 Paper / Gallery 依赖替换的场景重建。`MediaDependencyTests` 验证内存存储、静态 / GIF 解码和预览字节；`SuggestionDependencyTests` 验证草稿及提交归属；同文件的 `AppLocalDataOwnershipTests` 与 `SettingsDependencyOwnershipTests` 验证清理动作顺序、失败汇总、后端隔离和设置媒体 / 账号归属。`ExperimentalPreferenceCloudSyncTests` 使用独立通知中心和平台替身验证生命周期实例隔离及所选课程源向成绩场景传递。

按现有测试类或方法选择范围，多个筛选项在同一次调用执行。Swift Testing 方法名保留 `()`，suite 名称用于整组运行；脚本按实际用例数量验收选择范围：

```sh
Scripts/run-extended-tests.sh default \
  --only-testing ExperimentalPreferenceCloudSyncTests \
  --only-testing ScheduleModuleBoundaryTests \
  --only-testing NetworkClientTests
```

`modules`、`ui`、`catalyst` 支持 `--build-only` 编译测试产物。`--clean-build` 清理固定测试产物目录后执行所选流程。全量逻辑测试使用 `Scripts/run-extended-tests.sh`。

## UI 自动化

`BIT101-iOSUITests` 使用 `BIT101-iOS-UIAutomation` Release scheme 和真机宿主。`BIT101_UI_TESTING` 构建隔离 Keychain、偏好和账号缓存，使用合成会话及离线服务；正式 App 由生产组装入口启动。

UI 用例覆盖登录、账号切换、日程菜单、持久化、主 Tab、成绩短信挑战以及浅色、深色大字号。多项用例合并到同一串行 Runner 会话，结束后恢复常规 App：

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

稳定的 `accessibilityIdentifier` 用于字段、主 Tab 和编辑入口定位；失败的元素树和截图保存在既有 `.xcresult`。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/check-module-boundaries.py
```

统一入口汇总 SwiftSyntax 契约、UI 规则、客户端工程规范、模块依赖、文档链接、工程配置和锁定依赖检查。源码质量和语法检查覆盖 `ModuleTests/`。模块检查器自测导入解析、循环、依赖方向及全局资源访问约束，校验声明、实际导入、测试依赖以及 App 和扩展的直接产品依赖。规则按职责由对应检查器维护；设计系统的入口与规则见 [设计系统](DESIGN_SYSTEM.md)。

## 网络与 iCloud Smoke

网络 Smoke 使用正式 App 保存的会话、Cookie 与缓存，专用 Release 宿主完成探针后恢复常规 App：

```sh
Scripts/release-network-smoke-bit101.sh
Scripts/release-network-smoke-school.sh
BIT101_NETWORK_SMOKE_SCOPE=ddl Scripts/release-network-smoke.sh
```

可选范围为 `all`、`bit101`、`school`、`transcript`、`schedule` 和 `ddl`。报告分别记录服务健康、执行探针和覆盖完整度，部分覆盖返回状态码 2。学校短信 challenge 记录为认证受阻，短信输入由真机流程验证；反馈探针在同一请求内创建、读取并清理临时报告。

DDL 范围覆盖社区登录、课程中心原生认证、课程中心作业读取、乐学订阅发现和 ICS 下载。原生认证探针使用独立 Cookie 容器，携带学校 SSO 会话完成课程中心认证。报告的 `eclassDDL` 记录认证结果、课程数、活动类型、有效截止时间数量、近期与未来作业数量及作业截止字段缺失数量，同时记录账号滞留天数、窗口内作业数量、课程中心缓存数量和截止时间范围。

课程中心接口参考 [Android PR #24](https://github.com/BIT101-dev/BIT101-Android/pull/24) 与[全课程分页提案](https://github.com/Star2121-1/BIT101-Android/pull/1)。`ModuleTests/Transport/EclassDDLTests.swift` 覆盖分页、作业字段、时间格式、并发、原生会话恢复、取消及生产服务到持久化的完整链路；`ModuleTests/Schedule/EclassDDLSyncTests.swift` 覆盖完成状态、部分失败、账号状态和过期窗口；`ModuleTests/Sync/ScheduleSyncTests.swift` 验证学校正文与完成状态的云同步边界。

### 课程中心 DDL 验证记录

2026-10-01 的集成验证结果：

| 验证 | 结果与证据 |
| --- | --- |
| 包级测试 | 149 项通过；七个消费者 target 的完整执行记录见 `module-tests.log` |
| iPhone 常规行为 | 230 项通过，失败与跳过均为 0 |
| Catalyst 行为 | 238 项通过，失败与跳过均为 0；固定结果包成功保存 |
| iPhone DDL UI | 两项通过；验证双来源、详情、完成状态重启恢复和过期空列表提示 |
| 真机 DDL 网络 | 五项必需探针通过；原生认证在独立 Cookie 容器中完成 |
| 静态审计 | 语法、模块依赖、UI 规范、工程配置、文档及固定产物检查通过 |

真实课程中心探针读取 48 门课程、1 项作业和 1 个有效截止时间，账号缓存包含对应课程中心事件。该作业已超过账号当前 3 天滞留窗口，窗口内数量为 0；7 天窗口可显示此作业。空列表提示显示缓存数量与当前滞留天数，便于用户调整设置。真机网络报告保存具体截止时间与窗口计数。

模块测试使用受控响应验证未来作业经过生产服务、ViewModel、账号仓库、编码解码和重新加载后的显示与完成状态；真机 UI 使用隔离缓存验证实际交互。学校短信分支通过共享 challenge 和原生会话测试验证，真实网络探针采用 preflight 模式。

iCloud 双向验证要求 iPhone 与 Catalyst 使用同一 Apple ID 和 BIT101 账号，手机处于解锁状态并保存成绩缓存：

```sh
Scripts/run_icloud_cross_device_smoke.sh
Scripts/run_icloud_cross_device_smoke.sh --report
Scripts/run_icloud_cross_device_smoke.sh --cleanup
```

该专用流程通过 `ICLOUD_CROSS_DEVICE_SMOKE` 条件编译执行“真机 → Catalyst → 真机”，结束时恢复实验开关、协调数据和 Catalyst 本地登录状态。中断后的恢复使用既有 `--cleanup` 入口。

获得全量测试及网络、iCloud 授权后，通过 `Scripts/run-extended-tests.sh verify` 聚合验证；可选择分组，UI 筛选通过重复的 `--ui-test 测试类/方法` 参数合并到同一批次。

## 固定产物与 CI

| 类别 | 固定路径 |
| --- | --- |
| 测试构建、结果与日志 | `.build/extended-automation/`，结果包 `test-results.xcresult` |
| 测试指标 | `.build/extended-automation/test-metrics.txt` |
| 包级测试日志 | `.build/extended-automation/module-tests.log` |
| 设备截图 | `.build/screenshot.png` |
| 网络 Smoke | `.build/release-network-smoke/report/release-network-smoke.json` |
| iCloud Smoke | `.build/icloud-cross-device-smoke/` |

同类产物覆盖既有路径，文件名使用稳定类别名。脚本按输出规模显示终端结果或固定日志路径。
完整测试输出写入对应固定日志，终端显示汇总和失败摘要；模块日志保留 Swift Testing 的 suite、用例及参数执行记录。
测试入口通过 `.build/extended-automation.lock` 串行使用固定产物目录，聚合验证内的分组继承同一次执行锁。

GitHub Actions 的 `.github/workflows/ci.yml` 使用 `xcode-27` runner，执行静态审计与包级测试、Release 测试构建及 Catalyst 行为用例。App 依赖图同时编译 Watch 和两种 Widget，Swift / Clang 警告按错误处理。版本、plist 和 PR 基线在静态 job 校验，手动 `release_check` 校验公开版本。

本机承接真机行为、UI、网络和 iCloud 验证；发布操作按对应授权执行。
