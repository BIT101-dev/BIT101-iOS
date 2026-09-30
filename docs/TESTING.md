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

包级测试由 `Package.swift` 的 `BIT101ModulesTests` 管理，代码位于 `ModuleTests/`，使用内存传输、文件服务、偏好和通知中心。覆盖社区身份与恢复隔离、日程保存排队、文件损坏、账号切换、生产成绩服务注入和地图身份规则。学校课表解析沿用 `BIT101-iOSTests/Fixtures/schedule-service-response.json`。MapKit 页面、UIKit、Quick Look 和可信成绩单展示通过 App 宿主验证。

`FeatureCompositionTests` 在 App 宿主组合不同的环境依赖，验证课程入口的构造依赖。`ExperimentalPreferenceCloudSyncTests` 使用独立通知中心和平台替身验证生命周期实例隔离。

按现有测试类或方法选择范围，多个筛选项在同一次调用执行：

```sh
Scripts/run-extended-tests.sh default \
  --only-testing ExperimentalPreferenceCloudSyncTests \
  --only-testing ScheduleModuleBoundaryTests \
  --only-testing NetworkClientTests
```

`modules`、`ui`、`catalyst` 支持 `--build-only` 编译测试产物。全量逻辑测试使用 `Scripts/run-extended-tests.sh`。

## UI 自动化

`BIT101-iOSUITests` 使用 `BIT101-iOS-UIAutomation` Release scheme 和真机宿主。`BIT101_UI_TESTING` 构建隔离 Keychain、偏好和账号缓存，使用合成会话及离线服务；正式 App 由生产组装入口启动。

UI 用例覆盖登录、账号切换、日程菜单、持久化、主 Tab、成绩短信挑战以及浅色、深色大字号。多项用例合并到同一串行 Runner 会话，结束后恢复常规 App：

```sh
Scripts/run-extended-tests.sh ui
Scripts/run-extended-tests.sh ui <真机设备ID>
Scripts/run-extended-tests.sh ui \
  --only-testing LoginAndScheduleUITests/testLongPressOpensScheduleContextMenuAndImportSheet \
  --only-testing LoginAndScheduleUITests/testManualSchedulePersistsAcrossAppRelaunch
```

稳定的 `accessibilityIdentifier` 用于字段、主 Tab 和编辑入口定位；失败的元素树和截图保存在既有 `.xcresult`。

## 静态审计

```sh
Scripts/run-static-audit.sh
Scripts/check-module-boundaries.py
```

统一入口汇总 SwiftSyntax 契约、UI 规则、客户端工程规范、模块依赖、文档链接、工程配置和锁定依赖检查。源码质量和语法检查覆盖 `ModuleTests/`。模块检查器自测导入解析、循环与依赖方向，校验声明、实际导入、测试依赖以及 App 和扩展的直接产品依赖。规则按职责由对应检查器维护；设计系统的入口与规则见 [设计系统](DESIGN_SYSTEM.md)。

## 网络与 iCloud Smoke

网络 Smoke 使用正式 App 保存的会话、Cookie 与缓存，专用 Release 宿主完成探针后恢复常规 App：

```sh
Scripts/release-network-smoke-bit101.sh
Scripts/release-network-smoke-school.sh
BIT101_NETWORK_SMOKE_SCOPE=ddl Scripts/release-network-smoke.sh
```

可选范围为 `all`、`bit101`、`school`、`transcript`、`schedule` 和 `ddl`。报告分别记录服务健康、执行探针和覆盖完整度，部分覆盖返回状态码 2。学校短信 challenge 记录为认证受阻，短信输入由真机流程验证；反馈探针在同一请求内创建、读取并清理临时报告。

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

GitHub Actions 的 `.github/workflows/ci.yml` 使用 `xcode-27` runner，执行静态审计与包级测试、Release 测试构建及 Catalyst 行为用例。App 依赖图同时编译 Watch 和两种 Widget，Swift / Clang 警告按错误处理。版本、plist 和 PR 基线在静态 job 校验，手动 `release_check` 校验公开版本。

本机承接真机行为、UI、网络和 iCloud 验证；发布操作按对应授权执行。
