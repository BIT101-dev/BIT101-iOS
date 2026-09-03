# 测试与持续集成

## 网络冒烟测试授权边界

未经用户明确指示，不得主动执行网络侧冒烟测试。构建、静态检查及不涉及网络的本地验证不属于此限制；是否执行仍按当前任务要求决定。

## 设备使用红线

**禁止启动、使用或创建任何 iOS / watchOS 模拟器。**

- 不得执行 `simctl boot`，不得选择 Simulator destination，也不得运行任何会隐式启动模拟器的自动化操作。
- 构建、测试、安装和运行验证只能使用当前已连接并受信任的真机。
- 没有可用真机时必须停止验证并明确说明，不能改用模拟器。
- 仅做编译检查时使用 generic device destination，执行前仍须确认命令不指向模拟器。
- 本约束同样适用于维护者、CI 脚本和自动化代理。

## 本地工具链

工程当前使用 Xcode 27 Beta。若它没有设为系统默认，所有命令显式指定开发者目录：

```sh
export DEVELOPER_DIR=/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer
xcodebuild -version
```

不必为了本仓库永久切换系统 `xcode-select`。执行任何构建或测试前，先确认 destination 是 generic device 或当前连接的真机。

## 编译测试包

```sh
xcodebuild build-for-testing \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Tests \
  -allowProvisioningUpdates
```

## 运行真机测试

连接并信任真机后，通过 `xcodebuild -showdestinations` 获取设备 ID：

```sh
DEVICE_ID='<xcode-device-id>'

xcodebuild test \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/Tests \
  -collect-test-diagnostics never \
  -allowProvisioningUpdates
```

2026-08-09 的历史基线为 **40 项测试全部通过，0 条编译警告/错误**；当前默认测试 Target 有 **95 项自动化用例**（89 项 Swift Testing、6 项 XCTest）。另有 5 项只在专用条件下运行的 smoke 用例。测试覆盖范围包括：

- 取消错误、页码分页、账号隔离 Codable 快照
- HTTP/社区请求构造和错误映射
- 登录启动状态、CAS HTML 解析、AES/MD5 兼容向量
- 成绩详细模式与排序
- 课程草稿/周次、空教室筛选和文案
- ICS 折行/转义/时区解析
- 课程列表与文章搜索 ViewModel 的成功、失败、取消和分页状态
- widget/watch 共享快照与时间线计算

## 真机验证

连接并信任设备后，先用 `xcodebuild -showdestinations` 获取 Xcode 设备 ID。工程已配置自动签名：

```sh
xcodebuild build \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination 'platform=iOS,id=<xcode-device-id>' \
  -derivedDataPath build/DeviceReview \
  -allowProvisioningUpdates
```

构建后可用 `xcrun devicectl device install app` 和 `device process launch` 安装、启动开发包。真机检查至少确认主 App 与 widget extension 没有启动即崩溃；涉及登录、学校接口、通知、Live Activity 或深链时，再按 `MODULE_PLAYBOOK.md` 完成人工交互回归。

也可以直接运行免参数的一键脚本：

```sh
Scripts/build-install-device.sh
```

脚本会自动寻找可用的 iPhone 真机；未连接或未信任时给出提示并退出。它只执行 Debug 构建、安装和启动，不执行 Archive。需要时也可传入设备 ID 和 Developer 目录。

### Watch 与 iOS 构建说明

1. 发布使用 Xcode Archive 或 `xcodebuild archive`。
2. Debug 装机使用具体 iPhone 设备 ID。
3. Watch 单独使用 watchOS scheme/destination 构建。
4. 不要用 generic iOS Debug 构建结果判断正式发布是否可行。

Xcode 27 beta 在 generic iOS Debug 构建中可能把嵌入的 Watch target 按 iOS SDK 处理，触发 Watch 图标或 watchOS API 报错；当前不需要修改 Watch 图标或 Watch 代码。

## CI 门禁

发布前网络冒烟按依赖边界提供两个入口：

- `Scripts/release-network-smoke-bit101.sh`：BIT101 自有 API、社区/学业只读接口、网页中转、远程配置，以及自有反馈 Worker 的临时写入/读取/删除；
- `Scripts/release-network-smoke-school.sh`：学校教学中心、WebVPN、乐学、课表、成绩及可信成绩单相关链路。

### 正式 App 网络冒烟说明

