import { DurableObject } from "cloudflare:workers";

const MAX_ATTACHMENTS = 6;
const MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024;
const MAX_REPORT_METADATA_BYTES = 1024 * 1024;
const MAX_BODY_BYTES = MAX_ATTACHMENTS * 4 * Math.ceil(MAX_ATTACHMENT_BYTES / 3) + MAX_REPORT_METADATA_BYTES;
const MAX_REPORTS_PER_DAY = 1000;
const REPORT_RETENTION_SECONDS = 30 * 24 * 60 * 60;
const MAX_REPORTS_PER_SOURCE_PER_DAY = 100;
const MAX_EMAIL_RETRY_DELAY_MS = 60 * 60 * 1000;

async function readReportBody(request) {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const parts = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return null;
      }
      parts.push(decoder.decode(value, { stream: true }));
    }
    parts.push(decoder.decode());
    return parts.join("");
  } finally { reader.releaseLock(); }
}

function validReport(report, request) {
  if (!report || typeof report !== "object" || Array.isArray(report)) return false;
  for (const key of ["appVersion", "build", "deviceModel", "systemVersion", "networkStatus", "contact"]) {
    if (report[key] != null && typeof report[key] !== "string") return false;
  }
  if (report.diagnostics != null && (!Array.isArray(report.diagnostics)
    || report.diagnostics.some(record => !record || typeof record !== "object" || Array.isArray(record)))) return false;
  if (report.mode === "network-smoke") {
    return request.headers.get("x-bit101-network-smoke") === "1"
      && typeof report.runID === "string" && /^[a-zA-Z0-9-]{1,128}$/.test(report.runID);
  }
  if (report.mode === "suggestion") {
    return typeof report.comment === "string" && report.comment.trim().length > 0;
  }
  return ["sanitized", "raw"].includes(report.mode)
    && typeof report.errorTitle === "string" && report.errorTitle.trim().length > 0
    && typeof report.errorMessage === "string" && report.errorMessage.trim().length > 0;
}

const PROTECTED_NAMES = ["password", "passwd", "pwd", "cookie", "set-cookie", "authorization", "proxy-authorization", "token",
  "access_token", "refresh_token", "challenge_token", "fake-cookie", "accessToken", "refreshToken", "challengeToken", "fakeCookie",
  "session", "sessionID", "session_id", "sessionid", "ticket", "api-key", "api_key", "apikey", "client_secret", "secret", "captcha",
  "captcha_payload", "croypto", "execution", "salt"];
