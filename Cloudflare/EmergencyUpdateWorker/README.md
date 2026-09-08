# BIT101 紧急更新 Worker

接口公开 `emergency-update` KV 的读取能力；写入操作通过已授权的本机 Wrangler 完成。

## 域名与维护边界

- iOS 项目维护者负责域名 `aihelpme.dev` 的管理。
- BIT101/101 相关域名（包括 `bit101.cn`）归属 BIT101 服务体系。
- BIT101 服务端由独立维护团队负责；iOS 项目配置保留 `aihelpme.dev` 资源边界。
- 本 Worker 及其网页、远程配置和跳转入口使用 `aihelpme.dev` 资源，以及用户明确确认归属的其他资源。

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

配置不设过期时间。只要 `enabled` 为真且装机 Build 小于等于
`maximum_affected_build`，App 每天最多允许用户忽略提醒到当天结束。