`release-network-smoke.sh` 使用 Debug 构建，不会把 smoke runner 和触发路由编译进 App Store Release；
它会先做一次本地构建检查，然后直接向
当前已安装并运行中的正式 App 发送 `bit101://network-smoke/<scope>?run=<uuid>`，
在同一进程内触发探针。BIT101 自有反馈 Worker 的测试数据会在同一请求内写入、读取并删除，
不会发送邮件或留下报告。这样可以复用正式 App 当前保存的登录态、Cookie 与缓存，
而不是测试 Host 的独立会话。

脚本会把结果写到应用组目录 `group.BIT101-dev.BIT101-iOS.shared/Library/NetworkSmoke/` 下的
`release-network-smoke.json`，再由命令行读取并判断是否通过；每次运行覆盖上一份结果。

默认直接运行对应入口即可，脚本会自动寻找可用的 iPhone 真机：

```sh
Scripts/release-network-smoke-bit101.sh
Scripts/release-network-smoke-school.sh
```

仍可传入设备 ID 和 Developer 目录覆盖自动发现结果。

可信成绩单仍然属于学校链路的一部分；当前冒烟只区分 `all`、`bit101` 和 `school`
三个范围，不再单独保留重新认证入口。

CI 或其它自动化同样不得启动、创建或使用模拟器。无法提供真机 destination 的环境只能做不依赖模拟器的静态检查；真机构建、测试、Widget 时间线和 Live Activity 时序按 `MODULE_PLAYBOOK.md` 人工验证。

CI 的版本门禁由 `Scripts/validate_versions.py` 提供，检查所有 Target/Configuration 的公开版本与 Build 是否一致、格式是否合法，以及相对 PR 基准是否倒退。在 GitHub Actions 手动运行 `iOS CI` 并打开 `release_check`，还会确认准备发布的公开版本高于 App Store 当前版本。

## iCloud 跨设备双向 Smoke

`BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift` 保留了“真机 → Mac Catalyst → 真机”的双向验证，但仅在显式加入 `ICLOUD_CROSS_DEVICE_SMOKE` 编译条件时存在：

- 不进入 App Target 或 Release 包；
- 默认构建和默认测试不会包含、发现或执行这些用例；
- 只能通过专用脚本运行，脚本不会选择或启动模拟器；
- 两端必须登录同一 Apple ID 和同一 BIT101 学号，真机需已解锁并保存过成绩缓存。

运行方式：

```sh
Scripts/run_icloud_cross_device_smoke.sh
```

脚本默认自动寻找可用的 iPhone 真机；也兼容显式传入设备 ID 和 Developer 目录。

测试会让手机临时切换“自动旋转”偏好并上传成绩缓存，Mac 收到后写回原值，最后由手机确认。正常完成或脚本异常退出时都会尝试恢复原设置、实验开关并清除协调数据；测试期间不要在两端手动修改相关设置。

## App Store 更新提醒真机测试

不修改工程版本号，也不使用模拟器。手机重新连接后，用命令行构建参数临时覆盖 Debug 包的公开版本，例如把本机伪装成 `1.7.0`：

```sh
DEVICE_ID='<xcode-device-id>'

xcodebuild build \
  -project BIT101-iOS.xcodeproj \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath build/UpdatePromptTest \
  -allowProvisioningUpdates \
  MARKETING_VERSION=1.7.0 \
  CURRENT_PROJECT_VERSION=9001
```

把 `build/UpdatePromptTest/Build/Products/Debug-iphoneos/BIT101-iOS.app` 安装到真机后，依次验证：

首次 smoke 可通过 `devicectl` 仅为该次 Debug 启动传入
`BIT101_UPDATE_PROMPT_SMOKE_RESET=1`，清除更新提醒自身的查询、忽略与展示门禁；该入口受
`#if DEBUG` 保护，不进入 Release 构建，也不会清除登录、课表或其它用户数据。

1. 首次启动显示“发现新版本 1.7.1”，正文与 App Store 的开发者更新内容一致，三个操作均可见。
2. 点击“前往 App Store”，确认打开 BIT101 的中国区 App Store 页面。
3. 点击“本次忽略”，弹窗应立即关闭；强制退出并重新启动后，24 小时内不得再次提醒，也不得产生第二次网络查询。
4. 点击“忽略此版本”，弹窗应立即关闭；超过 24 小时后 `1.7.1` 仍不应继续提醒，只有更高版本可以再次出现。
5. 卸载 Debug 包以清除其 `UserDefaults` 后重装，再断网启动；查询失败必须静默，不得阻塞登录或主界面。
6. 最后安装正常 `1.7.1` Debug 包；线上版本与本地相同时不得提醒。

