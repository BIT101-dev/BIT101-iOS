# BIT101 错误报告 Worker

此 Worker 提供独立于 `open.aihelpme.dev` 的反馈 API；网页内容由对应网页 Worker 承载，仓库保留单一反馈 API 入口。

Worker 已绑定独立 KV 和 `feedback.aihelpme.dev`。部署前使用以下命令更新 Worker：

```bash
cd Cloudflare/EmergencyUpdateWorker
npx wrangler deploy --config ../ErrorReportWorker/wrangler.jsonc
```

Worker 提供 `POST https://feedback.aihelpme.dev/api/error-reports` 接口。

UTC 日配额由 SQLite Durable Object 在事务内预留，正式报告与网络探针分别保留每日 1000 次预算，每个来源在各自预算中每日最多提交 100 次。来源采用 Cloudflare `CF-Connecting-IP` 与 UTC 日期的 SHA-256 摘要，日计数更新时替换来源集合；共享出口的请求共用来源限额。报告正文继续存入 KV。部署配置同时登记配额 binding 与存储迁移。浏览器预检返回空响应体的 204 和接口 CORS 头。

请求体逐块读取，累计字节超过请求体上限时终止读取。报告类型、业务正文、附件和网络探针标记在配额预留前验证；有效报告进入持久化流程。

网络冒烟会向同一接口发送 `mode: "network-smoke"` 的临时请求。Worker 写入、读取并删除临时 KV 键，响应分别以 `temporaryRecordRemoved` 和 `quotaReserved` 标明清理结果与配额预留，邮件通知保持关闭。

请求体上限按六张最大附件的完整 Base64 长度，加上 1 MiB 报告元数据空间计算。建议页最多上传 6 张图片。App 内将每张图片以约 1 MB 为目标压缩，Worker 单张上限为 2 MB，并校验 Base64 字符、填充及末尾编码位，再将图片存入 KV。建议报告使用 `mode: "suggestion"`，与错误报告共用 KV。拉取脚本按“错误报告 / 用户建议”分目录保存，并将图片解码为独立文件。

客户端与 Worker 共用受保护字段清单，脱敏覆盖完整认证头、Cookie、JSON 字符串及键值文本。URL 参数按解码后的键名核对，嵌套登录链接沿解码后的 URL 继续处理，URL 账号密码统一遮盖，fragment 含受保护内容时整段遮盖；审计自测核对双方字段清单并注入编码参数、fragment、嵌套链接、转义字符串和多段认证值。

## 邮件提醒

Worker 收到新报告后会向已验证的维护者邮箱发送结构化提醒，邮件主题区分“错误报告”和“用户建议”，正文包含标题、用户补充、联系方式、版本、设备、系统、网络、诊断数量、状态码统计和最近失败请求；邮件保留报告编号与 KV 查看键，图片附件继续留在 KV 中。邮件正文使用 Worker 脱敏后的报告字段，避免发送完整原始响应和图片。收件地址由 `wrangler.jsonc` 的 `REPORT_EMAIL` binding 固定；修改地址后需先在 Cloudflare Email Routing 中验证，再重新部署 Worker。

在仓库根目录查看和管理报告；默认调用分页拉取开放 Issues、CI 失败与反馈，在固定收件箱累计保存正文与附件。同一报告键复用已有文件，缺失的本地正文通过再次拉取恢复；远端报告通过 `delete` 操作管理。报告操作共用收件箱锁。单份报告的终端输出展示正文、附件类型与字节数，图片由收件箱流程保存为独立文件：

```bash
Scripts/fetch-issues-and-reports.sh list
Scripts/fetch-issues-and-reports.sh latest
Scripts/fetch-issues-and-reports.sh show <报告键>
Scripts/fetch-issues-and-reports.sh delete <报告键>
```

诊断记录及附件元数据按各自结构验收，异常结构与序列化失败在配额及 KV 写入前返回 400。报告元数据预算独立于图片附件执行，超限返回 413。邮件通知异常独立记录，已保存报告返回提交成功；拉取脚本将历史异常 MIME 元数据的附件保留为二进制文件。

KV 列表索引按标题、版本和构建号的摘要长度约束在平台 1024 字节预算内，完整字段保留在正文。报告抓取在四个工作线程内完成下载、解析和落盘，任务结果返回报告键；正文内存随并发数保持有界，整批成功后提交暂存归档与已处理键。
