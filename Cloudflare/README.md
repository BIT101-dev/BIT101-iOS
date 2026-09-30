# 自有 Cloudflare 资源

本目录维护 `aihelpme.dev` 下的资源。BIT101/101 域名由对应主体管理。

## 资源对应关系

| 域名 | 资源 | 项目名 | 本地源码 |
| --- | --- | --- | --- |
| `privacy.aihelpme.dev` | Pages | `privacy-policy` | `Cloudflare/PrivacyPolicy/` |
| `open.aihelpme.dev` | Worker | `bit101-open` | `Cloudflare/OpenWorker/` |
| `update.aihelpme.dev` | Worker + KV | `bit101-emergency-update` | `Cloudflare/EmergencyUpdateWorker/` |
| `feedback.aihelpme.dev` | Worker + KV | `bit101-error-reports` | `Cloudflare/ErrorReportWorker/` |

反馈域名提供 App 错误报告和用户建议 API。专用配置与使用方法见 [紧急更新](EmergencyUpdateWorker/README.md) 和 [反馈报告](ErrorReportWorker/README.md)。

## 链接契约

- 话廊分享：`https://open.aihelpme.dev/gallery/<id>`；课程分享：`https://open.aihelpme.dev/course/<id>`。
- App 的 `bit101://` 路由支持 `schedule/courses`、`gallery/<id>`、`course/<id>` 与 `paper/<id>`，由 `AppDeepLinkCoordinator` 解析，App 壳层在登录恢复后分发。
- 文章分享使用 `https://open.aihelpme.dev/paper/<id>`。OpenWorker 的网页路由覆盖 `gallery` 和 `course`；文章网页落地规则由部署配置管理。
- AASA 对应 `Y2T72736G3.BIT101-dev.BIT101-iOS`，关联 `gallery/*` 和 `course/*`。具体响应与网页内容以 `OpenWorker/worker.js` 为准。
- `/.well-known/apple-app-site-association` 直接返回 HTTP 200 和 `application/json`。App ID 开启 Associated Domains，签名描述文件包含对应权限。
- 配置部署后重新安装 App，从信息或备忘录等外部 App 点击链接验证。Apple CDN 的缓存影响配置生效时间。
- 中转页保留关联域名并提供 Scheme 与网页入口，供内置浏览器等场景选择打开方式。

## 部署

命令修改线上资源，按用户明确的部署要求执行。仓库共用 `Cloudflare/EmergencyUpdateWorker` 中安装的 Wrangler；授权失效或账号变化时执行 `npx wrangler login`。

```sh
# 隐私政策 Pages
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler pages deploy ../PrivacyPolicy --project-name privacy-policy --branch main)

# Universal Link 与网页中转
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler deploy --config ../OpenWorker/wrangler.jsonc)

# 紧急更新
(cd Cloudflare/EmergencyUpdateWorker && npx wrangler deploy)

# 反馈 API
(cd Cloudflare/EmergencyUpdateWorker && \
  npx wrangler deploy --config ../ErrorReportWorker/wrangler.jsonc)
```

报告读取脚本复用同一 Wrangler 安装，入口为 `Scripts/fetch-issues-and-reports.sh`。
