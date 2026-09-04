# 自有 Cloudflare 资源

本目录只维护 iOS 项目维护者拥有的 `aihelpme.dev` 资源。BIT101/101 相关域名不在可管理范围内。

`feedback.aihelpme.dev` 没有独立网页，只有接收 App 错误报告和用户建议的 Worker API；后端源码在
`Cloudflare/ErrorReportWorker/worker.js`，App 内提交界面在
`BIT101-iOS/Shared/Infrastructure/ErrorReportSupport.swift` 与
`BIT101-iOS/Settings/SettingsRootView.swift`。

报告读取脚本复用 `EmergencyUpdateWorker/node_modules` 中已安装的 Wrangler，避免每次在
`ErrorReportWorker` 目录重新下载 Wrangler。

## 资源对应关系

| 域名 | Cloudflare 资源 | 远端项目名 | 本地源码 |
| --- | --- | --- | --- |
| `privacy.aihelpme.dev` | Pages | `privacy-policy` | `Cloudflare/PrivacyPolicy/` |
| `open.aihelpme.dev` | Worker | `bit101-open` | `Cloudflare/OpenWorker/` |
| `update.aihelpme.dev` | Worker + KV | `bit101-emergency-update` | `Cloudflare/EmergencyUpdateWorker/` |
| `feedback.aihelpme.dev` | Worker + KV | `bit101-error-reports` | `Cloudflare/ErrorReportWorker/` |

2026-08-31 已通过 Wrangler 确认：当前 OAuth 登录可以读取并部署 `privacy-policy` Pages 项目和
`bit101-open` Worker，并具有 Pages、Workers、KV 与 Worker Routes 写入权限。因此在授权未过期
或未被撤销时，可以从此电脑部署四项资源，无需每次进入 Cloudflare 网页。

## 部署

仓库当前使用 `Cloudflare/EmergencyUpdateWorker` 中安装的 Wrangler：

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

以上命令都会直接修改线上资源，只有在用户明确要求部署时才能执行。若 Wrangler 授权过期、被撤销
或 Cloudflare 账号发生变化，仍需重新执行 `npx wrangler login`。

## 最近部署验证

2026-08-31 已从本仓库完成一次命令行部署并验证：

- `privacy-policy` Pages 成功生成新的生产部署，`privacy.aihelpme.dev` 正常显示隐私政策及更新日期；
- `bit101-open` Worker 成功部署到 `open.aihelpme.dev`，AASA JSON 与课程中转页均正常；
- `update.aihelpme.dev` 的临时 `Build ≤ 1000` 测试提醒已关闭，接口返回禁用状态。

## 目录约定

每个自有域名的部署配置和源码都放在 `Cloudflare/` 下的一个项目目录中：

- `PrivacyPolicy/`：隐私政策 Pages。
- `OpenWorker/`：Universal Link 跳转 Worker。
- `EmergencyUpdateWorker/`：紧急更新 Worker。
- `ErrorReportWorker/`：反馈 API Worker。

不再使用顶层 `web/` 目录，也不为反馈 API 新建网页副本。