自动化测试覆盖数字版本比较、24 小时查询节流、24 小时展示冷却、更新内容缓存、失败静默和“忽略此版本”。真机暂不连接时只进行 static/generic-device 编译验证，实际弹窗和 App Store 跳转留待真机恢复后执行。

## 学期滚动缓存与成绩自动刷新

- 课表自动同步按 3 月 1 日、9 月 1 日推导当前及下一学期，并保存两份转换后的完整快照（首周、课程、考试）。
- 学校返回的首周日期优先于日历分界；新学期快照尚无课程/考试时不得用空数据覆盖当前课表。
- 手动选择学期先更新当前学期；随后课表请求失败仍应保留该选择并显示错误，已有快照应继续展示，没有快照时不得展示旧学期课程。
- 冷启动只可从本地快照自动切换到已经开始的新学期，不得为切换而启动模拟器或依赖 UI 自动化。
- 手动周次浏览应可超过课程最后一周；冷启动、学期切换、同步和“回到本周”按首周日期定位时，结果应限制在第 -12 至 +20 周。
- 启动自动成绩查询仅在第 16 周结束后至下一学期首周之前启用，并按账号每天最多尝试一次；主动进入成绩页和下拉刷新不受此限制。
- 假期内不得自动同步 DDL 或预热空教室；学期开始后恢复。主动进入对应页面或手动刷新不受限制。
- 假期只检查下一学期课表：平时最多每 7 天一次，距新学期首周 14 天内最多每天一次；已经取得有效课表后，开学前不再重复获取。
- 真机 smoke 应检查相邻两个学期均已写入缓存、当前学期选择正确，且同一天重复启动不会再次查询成绩。

## 系统日历导入

- 只在真机的“我的－设置－课程表设置”中验证，不使用模拟器。
- 首次导入应请求完整日历权限，并创建“BIT101 课表”日历；课程日期、起止时间、地点应与当前学期一致。
- 同一学期连续导入两次，事件数量不得翻倍；第二次应替换带 `bit101://calendar-course/` 标记的旧事件。
- “删除已导入的日历事件”只能删除 BIT101 标记事件，不得影响用户自己创建的日程。
- 拒绝权限、无课表或没有已导入事件时应给出可理解的错误提示，不得崩溃。

## 成绩详细信息缓存

- 每次成绩刷新仍先获取简略列表；以除“序号、操作栏”外的简略字段进行无序比较。
- 新增、删除、分数或其它简略字段变化时必须重新获取详细信息。
- 简略列表未变化，且最新学期已知教学班状态全部为“是”时，直接复用详细缓存。
- 简略列表未变化但仍存在“否”时，详细查询按账号限制为 24 小时最多一次。
- 主动下拉刷新优先级最高，必须绕过详细缓存并完整查询简略与详细成绩。
## 错误报告

```sh
Scripts/check-error-report-coverage.sh
Scripts/error-reports.sh list
Scripts/error-reports.sh latest
Scripts/error-reports.sh delete '<report-key>'
Scripts/fetch-issues-and-reports.sh
Scripts/run-static-audit.sh
Scripts/run-extended-tests.sh
```

覆盖检查确保用户可见的错误弹窗和主要失败占位页保留 App Store 与错误报告入口。
报告直接通过当前 Wrangler 登录读取远端 KV，不需要额外管理网页。
最后一个脚本会用当前 GitHub CLI 和 Wrangler 登录状态，一次拉取未关闭的仓库 Issues 与 Cloudflare KV 报告，保存到 `.build/issue-report-inbox` 并输出简要汇总。错误报告按 `本次/上次/上上次` 保留三批；输出本次详情，只输出上两批数量。本次没有新报告时显示最近一批详情。完整拉取成功后只清理本次已拉取的 Cloudflare 报告，失败时保留远端数据。完整报告仅保存在本机，不会写回仓库。

`run-static-audit.sh` 只做静态检查，不连接学校接口，不运行网络 smoke，不执行 Archive。它按 Swift、Shell、Python、Worker、Git、文档、UI、触感、组件和源码质量规则输出结果；源码质量报告固定覆盖 `.build/code-quality-report.txt`。

## 扩展自动化测试

扩展测试使用 `EXTENDED_AUTOMATION` 条件编译，默认测试和 Release 包不会包含这些用例。运行：

```sh
Scripts/run-extended-tests.sh
```

脚本在真机上分组执行 27 项课程表策略、基础设施和登录状态测试；未连接真机时直接提示，不会改用模拟器。测试日志保存在 `.build/extended-automation`。
