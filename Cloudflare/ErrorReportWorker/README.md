# BIT101 错误报告 Worker

独立于 `open.aihelpme.dev` 的跳转 Worker。部署前请：

Worker 已绑定独立 KV 和 `feedback.aihelpme.dev`。更新部署：

```bash
cd Cloudflare/ErrorReportWorker
npx wrangler deploy
```

接口：`POST https://feedback.aihelpme.dev/api/error-reports`。

在仓库根目录快捷查看和管理报告：

```bash
Scripts/error-reports.sh list
Scripts/error-reports.sh latest
Scripts/error-reports.sh show <报告键>
Scripts/error-reports.sh delete <报告键>
```