const SECRET_NAMES = PROTECTED_NAMES.map(value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
const SECRET_KEYS = new RegExp(SECRET_NAMES, "i");
const SECRET_HEADERS = /((?:authorization|proxy-authorization|cookie|set-cookie)\s*[=:]\s*)[^&\r\n]+/gi;
const SECRET_JSON = new RegExp(`("[^"]*(?:${SECRET_NAMES})[^"]*"\\s*:\\s*")(?:\\\\.|[^"\\\\])*(")`, "gi");
const SECRET_TEXT = new RegExp("(\\b[\\w$-]*(?:" + SECRET_NAMES + ")[\\w$-]*(?:[\"']\\]?)?\\s*[=:]\\s*)(?:\"(?:\\\\.|[^\"\\\\])*(?:\"|$)|'(?:\\\\.|[^'\\\\])*(?:'|$)|[^&\\r\\n,;]+)", "gi");

function redactHTML(value) {
  return value.replace(/<(?:input|meta)\b(?:[^>"']|"[^"]*(?:"|$)|'[^']*(?:'|$))*(?:>|$)|<(?:textarea|span)\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?(?:<\/(?:textarea|span)\s*>|$)/gi, tag => {
    const fields = [...tag.matchAll(/\b(?:id|name|type|property|http-equiv)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi)]
      .map(match => decodedHTMLAttribute(match[1] ?? match[2] ?? match[3]));
    if (!fields.some(field => SECRET_KEYS.test(field) || /^(?:login-page-flowkey|login-croypto)$/i.test(field))) return tag;
    const masked = tag.replace(/(\b(?:value|content)\s*=\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s"'=<>`]+)/gi, '$1"[REDACTED]"');
    return /^<(?:textarea|span)\b/i.test(tag) ? masked.replace(/(>)[\s\S]*(<\/(?:textarea|span)\s*>|$)/gi, "$1[REDACTED]$2") : masked;
  });
}

function decodedHTMLAttribute(value) {
  const named = { lowbar: "_", UnderBar: "_", hyphen: "-", amp: "&" };
  return value.replace(/&#(?:[xX]([0-9a-fA-F]+)|([0-9]+));?/g, (match, hex, decimal) => {
    const number = parseInt(hex ?? decimal, hex ? 16 : 10);
    return number <= 0x10FFFF && !(number >= 0xD800 && number <= 0xDFFF) ? String.fromCodePoint(number) : match;
  }).replace(/&(lowbar|UnderBar|hyphen|amp);/g, (_, name) => named[name]);
}

function decodedPercent(value) {
  while (true) {
    try { const decoded = decodeURIComponent(value); if (decoded === value) return value; value = decoded; }
    catch { return value; }
  }
}

function redactURLs(value) {
  return value.replace(/https?:\/\/[^\s<>"']+/gi, text => {
    try {
      const url = new URL(text);
      if (url.username || url.password) { url.username = "[REDACTED]"; url.password = ""; }
      if (url.hash && (SECRET_KEYS.test(decodedPercent(url.hash))
        || [...new URLSearchParams(url.hash.slice(1)).keys()].some(name => SECRET_KEYS.test(decodedPercent(name))))) {
        url.hash = "[REDACTED]";
      }
      const query = [...url.searchParams].map(([name, item]) => [name, SECRET_KEYS.test(decodedPercent(name))
        ? "[REDACTED]" : /https?:\/\//i.test(decodedPercent(item)) ? redactURLs(decodedPercent(item)) : item]);
      if (query.length) { url.search = ""; for (const [name, item] of query) url.searchParams.append(name, item); }
      return url.toString();
    } catch { return "[REDACTED]"; }
  });
}

function redactString(value) {
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") value = JSON.stringify(forceRedact(parsed));
  } catch {
    // 截断 JSON 的凭据范围按完整响应遮盖。
    if (/^\s*[\[{]/.test(value)) value = "[REDACTED]";
  }
  return redactHTML(redactURLs(value))
    .replace(SECRET_HEADERS, "$1[REDACTED]")
    .replace(SECRET_JSON, "$1[REDACTED]$2")
    .replace(SECRET_TEXT, "$1[REDACTED]");
}

function forceRedact(value) {
  if (Array.isArray(value)) return value.map(forceRedact);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      key,
      SECRET_KEYS.test(key) ? "[REDACTED]" : forceRedact(item)
    ]));
  }
  return typeof value === "string" ? redactString(value) : value;
}

function json(data, status = 200) {
  const options = {
    status, headers: {
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS"
    }
  };
  return status === 204 ? new Response(null, options) : Response.json(data, options);
}

export class ReportQuota extends DurableObject {
  async fetch(request) {
    const { source, smoke, admission } = await request.json();
    let sourceLimit = smoke ? MAX_REPORTS_PER_SOURCE_PER_DAY
      : Number(this.env?.REPORT_SOURCE_DAILY_LIMIT ?? MAX_REPORTS_PER_SOURCE_PER_DAY);
    if (!Number.isSafeInteger(sourceLimit) || sourceLimit < 1 || sourceLimit > MAX_REPORTS_PER_DAY) {
      return Response.json({ allowed: false, error: "invalid_source_quota" }, { status: 503 });
    }
    if (admission) sourceLimit = 2 * Math.max(sourceLimit, MAX_REPORTS_PER_SOURCE_PER_DAY);
    const key = admission ? "admission" : smoke ? "smoke" : "daily";
    const day = new Date().toISOString().slice(0, 10);
    const result = this.ctx.storage.transactionSync(() => {
      const previous = this.ctx.storage.kv.get(key);
      const current = previous?.day === day ? previous : { day, count: 0 };
      if (current.count >= MAX_REPORTS_PER_DAY * (admission ? 2 : 1)) return { allowed: false, error: "daily_limit_reached" };
      const sources = current.sources ?? {};
      const count = sources[source] ?? 0;
      if (count >= sourceLimit) return { allowed: false, error: "source_limit_reached" };
      sources[source] = count + 1;
      this.ctx.storage.kv.put(key, { day, count: current.count + 1, sources });
      return { allowed: true };
    });
    return Response.json(result);
  }
}

function emailText(value, limit = 1200) {
  const text = value == null ? "" : (typeof value === "object" ? JSON.stringify(value) : String(value)).trim();
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}…`;
}

function emailLine(value) {
  return emailText(value).replace(/[\r\n]+/g, " ");
}

function listText(value, limit) {
  return typeof value === "string" || typeof value === "number" ? emailText(value, limit) : "";
}

function reportEmailSubject(category, report) {
  const title = emailLine(report.errorTitle || report.comment || "新报告");
  const version = emailLine(report.appVersion || "未知版本");
  const build = emailLine(report.build || "?");
  return `BIT101 ${category} · ${title} · ${version} (${build})`.slice(0, 180);
}

function reportEmailBody(id, receivedAt, report) {
  const context = report.context || {};
  const summary = report.diagnosticSummary || {};
  const diagnostics = Array.isArray(report.diagnostics) ? report.diagnostics : [];
  const lines = [
    `报告编号：${id}`,
    `接收时间：${receivedAt}`,
    `类型：${report.mode === "suggestion" ? "用户建议" : "错误报告"}`,
    `构建：${report.isDevelopmentBuild ? "开发版" : "正式版"} ${emailLine(report.appVersion || "?")} (${emailLine(report.build || "?")})`,
    `设备：${emailLine(report.deviceModel || "?")}`,
    `系统：${emailLine(report.systemVersion || "?")}`,
    `语言环境：${emailLine(context.locale || "?")}`,
    `时区：${emailLine(context.timeZone || "?")}`,
    `界面：${emailLine(context.interfaceStyle || "?")} · 方向：${emailLine(context.orientation || "?")}`,
    `网络：${emailLine(context.networkStatus || report.networkStatus || "?")}`,
    "",
    `标题：${emailText(report.errorTitle || "")}`,
    `消息：${emailText(report.errorMessage || "")}`
  ];

  if (report.comment) {
    lines.push("", "用户补充：", emailText(report.comment, 2400));
  }
  if (report.contact) lines.push("", `联系方式：${emailText(report.contact, 500)}`);

  lines.push(
    "",
    `诊断记录：${emailLine(summary.total ?? diagnostics.length)} 条，失败 ${emailLine(summary.failed ?? 0)} 条`,
    `状态码统计：${Object.entries(summary.statusCodes || {}).map(([code, count]) => `${code}×${emailLine(count)}`).join("、") || "暂无"}`
  );
  if (summary.latestFailure) lines.push(`最近错误：${emailText(summary.latestFailure)}`);

  if (diagnostics.length) {
    lines.push("", "关键请求：");
    for (const record of diagnostics.slice(-8)) {
      const status = record.statusCode == null ? "无状态码" : `HTTP ${emailLine(record.statusCode)}`;
      const elapsed = record.elapsedMilliseconds == null ? "" : ` ${emailLine(record.elapsedMilliseconds)}ms`;
      const error = record.error ? ` · ${emailLine(record.error)}` : "";
      lines.push(`- ${emailLine(record.method || "?")} ${emailText(record.url, 500)} · ${status}${elapsed}${error}`);
    }
  }

  const attachmentCount = Array.isArray(report.attachments) ? report.attachments.length : 0;
  if (attachmentCount) lines.push("", `附件：${attachmentCount} 张`);
  lines.push(
    "",
    `KV 查看键：report:${receivedAt}:${id}`,
    "完整报告：运行 Scripts/fetch-issues-and-reports.sh show <报告键>"
  );
  return lines.join("\n");
}

export class ReportEmailDelivery extends DurableObject {
  async fetch(request) {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const job = await request.json();
    if (!await this.ctx.storage.get("job")) {
      await this.ctx.storage.put("job", { ...job, delivery: { status: "pending", attempts: 0 } });
      await this.ctx.storage.setAlarm(Date.now());
    }
    return json({ queued: true }, 201);
  }

  async alarm(info = { retryCount: 0 }) {
    const job = await this.ctx.storage.get("job");
    if (!job) return;
    const expires = Date.parse(job.receivedAt) + REPORT_RETENTION_SECONDS * 1000;
    if (Date.now() >= expires) { await this.ctx.storage.deleteAll(); return; }
    let stored, record, failure;
    try {
      stored = await this.env.ERROR_REPORTS.getWithMetadata(job.key);
      if (!stored.value) throw new Error("Report storage is pending");
      record = JSON.parse(stored.value);
      if (job.delivery.status === "pending") {
        job.delivery.attempts += 1;
        await this.ctx.storage.put("job", job);
        const category = record.report.mode === "suggestion" ? "用户建议" : "错误报告";
        const sent = await this.env.REPORT_EMAIL.send({
          from: "error-report@aihelpme.dev", to: "idleassetsd@gmail.com",
          subject: `${reportEmailSubject(category, record.report)} [${job.id}]`,
          text: reportEmailBody(job.id, job.receivedAt, record.report),
          headers: { "X-BIT101-Report-ID": job.id }
        });
        job.delivery = { status: "sent", attempts: job.delivery.attempts, messageID: sent?.messageId || "" };
      }
    } catch (error) {
      failure = error;
      if (job.delivery.status === "pending") {
        job.delivery.lastError = emailText(forceRedact(error.message || error.name || "Error"), 300);
      }
    }
    job.delivery.updatedAt = new Date().toISOString();
    await this.ctx.storage.put("job", job);
    if (record) {
      try {
        await this.env.ERROR_REPORTS.put(job.key, JSON.stringify({ ...record, emailDelivery: job.delivery }), {
          metadata: { ...stored.metadata, emailStatus: job.delivery.status }, expiration: Math.floor(expires / 1000)
        });
      } catch (error) { failure = error; }
    }
    if (failure) {
      job.retryFailures = (job.retryFailures || 0) + 1;
      await this.ctx.storage.put("job", job);
      if (info.retryCount < 6) throw failure;
      const delay = Math.min(MAX_EMAIL_RETRY_DELAY_MS, 2000 * 2 ** Math.min(job.retryFailures, 11));
      await this.ctx.storage.setAlarm(Math.min(expires, Date.now() + delay));
      console.error("REPORT_EMAIL_DELIVERY_PENDING", { reportID: job.id, status: job.delivery.status, attempts: job.delivery.attempts });
      return;
    }
    await this.ctx.storage.setAlarm(expires);
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return json({}, 204);
    if (url.pathname !== "/api/error-reports" || request.method !== "POST") {
      return json({ error: "not_found" }, 404);
    }
    if (!env.ERROR_REPORTS) return json({ error: "storage_not_configured" }, 503);
    if (env.REPORT_EMAIL && !env.REPORT_EMAIL_DELIVERY) return json({ error: "notification_queue_not_configured" }, 503);
    const clientIP = request.headers.get("CF-Connecting-IP");
    if (!clientIP) return json({ error: "client_identity_unavailable" }, 503);
    const receivedAt = new Date().toISOString();
    const sourceBytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${receivedAt.slice(0, 10)}:${clientIP}`));
    const source = Array.from(new Uint8Array(sourceBytes), byte => byte.toString(16).padStart(2, "0")).join("");
    const quota = env.REPORT_QUOTA.get(env.REPORT_QUOTA.idFromName("daily"));
    const admissionResponse = await quota.fetch("https://quota/reserve", {
      method: "POST", body: JSON.stringify({ source, admission: true })
    });
    if (!admissionResponse.ok) return json({ error: "quota_unavailable" }, 503);
    const admission = await admissionResponse.json();
    if (!admission.allowed) return json({ error: admission.error }, 429);
    const length = Number(request.headers.get("content-length") || 0);
    if (length > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
    let report;
    try {
      const body = await readReportBody(request);
      if (body === null) return json({ error: "payload_too_large" }, 413);
      report = JSON.parse(body);
    } catch { return json({ error: "invalid_json" }, 400); }
    if (!validReport(report, request)) return json({ error: "invalid_report" }, 400);
    if (report.attachments != null && !Array.isArray(report.attachments)) return json({ error: "invalid_attachment" }, 400);
    if (Array.isArray(report.attachments)) {
      if (report.attachments.length > MAX_ATTACHMENTS) {
        return json({ error: "too_many_attachments" }, 413);
      }
      for (const attachment of report.attachments) {
        if (!attachment || typeof attachment.data !== "string"
          || attachment.contentType != null && typeof attachment.contentType !== "string"
          || attachment.name != null && typeof attachment.name !== "string") {
          return json({ error: "invalid_attachment" }, 400);
        }
        const padding = attachment.data.endsWith("==") ? 2 : attachment.data.endsWith("=") ? 1 : 0;
        const bytes = Math.floor(attachment.data.length * 3 / 4) - padding;
        if (bytes > MAX_ATTACHMENT_BYTES) {
          return json({ error: "attachment_too_large" }, 413);
        }
        if (attachment.data.length < 4 || attachment.data.length % 4 !== 0
          || /[^A-Za-z0-9+/]/.test(attachment.data.slice(0, attachment.data.length - padding))
          || padding > 0 && !/(?:[AQgw]==|[AEIMQUYcgkosw048]=)$/.test(attachment.data)) {
          return json({ error: "invalid_attachment" }, 400);
        }
      }
    }

    const id = crypto.randomUUID();
    let serializedRecord;
    try {
      const { attachments, ...metadata } = report;
      if (new TextEncoder().encode(JSON.stringify(metadata)).byteLength > MAX_REPORT_METADATA_BYTES) {
        return json({ error: "metadata_too_large" }, 413);
      }
      report = forceRedact(report);
      serializedRecord = JSON.stringify({ id, receivedAt, report,
        emailDelivery: { status: env.REPORT_EMAIL && report.mode !== "network-smoke" ? "pending" : "disabled", attempts: 0 } });
    } catch { return json({ error: "invalid_report" }, 400); }

    const quotaResponse = await quota.fetch("https://quota/reserve", {
      method: "POST", body: JSON.stringify({ source, smoke: report.mode === "network-smoke" })
    });
    if (!quotaResponse.ok) return json({ error: "quota_unavailable" }, 503);
    const reservation = await quotaResponse.json();
    if (!reservation.allowed) return json({ error: reservation.error }, 429);

    const recordMetadata = { mode: report.mode, title: listText(report.errorTitle, 100),
      version: listText(report.appVersion, 24), build: listText(report.build, 16) };

    if (
      report.mode === "network-smoke"
      && request.headers.get("x-bit101-network-smoke") === "1"
    ) {
      const runID = report.runID;
      const smokeKey = `smoke:${runID}:${crypto.randomUUID()}`;
      await env.ERROR_REPORTS.put(smokeKey, serializedRecord, { metadata: recordMetadata, expirationTtl: 60 });
      const stored = await env.ERROR_REPORTS.getWithMetadata(smokeKey);
      await env.ERROR_REPORTS.delete(smokeKey);
      return stored.value === serializedRecord && JSON.stringify(stored.metadata) === JSON.stringify(recordMetadata)
        ? json({ ok: true, recordVerified: true, temporaryRecordRemoved: true, quotaReserved: true }, 201) : json({ error: "smoke_write_failed" }, 500);
    }

    const key = `report:${receivedAt}:${id}`;
    if (env.REPORT_EMAIL) {
      const delivery = env.REPORT_EMAIL_DELIVERY.get(env.REPORT_EMAIL_DELIVERY.idFromName(id));
      const queued = await delivery.fetch("https://delivery/queue", { method: "POST", body: JSON.stringify({ id, receivedAt, key }) });
      if (!queued.ok) return json({ error: "notification_queue_unavailable" }, 503);
    }
    await env.ERROR_REPORTS.put(
      key,
      serializedRecord,
      { metadata: recordMetadata, expirationTtl: REPORT_RETENTION_SECONDS }
    );

    return json({ id }, 201);
  }
};
