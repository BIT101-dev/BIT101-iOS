import { DurableObject } from "cloudflare:workers";

const MAX_ATTACHMENTS = 6;
const MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024;
const MAX_REPORT_METADATA_BYTES = 1024 * 1024;
const MAX_BODY_BYTES = MAX_ATTACHMENTS * 4 * Math.ceil(MAX_ATTACHMENT_BYTES / 3) + MAX_REPORT_METADATA_BYTES;
const MAX_REPORTS_PER_DAY = 1000;
const MAX_REPORTS_PER_SOURCE_PER_DAY = 100;

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
const SECRET_TEXT = new RegExp(`(\\b(?:${SECRET_NAMES})\\s*[=:]\\s*)[^&\\r\\n,;]+`, "gi");

function redactHTML(value) {
  return value.replace(/<input\b(?:[^>"']|"[^"]*(?:"|$)|'[^']*(?:'|$))*(?:>|$)|<textarea\b(?:[^>"']|"[^"]*"|'[^']*')*>[\s\S]*?(?:<\/textarea\s*>|$)/gi, tag => {
    const fields = [...tag.matchAll(/\b(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi)]
      .map(match => match[1] ?? match[2] ?? match[3]);
    if (!fields.some(field => SECRET_KEYS.test(field) || /^(?:login-page-flowkey|login-croypto)$/i.test(field))) return tag;
    const masked = tag.replace(/(\bvalue\s*=\s*)(?:"[^"]*(?:"|$)|'[^']*(?:'|$)|[^\s"'=<>`]+)/gi, '$1"[REDACTED]"');
    return /^<textarea\b/i.test(tag) ? masked.replace(/(>)[\s\S]*(<\/textarea\s*>|$)/gi, "$1[REDACTED]$2") : masked;
  });
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
    const { source, smoke } = await request.json();
    const key = smoke ? "smoke" : "daily";
    const day = new Date().toISOString().slice(0, 10);
    const result = this.ctx.storage.transactionSync(() => {
      const previous = this.ctx.storage.kv.get(key);
      const current = previous?.day === day ? previous : { day, count: 0 };
      if (current.count >= MAX_REPORTS_PER_DAY) return { allowed: false, error: "daily_limit_reached" };
      const sources = current.sources ?? {};
      const count = sources[source] ?? 0;
      if (count >= MAX_REPORTS_PER_SOURCE_PER_DAY) return { allowed: false, error: "source_limit_reached" };
      sources[source] = count + 1;
      this.ctx.storage.kv.put(key, { day, count: current.count + 1, sources });
      return { allowed: true };
    });
    return Response.json(result);
  }
}

function emailText(value, limit = 1200) {
  const text = value == null ? "" : String(value).trim();
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
  const version = report.appVersion || "未知版本";
  const build = report.build || "?";
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
    `构建：${report.isDevelopmentBuild ? "开发版" : "正式版"} ${report.appVersion || "?"} (${report.build || "?"})`,
    `设备：${report.deviceModel || "?"}`,
    `系统：${report.systemVersion || "?"}`,
    `语言环境：${context.locale || "?"}`,
    `时区：${context.timeZone || "?"}`,
    `界面：${context.interfaceStyle || "?"} · 方向：${context.orientation || "?"}`,
    `网络：${context.networkStatus || report.networkStatus || "?"}`,
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
    `诊断记录：${summary.total ?? diagnostics.length} 条，失败 ${summary.failed ?? 0} 条`,
    `状态码统计：${Object.entries(summary.statusCodes || {}).map(([code, count]) => `${code}×${count}`).join("、") || "暂无"}`
  );
  if (summary.latestFailure) lines.push(`最近错误：${emailText(summary.latestFailure)}`);

  if (diagnostics.length) {
    lines.push("", "关键请求：");
    for (const record of diagnostics.slice(-8)) {
      const status = record.statusCode == null ? "无状态码" : `HTTP ${record.statusCode}`;
      const elapsed = record.elapsedMilliseconds == null ? "" : ` ${record.elapsedMilliseconds}ms`;
      const error = record.error ? ` · ${emailLine(record.error)}` : "";
      lines.push(`- ${record.method || "?"} ${emailText(record.url, 500)} · ${status}${elapsed}${error}`);
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

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return json({}, 204);
    if (url.pathname !== "/api/error-reports" || request.method !== "POST") {
      return json({ error: "not_found" }, 404);
    }
    if (!env.ERROR_REPORTS) return json({ error: "storage_not_configured" }, 503);
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
    const receivedAt = new Date().toISOString();
    let serializedReport, serializedRecord;
    try {
      const { attachments, ...metadata } = report;
      if (new TextEncoder().encode(JSON.stringify(metadata)).byteLength > MAX_REPORT_METADATA_BYTES) {
        return json({ error: "metadata_too_large" }, 413);
      }
      report = forceRedact(report);
      serializedReport = JSON.stringify(report);
      serializedRecord = JSON.stringify({ id, receivedAt, report });
    } catch { return json({ error: "invalid_report" }, 400); }

    const clientIP = request.headers.get("CF-Connecting-IP");
    if (!clientIP) return json({ error: "client_identity_unavailable" }, 503);
    const sourceBytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
      `${receivedAt.slice(0, 10)}:${clientIP}`
    ));
    const source = Array.from(new Uint8Array(sourceBytes), byte => byte.toString(16).padStart(2, "0")).join("");
    const quota = env.REPORT_QUOTA.get(env.REPORT_QUOTA.idFromName("daily"));
    const reservation = await (await quota.fetch("https://quota/reserve", {
      method: "POST", body: JSON.stringify({ source, smoke: report.mode === "network-smoke" })
    })).json();
    if (!reservation.allowed) return json({ error: reservation.error }, 429);

    if (
      report.mode === "network-smoke"
      && request.headers.get("x-bit101-network-smoke") === "1"
    ) {
      const runID = report.runID;
      const smokeKey = `smoke:${runID}:${crypto.randomUUID()}`;
      await env.ERROR_REPORTS.put(smokeKey, serializedReport, { expirationTtl: 60 });
      const stored = await env.ERROR_REPORTS.get(smokeKey);
      await env.ERROR_REPORTS.delete(smokeKey);
      return stored ? json({ ok: true, temporaryRecordRemoved: true, quotaReserved: true }, 201) : json({ error: "smoke_write_failed" }, 500);
    }

    const category = report.mode === "suggestion" ? "用户建议" : "错误报告";
    await env.ERROR_REPORTS.put(
      `report:${receivedAt}:${id}`,
      serializedRecord,
      { metadata: { mode: report.mode, title: listText(report.errorTitle, 100),
        version: listText(report.appVersion, 24), build: listText(report.build, 16) } }
    );

    if (env.REPORT_EMAIL) {
      ctx.waitUntil(Promise.resolve().then(() => env.REPORT_EMAIL.send({
        from: "error-report@aihelpme.dev",
        to: "idleassetsd@gmail.com",
        subject: reportEmailSubject(category, report),
        text: reportEmailBody(id, receivedAt, report)
      })).catch(error => {
        console.error("REPORT_EMAIL_FAILED", { reportID: id, error: error.name || "Error" });
      }));
    }
    return json({ id }, 201);
  }
};
