# 自有 Cloudflare 资源

本目录的管理对象为 iOS 项目维护者拥有的 `aihelpme.dev` 资源。BIT101/101 相关域名的管理范围独立于本目录。

`feedback.aihelpme.dev` 的资源类型为 Worker API，接口功能为接收 App 错误报告和用户建议；独立网页入口状态为空。后端源码位于
`Cloudflare/ErrorReportWorker/worker.js`，App 内提交界面位于
`BIT101-iOS/Shared/Infrastructure/ErrorReportSupport.swift` 与
`BIT101-iOS/Settings/SettingsRootView.swift`。

报告读取脚本调用 `EmergencyUpdateWorker/node_modules` 中已安装的 Wrangler；`ErrorReportWorker` 目录的每次执行沿用该安装。

## 资源对应关系

| 域名 | Cloudflare 资源 | 远端项目名 | 本地源码 |
| --- | --- | --- | --- |
| `privacy.aihelpme.dev` | Pages | `privacy-policy` | `Cloudflare/PrivacyPolicy/` |
| `open.aihelpme.dev` | Worker | `bit101-open` | `Cloudflare/OpenWorker/` |
| `update.aihelpme.dev` | Worker + KV | `bit101-emergency-update` | `Cloudflare/EmergencyUpdateWorker/` |
| `feedback.aihelpme.dev` | Worker + KV | `bit101-error-reports` | `Cloudflare/ErrorReportWorker/` |

2026-08-31，Wrangler OAuth 登录状态确认可读取并部署 `privacy-policy` Pages 项目和
`bit101-open` Worker；当前登录状态具有 Pages、Workers、KV 与 Worker Routes 写入权限。授权保持有效且未被撤销、
Cloudflare 账号保持一致时，此电脑通过 Wrangler 部署四项资源，部署入口采用命令行。

## 部署

仓库调用 `Cloudflare/EmergencyUpdateWorker` 中安装的 Wrangler：

```sh
# 隐私政策 Pages
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler pages deploy ../PrivacyPolicy --project-name privacy-policy --branch main)

# Universal Link 与网页跳转 Worker
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler deploy --config ../OpenWorker/wrangler.jsonc)

# 紧急更新 Worker
(cd Cloudflare/EmergencyUpdateWorker && npx wrangler deploy)

# 用户主动提交的错误报告 Worker
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler deploy --config ../ErrorReportWorker/wrangler.jsonc)
```

以上命令直接修改线上资源。部署动作的触发条件为用户明确要求部署。Wrangler 授权处于有效状态且
Cloudflare 账号保持一致时，命令可直接运行；授权过期、授权撤销或 Cloudflare 账号变化时，先执行
`npx wrangler login`。

## 部署验证记录

2026-08-31 已从本仓库完成一次命令行部署并验证：

- `privacy-policy` Pages 成功生成新的生产部署，`privacy.aihelpme.dev` 正常显示隐私政策及更新日期；
- `bit101-open` Worker 成功部署到 `open.aihelpme.dev`，AASA JSON 与课程中转页均正常；
- `update.aihelpme.dev` 的临时 `Build ≤ 1000` 测试提醒已关闭，接口返回禁用状态。

## 目录约定

每个自有域名对应的部署配置和源码位于 `Cloudflare/` 下的独立项目目录：

- `PrivacyPolicy/`：隐私政策 Pages。
- `OpenWorker/`：Universal Link 跳转 Worker。
- `EmergencyUpdateWorker/`：紧急更新 Worker。
- `ErrorReportWorker/`：反馈 API Worker。

顶层 `web/` 目录状态为停用；反馈 API 项目的网页副本创建策略为关闭。
