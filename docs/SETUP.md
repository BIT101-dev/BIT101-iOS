# 新电脑开发环境

这份文档说明 macOS 新电脑所需的外部工具、账号配置，以及从拉取代码到构建和装机的流程。命令默认在仓库根目录执行。

## 工具清单

| 工具 | 使用范围 | 安装方式 |
| --- | --- | --- |
| Xcode 27.x | App、Widget、Watch、Mac Catalyst 编译，真机安装与调试 | [Apple 官方下载](https://developer.apple.com/download/all/?q=Xcode)；完成首次启动的许可与组件安装 |
| Git | 克隆、拉取和提交 | Xcode 开发工具附带 |
| Homebrew | 管理 Python 和维护工具 | [官方安装说明](https://docs.brew.sh/Installation) |
| Python 3.11 或以上 | 构建锁、日志、设备选择、文档及工程检查 | `brew install python` |
| Node.js、npm、npx | Worker 本地依赖、静态审计中的 JavaScript 检查、反馈报告工具 | `brew install node`；仓库锁定依赖要求 Node.js 22 或以上 |
| Wrangler、Miniflare | Cloudflare 报告访问与 Worker 本地验证 | 在 `Cloudflare/EmergencyUpdateWorker` 执行 `npm ci` |
| GitHub CLI（`gh`） | Issues、GitHub Actions 失败记录和反馈汇总 | `brew install gh` |
| ripgrep（`rg`） | 源码和文件检索 | `brew install ripgrep` |
| openpyxl | 从教务 Excel 生成校园地图 fixture | 安装到 Homebrew Python，见下文 |

App 的基础构建依赖 Xcode、Git 和 Python。Node.js 工具链用于完整维护流程，`gh` 用于 GitHub 信息读取，`openpyxl` 用于地图数据整理，`rg` 用于开发检索。

Swift、Swift Package Manager、Clang、CoreDevice 和 SDK 由 Xcode 提供；Shell、Ruby、curl、plutil、codesign、ditto 和 open 由 macOS 提供。App 模块定义在根目录 `Package.swift`，由 Xcode 自动解析本地依赖。Worker 的包版本由 `Cloudflare/EmergencyUpdateWorker/package-lock.json` 管理。

## 安装与拉取

### 1. 准备 Xcode

安装 Xcode 27.x，将应用放在 `/Applications/Xcode.app`，完成首次启动的许可和组件准备。平台资源选择 iOS、watchOS 和 macOS 构建 SDK 与真机支持。macOS 版本按 [Apple 的 Xcode 系统要求](https://developer.apple.com/xcode/system-requirements/)选择。

在终端指定完整开发者目录：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

该变量在当前终端会话生效。长期使用时将这行配置写入现有 `~/.zprofile`，重新打开终端。Xcode 安装位置变化时，将路径替换为实际应用内的 `Contents/Developer`。

构建、装机和设备查询均通过项目脚本执行，脚本使用同一份 `DEVELOPER_DIR` 配置。

### 2. 准备命令行工具

按 [Homebrew 官方说明](https://docs.brew.sh/Installation)安装，并完成安装器提示的 `brew shellenv` 配置。Apple Silicon 的默认安装目录为 `/opt/homebrew`，Intel Mac 为 `/usr/local`。

基础构建环境：

```sh
brew install python
export PATH="$(brew --prefix)/opt/python@3/libexec/bin:$PATH"
git --version
python3 --version
```

完整维护工具：

```sh
brew install node gh ripgrep ruff
node --version
npm --version
gh --version
rg --version
ruff --version
```

将上述 Python PATH 配置加入 shell 启动配置，终端使用 Homebrew Python。构建、测试脚本与提交钩子也通过公共入口优先选择该解释器。

### 3. 克隆或更新仓库

首次克隆：

```sh
git clone https://github.com/BIT101-dev/BIT101-iOS.git
cd BIT101-iOS
git config core.hooksPath .githooks
git config user.name "你的提交姓名"
git config user.email "你的提交邮箱"
```

将提交姓名和邮箱替换为自己的 Git 身份；这些配置保存在当前仓库。

已有工作目录：

```sh
git pull --ff-only
```

本地改动涉及远端更新的文件时，先提交或暂存这些改动，再拉取并恢复。提交钩子校验暂存内容的文件行数和文档引用。

### 4. 安装维护依赖

Wrangler 与 Miniflare 共用仓库内的安装位置：

```sh
(cd Cloudflare/EmergencyUpdateWorker && npm ci)
(cd Cloudflare/EmergencyUpdateWorker && npx --no-install wrangler --version)
```

`npm ci` 按锁文件安装，生成的 `node_modules/` 进入 Git 忽略范围。Wrangler 的 Node.js 支持范围见 [Cloudflare 官方说明](https://developers.cloudflare.com/workers/wrangler/install-and-update/)。

需要生成地图 fixture 时安装 Excel 解析包：

```sh
python3 -m pip install --break-system-packages openpyxl
```

这里使用 Homebrew Python 的既有环境。地图数据准备沿用 `Scripts/generate_campus_map_fixture.py` 和现有人工审核流程，命令说明见 [构建与测试](TESTING.md)。

## 编译与运行

### 真机暂时离线

编译 iOS Release App、Watch 和组件：

```sh
Scripts/build-install-device.sh build
```

这个入口使用 iOS SDK 的通用 Release 目的地，并关闭代码签名，适合验证新电脑的编译环境。构建产物与日志固定保存在 `build/DeviceInstall/`。

完成签名配置后，在当前 Mac 构建、安装并启动 Catalyst：

```sh
Scripts/build-install-device.sh mac
```

安装路径为 `~/Applications/BIT101-iOS.app`。Mac 启动验证覆盖 Catalyst 宿主；iPhone、Widget、Watch、设备权限及跨设备行为由真机验收流程覆盖。

### 真机可用

在 Xcode 账号设置中登录具有项目签名权限的 Apple 账号，并准备证书和描述文件。工程使用自动签名，App 与扩展的团队为 `Y2T72736G3`；账号需具有对应团队和能力的访问权限。

签名涉及的项目资源：

- App、Widget、Watch App 和 Watch Widget 的 Bundle ID。
- App Group：`group.BIT101-dev.BIT101-iOS.shared`。
- CloudKit 容器：`iCloud.BIT101-dev.BIT101-iOS`。
- iCloud Key-Value Store 与 Associated Domains：`applinks:open.aihelpme.dev`。

证书、私钥、描述文件和账号登录状态在新电脑上单独准备。Catalyst 安装同样使用自动签名和工程能力：在 Apple 开发者账号的 Devices 中登记当前 Mac，并准备覆盖该设备且包含 Associated Domains、App Group 和 iCloud 权限的 Mac Catalyst 描述文件。

连接 iPhone，完成信任、Xcode 配对和开发者模式授权；运行时保持设备解锁。无线使用时，Mac 与 iPhone 连接同一局域网。工程最低部署版本为 iOS 17、watchOS 10。

```sh
Scripts/build-install-device.sh info
Scripts/build-install-device.sh
```

默认入口自动优先选择 USB 设备，其次选择可发现的无线设备，完成 Release 编译、安装和启动。

## 维护账号与专项流程

读取 GitHub 信息时，按 [GitHub CLI 登录说明](https://cli.github.com/manual/gh_auth_login)完成认证：

```sh
gh auth login
```

访问自有 Cloudflare 反馈报告时，在共用工具目录登录具有对应账号与 KV 权限的账号：

```sh
(cd Cloudflare/EmergencyUpdateWorker && npx --no-install wrangler login)
```

GitHub、Cloudflare 和 Apple 签名分别使用各自的授权，账号凭据保存在受信开发或真机宿主。日常 CI 执行静态审计，托管任务使用 `xcode-27` 镜像，各 Job 在所属工作区复用固定编译缓存和增量产物。手动全量和发布流程执行编译、完整模拟器行为与 UI 测试，真机发布宿主使用 `bit101-xcode-27` 与 `bit101-device` 标签。角色、标签与验收流程见 [构建与测试](TESTING.md)。

测试、静态审计、网络 Smoke 和 iCloud Smoke 按用户明确指定的范围执行；分组、入口和固定产物见 [构建与测试](TESTING.md)。iCloud 双向验证使用同一 Apple ID 的 iPhone 与 Catalyst。线上资源部署按对应授权和 [Cloudflare 资源文档](../Cloudflare/README.md)执行。

## 常见环境问题

| 现象 | 处理 |
| --- | --- |
| 提示 active developer directory 为 `/Library/Developer/CommandLineTools` | 在当前终端设置 `DEVELOPER_DIR` 为完整 Xcode 的 `Contents/Developer` |
| 提示 Xcode 许可或组件准备 | 完成 Xcode 首次启动的许可与组件安装，再执行原脚本 |
| 签名证书、描述文件或团队权限错误 | 核对 Xcode Apple 账号、签名团队以及 App 和扩展所需能力 |
| Catalyst 提示 Mac 需要注册，或描述文件缺少 Associated Domains | 在开发者账号登记 Mac，核对 App ID 能力并更新 Mac Catalyst 描述文件 |
| 提示设备离线 | 连接并解锁真机，完成配对；设备准备期间使用 `build` 验证 Release 编译 |
| Wrangler 可执行文件或依赖缺失 | 在 `Cloudflare/EmergencyUpdateWorker` 重新执行 `npm ci` |
| Wrangler 或 `gh` 授权失效 | 使用对应登录命令更新本机认证 |
| 地图生成提示 openpyxl | 使用上文的 Homebrew Python 安装命令准备 Excel 解析包 |

构建失败时查看固定日志 `build/DeviceInstall/build.log`，按诊断修复后重跑相同入口。
