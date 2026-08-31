# BIT101 紧急更新 Worker

接口只公开读取 `emergency-update` KV；写入操作仅通过已授权的本机 Wrangler 完成。

## 域名与维护边界

- iOS 项目维护者仅拥有并管理域名 `aihelpme.dev`。
- 所有 BIT101/101 相关域名（包括 `bit101.cn`）均不属于 iOS 项目维护者。
- iOS 项目维护者不是 BIT101 服务端维护者，不得将 BIT101/101 域名当作可配置资源。
- 本 Worker 及其网页、远程配置和跳转入口只能使用 `aihelpme.dev`，或用户另行明确确认归其所有的资源。

首次部署：

```sh
npm install
npx wrangler login
npx wrangler kv namespace create bit101-emergency-config \
  --binding EMERGENCY_CONFIG --update-config
npx wrangler deploy
```

发布提醒：

```sh
./Scripts/publish-emergency-update.sh 32 \
  '发现重要功能更新' \
  '此版本存在影响课表获取的问题，请尽快更新。'
```

关闭提醒：

```sh
./Scripts/disable-emergency-update.sh
```

配置不设过期时间；只要 `enabled` 为真且装机 Build 小于等于
`maximum_affected_build`，App 每天最多允许用户忽略到当天结束。
