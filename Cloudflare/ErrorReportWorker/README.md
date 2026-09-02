# BIT101 错误报告 Worker

独立于 `open.aihelpme.dev` 的跳转 Worker。部署前请：

Worker 已绑定独立 KV 和 `feedback.aihelpme.dev`。更新部署：

```bash
cd Cloudflare/ErrorReportWorker
npx wrangler deploy
```

接口：`POST https://feedback.aihelpme.dev/api/error-reports`。

## 邮件提醒

Worker 收到新报告后会向已验证的维护者邮箱发送一封简短提醒，邮件只包含报告编号和接收时间，不包含报告正文。收件地址由 `wrangler.jsonc` 的 `REPORT_EMAIL` binding 固定；修改地址后需先在 Cloudflare Email Routing 中验证，再重新部署 Worker。

在仓库根目录快捷查看和管理报告：

```bash
Scripts/error-reports.sh list
Scripts/error-reports.sh latest
Scripts/error-reports.sh show <报告键>
Scripts/error-reports.sh delete <报告键>
```
