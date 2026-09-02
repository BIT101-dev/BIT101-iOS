const MAX_BODY_BYTES = 256 * 1024;
const MAX_REPORTS_PER_DAY = 1000;

const SECRET_KEYS = /password|passwd|pwd|cookie|authorization|token|session/i;

function redactString(value) {
  return value
    .replace(/((?:password|passwd|pwd|cookie|set-cookie|authorization|access_?token|refresh_?token|challenge_?token|fake_?cookie|session(?:id)?|token)\s*[=:]\s*)[^&\s,;]+/gi, "$1[REDACTED]")
    .replace(/("(?:password|passwd|pwd|cookie|set-cookie|authorization|access_?token|refresh_?token|challenge_?token|fake_?cookie|session(?:id)?|token)"\s*:\s*")[^"]*(")/gi, "$1[REDACTED]$2");
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
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS"
    }
  });
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
    const body = await request.text();
    if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) {
      return json({ error: "payload_too_large" }, 413);
    }
    let report;
    try { report = JSON.parse(body); } catch { return json({ error: "invalid_json" }, 400); }
    if (!report || typeof report !== "object") return json({ error: "invalid_report" }, 400);
    report = forceRedact(report);
    const day = new Date().toISOString().slice(0, 10);
    const countKey = `count:${day}`;
    const count = Number(await env.ERROR_REPORTS.get(countKey) || 0);
    if (count >= MAX_REPORTS_PER_DAY) return json({ error: "daily_limit_reached" }, 429);
    await env.ERROR_REPORTS.put(countKey, String(count + 1), { expirationTtl: 172800 });
    const id = crypto.randomUUID();
    const receivedAt = new Date().toISOString();
    await env.ERROR_REPORTS.put(
      `report:${receivedAt}:${id}`,
      JSON.stringify({ id, receivedAt, report }),
      { metadata: { mode: report.mode, title: report.errorTitle, version: report.appVersion, build: report.build } }
    );

    if (env.REPORT_EMAIL) {
      ctx.waitUntil(env.REPORT_EMAIL.send({
        from: "error-report@aihelpme.dev",
        to: "idleassetsd@gmail.com",
        subject: `BIT101 新错误报告（${report.appVersion || "未知版本"}）`,
        text: `收到新的 BIT101 错误报告。\n\n报告编号：${id}\n接收时间：${receivedAt}\n\n邮件不包含报告正文，请在已登录的电脑上运行 Scripts/error-reports.sh 查看。`
      }).catch(() => {}));
    }
    return json({ id }, 201);
  }
};
