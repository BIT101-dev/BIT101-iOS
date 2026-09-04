# BIT101 错误报告 Worker

独立于 `open.aihelpme.dev` 的反馈 API Worker。这里没有网页页面，网页目录不应新增 `feedback/` 副本。部署前请：

Worker 已绑定独立 KV 和 `feedback.aihelpme.dev`。更新部署：

```bash
cd Cloudflare/EmergencyUpdateWorker
npx wrangler deploy --config ../ErrorReportWorker/wrangler.jsonc
```

接口：`POST https://feedback.aihelpme.dev/api/error-reports`。

网络冒烟会向同一接口发送 `mode: "network-smoke"` 的临时请求。Worker 会写入、读取并删除临时 KV 键，不发送邮件、不保留报告。

请求体上限为 16 MB。建议页最多上传 6 张图片，每张在 App 内以约 1 MB 为目标压缩，Worker 单张上限为 2 MB，再以 Base64 放入报告。Worker 会把建议与图片一起存入 KV。建议报告使用 `mode: "suggestion"`，与错误报告共用 KV，但拉取脚本会按“错误报告 / 用户建议”分目录保存，并将图片解码为独立文件。

## 邮件提醒

Worker 收到新报告后会向已验证的维护者邮箱发送一封简短提醒，邮件主题会区分“错误报告”和“用户建议”，只包含报告编号和接收时间，不包含报告正文。收件地址由 `wrangler.jsonc` 的 `REPORT_EMAIL` binding 固定；修改地址后需先在 Cloudflare Email Routing 中验证，再重新部署 Worker。

在仓库根目录快捷查看和管理报告：

```bash
Scripts/error-reports.sh list
Scripts/error-reports.sh latest
Scripts/error-reports.sh show <报告键>
Scripts/error-reports.sh delete <报告键>
```
