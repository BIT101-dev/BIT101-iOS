# 自有 Cloudflare 资源

本目录维护 `aihelpme.dev` 下的资源。BIT101/101 域名由对应主体管理。

## 资源对应关系

| 域名 | 资源 | 项目名 | 本地源码 |
| --- | --- | --- | --- |
| `privacy.aihelpme.dev` | Pages | `privacy-policy` | `Cloudflare/PrivacyPolicy/` |
| `open.aihelpme.dev` | Worker | `bit101-open` | `Cloudflare/OpenWorker/` |
| `update.aihelpme.dev` | Worker + KV | `bit101-emergency-update` | `Cloudflare/EmergencyUpdateWorker/` |
| `feedback.aihelpme.dev` | Worker + KV + SQLite Durable Object | `bit101-error-reports` | `Cloudflare/ErrorReportWorker/` |

反馈域名提供 App 错误报告和用户建议 API。专用配置与使用方法见 [紧急更新](EmergencyUpdateWorker/README.md) 和 [反馈报告](ErrorReportWorker/README.md)。

## 链接契约

- 话廊分享：`https://open.aihelpme.dev/gallery/<id>`；课程分享：`https://open.aihelpme.dev/course/<id>`。
- App 的 `bit101://` 路由支持 `schedule/courses`、`gallery/<id>`、`course/<id>` 与 `paper/<id>`，由 `AppDeepLinkCoordinator` 解析，App 壳层在登录恢复后分发。
- 文章分享使用 `https://open.aihelpme.dev/paper/<id>`。OpenWorker 的网页路由覆盖 `gallery`、`course` 与 `paper`。
- 分享图标使用固定 `/share-icon.jpg` 路径，Worker 随部署导入主 App 的 PNG 图标资源；部署摘要同时绑定该资源。
- AASA 对应 `Y2T72736G3.BIT101-dev.BIT101-iOS`，关联 `gallery/*`、`course/*` 与 `paper/*`。响应与网页实现见 `OpenWorker/worker.js`。
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
python3 Scripts/validation_provenance.py deploy-worker OpenWorker

# 紧急更新
python3 Scripts/validation_provenance.py deploy-worker EmergencyUpdateWorker

# 反馈 API
python3 Scripts/validation_provenance.py deploy-worker ErrorReportWorker
```

部署前提交 Worker 代码、资产、Wrangler 配置及依赖锁。部署入口逐份比较工作树与提交内容，将源码提交标识写入版本消息。说明文档与紧急配置分别维护，紧急配置通过完整响应核对。网络 Smoke 核对活跃部署、全部流量版本及源码提交标识，结束时确认部署一致，并将部署信息保存到原始报告和发布摘要。

报告读取脚本复用同一 Wrangler 安装，入口为 `Scripts/fetch-issues-and-reports.sh`。本机默认认证目录 `~/.wrangler/config` 通过符号链接指向 `~/Library/Preferences/.wrangler/config`，共用一份凭据。
