"""Exercise deployed Worker contracts in the local Workers runtime."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def worker_boundary_findings() -> list[str]:
    "通过 Workers 本地 runtime 验证跨域预检、并发配额及 Smoke 约束。"
    script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = require("miniflare");
(async () => {
  const config = JSON.parse(fs.readFileSync("../ErrorReportWorker/wrangler.jsonc", "utf8"));
  assert(config.durable_objects.bindings.some(binding => binding.name === "REPORT_QUOTA" && binding.class_name === "ReportQuota"));
  assert(config.migrations.some(migration => migration.new_sqlite_classes.includes("ReportQuota")));
  assert(config.durable_objects.bindings.some(binding => binding.name === "REPORT_EMAIL_DELIVERY" && binding.class_name === "ReportEmailDelivery"));
  assert(config.migrations.some(migration => migration.new_sqlite_classes.includes("ReportEmailDelivery")));
  const fixture = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8") + `
export class QuotaFixture extends ReportQuota {
  async fetch(request) {
    if (new URL(request.url).pathname === "/seed") {
      this.ctx.storage.kv.put(new URL(request.url).searchParams.get("kind") || "daily", await request.json());
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname === "/inspect") return Response.json(this.ctx.storage.kv.get(new URL(request.url).searchParams.get("kind") || "daily"));
    return super.fetch(request);
  }
}`;
  const mf = new Miniflare(convertV4MiniflareOptions({ name: "worker-fixture", modules: true, script: fixture,
    compatibilityDate: config.compatibility_date, kvNamespaces: ["ERROR_REPORTS"],
    durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true } },
    log: new Log(LogLevel.NONE) }));
  try {
    const preflight = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "OPTIONS",
      headers: { Origin: "https://bit101.cn", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type" } });
    assert.equal(preflight.status, 204);
    assert.equal(await preflight.text(), "");
    assert.equal(preflight.headers.get("Access-Control-Allow-Origin"), "*");
    assert(preflight.headers.get("Access-Control-Allow-Methods").split(",").map(value => value.trim()).includes("POST"));
    assert(preflight.headers.get("Access-Control-Allow-Headers").split(",").map(value => value.trim().toLowerCase()).includes("content-type"));
    const namespace = await mf.getDurableObjectNamespace("REPORT_QUOTA");
    const quota = namespace.get(namespace.idFromName("daily"));
    const today = new Date().toISOString().slice(0, 10);
    const seed = (value, kind = "daily") => quota.fetch(`https://quota/seed?kind=${kind}`, { method: "POST", body: JSON.stringify(value) });
    const inspect = async (kind = "daily") => (await quota.fetch(`https://quota/inspect?kind=${kind}`)).json();
    const send = (value, ip = "192.0.2.1") => mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
      method: "POST", headers: { "CF-Connecting-IP": ip, "x-bit101-network-smoke": "1" }, body: JSON.stringify(value) });
    await seed({ day: today, count: 0 });
    for (const value of [{}, [], { mode: "unknown" }, { mode: "sanitized" }, { mode: "suggestion", comment: " " },
                         { mode: "network-smoke", runID: "" }, { mode: "network-smoke", runID: "wrong/value" },
                         ...[{}, [null], [1], [[]]].map(diagnostics => ({ mode: "suggestion", comment: "fixture", diagnostics }))]) {
      assert.equal((await send(value)).status, 400);
    }
    for (const contentType of [[], {}, 5]) {
      assert.equal((await send({ mode: "suggestion", comment: "fixture", attachments: [{ data: "QQ==", contentType }] })).status, 400);
    }
    const deep = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "POST", body: '{"mode":"suggestion","comment":"fixture","extra":' + '['.repeat(5000) + 'null' + ']'.repeat(5000) + '}' });
    assert.equal(deep.status, 400);
    assert.equal((await send({ mode: "suggestion", comment: "x".repeat(2 * 1024 * 1024) })).status, 413);
    assert.equal((await inspect()).count, 0);
    for (const data of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!", "A==="]) {
      assert.equal((await send({ mode: "network-smoke", runID: "invalid-base64", attachments: [{ data }] })).status, 400);
    }
    assert.equal((await send({ mode: "network-smoke", runID: "maximum",
      attachments: Array.from({ length: 6 }, () => ({ data: Buffer.alloc(2 * 1024 * 1024).toString("base64") })) })).status, 201);
    const kv = await mf.getKVNamespace("ERROR_REPORTS");
    assert.equal((await send({ mode: "sanitized", errorTitle: "fixture", errorMessage: "fixture", build: { toString: null } })).status, 400);
    for (const title of ["x".repeat(1100), "\u0000".repeat(1100), "🧪".repeat(1100)]) {
      const response = await send({ mode: "sanitized", errorTitle: title, errorMessage: "fixture",
        appVersion: "\u0000".repeat(1100), build: "1" });
      assert.equal(response.status, 201);
      const id = (await response.json()).id;
      const row = (await kv.list()).keys.find(key => key.name.endsWith(id));
      assert(Buffer.byteLength(JSON.stringify(row.metadata)) <= 1024);
      assert.equal(JSON.parse(await kv.get(row.name)).report.errorTitle, title);
    }
    const source = Object.keys((await inspect()).sources)[0];
    assert(/^[a-f0-9]{64}$/.test(source));
    await seed({ day: today, count: 99, sources: { [source]: 99 } });
    const concurrent = () => Promise.all(Array.from({ length: 5 }, () => send({ mode: "suggestion", comment: "fixture" })));
    const sourceResponses = await concurrent();
    assert.equal(sourceResponses.filter(response => response.status === 201).length, 1);
    assert.equal(sourceResponses.filter(response => response.status === 429).length, 4);
    assert.equal((await sourceResponses.find(response => response.status === 429).json()).error, "source_limit_reached");
    assert.equal((await send({ mode: "suggestion", comment: "fixture" }, "192.0.2.2")).status, 201);
    await seed({ day: today, count: 999 });
    const responses = await concurrent();
    assert.equal(responses.filter(response => response.status === 201).length, 1);
    assert.equal(responses.filter(response => response.status === 429).length, 4);
    assert.equal((await inspect()).count, 1000);
    const nextDay = await send({ mode: "network-smoke", runID: "fixture" });
    assert.equal(nextDay.status, 201);
    assert.deepEqual(await nextDay.json(), { ok: true, recordVerified: true, temporaryRecordRemoved: true, quotaReserved: true });
    await seed({ day: today, count: 1000 }, "smoke");
    assert.equal((await send({ mode: "network-smoke", runID: "fixture" })).status, 429);
    await seed({ day: "2000-01-01", count: 1000 });
    assert.equal((await send({ mode: "suggestion", comment: "fixture" })).status, 201);
    assert.equal((await inspect()).count, 1);
    assert((await kv.list()).keys.every(key => key.name.startsWith("report:")));
  } finally { await mf.dispose(); }
  for (const limit of ["150", "0", "invalid"]) {
    const configured = new Miniflare(convertV4MiniflareOptions({ name: "worker-fixture", modules: true, script: fixture,
      compatibilityDate: config.compatibility_date, bindings: { REPORT_SOURCE_DAILY_LIMIT: limit },
      durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true } }, log: new Log(LogLevel.NONE) }));
    try {
      const namespace = await configured.getDurableObjectNamespace("REPORT_QUOTA");
      const quota = namespace.get(namespace.idFromName("daily"));
      const day = new Date().toISOString().slice(0, 10);
      await quota.fetch("https://quota/seed", { method: "POST", body: JSON.stringify({ day, count: 149, sources: { fixture: 149 } }) });
      const reserve = () => quota.fetch("https://quota/reserve", { method: "POST", body: JSON.stringify({ source: "fixture", smoke: false }) });
      const first = await reserve();
      if (limit === "150") {
        assert.equal((await first.json()).allowed, true);
        assert.equal((await (await reserve()).json()).error, "source_limit_reached");
        await quota.fetch("https://quota/seed", { method: "POST", body: JSON.stringify({ day, count: 1000 }) });
        assert.equal((await (await reserve()).json()).error, "daily_limit_reached");
      } else {
        assert.equal(first.status, 503);
        assert.equal((await first.json()).error, "invalid_source_quota");
      }
    } finally { await configured.dispose(); }
  }
  const bodySource = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8")
    .replace('import { DurableObject } from "cloudflare:workers";', 'class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }') + "\nexport { readReportBody, MAX_BODY_BYTES, forceRedact, PROTECTED_NAMES, reportEmailSubject, reportEmailBody };";
  const { default: feedback, ReportEmailDelivery, readReportBody, MAX_BODY_BYTES, forceRedact, PROTECTED_NAMES, reportEmailSubject, reportEmailBody } = await import("data:text/javascript;base64," + Buffer.from(bodySource).toString("base64"));
  const malformedLegacy = { build: { toString: null }, context: { locale: { toString: null } }, diagnosticSummary: { total: { toString: null } },
    diagnostics: [{ statusCode: { toString: null }, elapsedMilliseconds: { toString: null }, method: { toString: null } }] };
  assert.doesNotThrow(() => reportEmailSubject("fixture", malformedLegacy));
  assert.doesNotThrow(() => reportEmailBody("fixture", "fixture", malformedLegacy));
  let saved = 0, sent = 0, offline = true, failStatusWrite = false, failJobWrite = false, alarmAt;
  const emails = [];
  const records = new Map(), jobs = new Map();
  const storage = {
    async get(key) { return structuredClone(jobs.get(key)); }, async put(key, value) {
      if (value.delivery.status === "sent" && failJobWrite) { failJobWrite = false; throw new Error("job storage unavailable"); }
      jobs.set(key, structuredClone(value));
    },
    async setAlarm(at) { alarmAt = at; }, async deleteAll() { jobs.clear(); }
  };
  const emailEnv = {
    ERROR_REPORTS: {
      async getWithMetadata(key) { return records.get(key) || { value: null }; },
      async put(key, value, options) {
        if (options.expiration && failStatusWrite) throw new Error("status storage unavailable");
        saved += 1; records.set(key, { value, metadata: options.metadata });
        if (options.expirationTtl) assert.equal(options.expirationTtl, 30 * 24 * 60 * 60);
      }
    },
    REPORT_QUOTA: { idFromName() {}, get() { return { async fetch() { return Response.json({ allowed: true }); } }; } },
    REPORT_EMAIL: { send(message) { sent += 1; emails.push(message); if (offline) throw new Error("offline"); return { messageId: "fixture-receipt" }; } }
  };
  const delivery = new ReportEmailDelivery({ storage }, emailEnv);
  emailEnv.REPORT_EMAIL_DELIVERY = { idFromName(id) { return id; }, get(id) { return {
    async fetch(url, options) { assert.equal(JSON.parse(options.body).id, id); return delivery.fetch(new Request(url, options)); }
  }; } };
  const accepted = await feedback.fetch(new Request("https://feedback.invalid/api/error-reports", { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment: "fixture" }) }), {
    ...emailEnv
  });
  let bodyReads = 0;
  const blockedBody = new ReadableStream({ pull(controller) { bodyReads++; controller.enqueue(new TextEncoder().encode("fixture")); } }, { highWaterMark: 0 });
  const blocked = await feedback.fetch(new Request("https://feedback.invalid/api/error-reports", { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: blockedBody, duplex: "half" }), {
    ...emailEnv, REPORT_QUOTA: { idFromName() {}, get() { return { async fetch() { return Response.json({ allowed: false, error: "source_limit_reached" }); } }; } }
  });
  assert.equal(blocked.status, 429); assert.equal(bodyReads, 0);
  assert.equal(accepted.status, 201); assert.equal(saved, 1); assert.equal(sent, 0); assert(alarmAt);
  await assert.rejects(delivery.alarm({ retryCount: 0 }));
  assert.equal(jobs.get("job").delivery.status, "pending"); assert.equal(sent, 1);
  offline = false; failStatusWrite = true;
  await assert.rejects(delivery.alarm({ retryCount: 1 }));
  assert.equal(jobs.get("job").delivery.status, "sent"); assert.equal(sent, 2);
  failStatusWrite = false; await delivery.alarm({ retryCount: 2 });
  assert.equal(sent, 2);
  const job = jobs.get("job"), stored = JSON.parse(records.get(job.key).value);
  assert.equal(stored.emailDelivery.status, "sent"); assert.equal(stored.emailDelivery.messageID, "fixture-receipt");
  assert.equal(records.get(job.key).metadata.emailStatus, "sent");
  assert.equal(alarmAt, Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 * 1000);
  jobs.set("job", { ...job, delivery: { status: "pending", attempts: 0 } }); failJobWrite = true;
  const beforeJobFailure = sent;
  await assert.rejects(delivery.alarm({ retryCount: 0 }));
  assert.equal(jobs.get("job").delivery.status, "pending"); assert.equal(jobs.get("job").delivery.attempts, 1);
  await delivery.alarm({ retryCount: 1 });
  assert.equal(sent, beforeJobFailure + 2); assert.equal(jobs.get("job").delivery.attempts, 2);
  assert.equal(emails.at(-1).headers["X-BIT101-Report-ID"], job.id);
  assert.equal(emails.at(-1).subject, emails.at(-2).subject);
  assert.equal(emails.at(-1).text, emails.at(-2).text);
  await delivery.alarm({ retryCount: 2 }); assert.equal(sent, beforeJobFailure + 2);
  jobs.set("job", { ...job, delivery: { status: "pending", attempts: 0 } }); offline = true;
  for (let retryCount = 0; retryCount < 6; retryCount++) await assert.rejects(delivery.alarm({ retryCount }));
  await delivery.alarm({ retryCount: 6 });
  assert.equal(jobs.get("job").delivery.status, "failed"); assert.equal(jobs.get("job").delivery.attempts, 7);
  assert.equal(JSON.parse(records.get(job.key).value).emailDelivery.status, "failed");
  jobs.set("job", { ...job, receivedAt: "2000-01-01T00:00:00Z" }); const attempts = sent;
  await delivery.alarm(); assert.equal(jobs.size, 0); assert.equal(sent, attempts);
  const appNames = JSON.parse("[" + fs.readFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift", "utf8").match(/protectedNames = \[([\s\S]*?)\]/)[1] + "]");
  assert.deepEqual(PROTECTED_NAMES, appNames);
  for (const value of ["https://example.invalid/?%70assword=TEST_ONLY_SECRET", "https://example.invalid/?%2570assword=TEST_ONLY_SECRET", "https://example.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://fixture-user:TEST_ONLY_SECRET@example.invalid/", "https://example.invalid/#%74oken=TEST_ONLY_SECRET", "https://example.invalid/#%2574oken=TEST_ONLY_SECRET", "https://example.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad"]) {
    assert(!decodeURIComponent(forceRedact(value)).includes("TEST_ONLY_SECRET")); assert.equal(forceRedact("https://example.invalid/#section"), "https://example.invalid/#section");
  }
  for (const value of ["Authorization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY_SECRET", "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", '{"password":"TEST_ONLY_\\\"SECRET"}']) assert(!forceRedact(value).includes("TEST_ONLY") && !forceRedact(value).includes("SECRET"));
  for (const value of ['<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">', '<input id="login-croypto" value="SENSITIVE_VALUE">', '<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">', '<input name="execution" value="SENSITIVE_VALUE', '<textarea name="password">SENSITIVE_VALUE</textarea>', '<textarea name="password">SENSITIVE_VALUE', '{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}', '{"captcha_payload":["SENSITIVE_VALUE"]}', '{"cookie_str":{"value":"SENSITIVE_VALUE']) {
    const masked = forceRedact(value); assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE") && masked.includes("[REDACTED]"));
    if (value.includes("available")) assert(masked.includes("available"));
  }
  for (const value of ['<input type="password" value="SENSITIVE_VALUE">', '<input TYPE=pass&#x77;ord value="SENSITIVE_VALUE">',
    '<input name="pass&#119;ord" value="SENSITIVE_VALUE">', '<input name="pass&#x77ord" value="SENSITIVE_VALUE">',
    '<textarea name="access&lowbar;token">SENSITIVE_VALUE</textarea>']) {
    assert(!forceRedact(value).includes("SENSITIVE_VALUE"));
  }
  const ordinaryInput = '<input type="text" name="summary" value="visible">';
  assert.equal(forceRedact(ordinaryInput), ordinaryInput);
  const emergency = (await import("data:text/javascript;base64," + Buffer.from(fs.readFileSync("src/index.js", "utf8")).toString("base64"))).default;
  const notice = { schema_version: 1, enabled: true, notice_id: "fixture", maximum_affected_build: 100, title: "fixture", message: "fixture" };
  for (const [value, status] of [[null, 503], [{ enabled: false }, 503], [{ schema_version: 1, enabled: false }, 200], [new Error("offline"), 503], [notice, 200], [{ ...notice, title: " " }, 503], [{ ...notice, maximum_affected_build: 1e20 }, 503]]) {
    const response = await emergency.fetch(new Request("https://emergency.invalid/emergency-update.json"), { EMERGENCY_CONFIG: { async get() { if (value instanceof Error) throw value; return value; } } });
    assert.equal(response.status, status);
  }
  for (const args of [["1", " ", "fixture"], ["1", "fixture", " "], ["9007199254740992", "fixture", "fixture"]]) {
    assert.equal(require("node:child_process").spawnSync("zsh", ["Scripts/publish-emergency-update.sh", ...args]).status, 64);
  }
  const publisher = fs.readFileSync("Scripts/publish-emergency-update.sh", "utf8");
  assert(publisher.includes('source "$ROOT_DIR/../../Scripts/script-support.sh"'));
  assert(publisher.includes('bit101_acquire_script_lock "$HOME/Library/Caches/BIT101-iOS/emergency-publish.lock" BIT101_EMERGENCY_PUBLISH_LOCK_HELD "$0" "$@"'));
  assert(publisher.indexOf("bit101_acquire_script_lock") < publisher.indexOf('"$WRANGLER" kv key put'));
  let chunks = 0, cancelled = false;
  const stream = new ReadableStream({
    pull(controller) { chunks += 1; controller.enqueue(new Uint8Array(1024 * 1024)); },
    cancel() { cancelled = true; }
  });
  assert.equal(await readReportBody(new Request("https://feedback.invalid", { method: "POST", body: stream, duplex: "half" })), null);
  assert(cancelled && chunks <= Math.floor(MAX_BODY_BYTES / (1024 * 1024)) + 2);
  const utf8 = new TextEncoder().encode('文章😀');
  const split = new ReadableStream({ start(controller) {
    for (const byte of utf8) controller.enqueue(new Uint8Array([byte]));
    controller.close();
  }});
  assert.equal(await readReportBody(new Request("https://feedback.invalid", { method: "POST", body: split, duplex: "half" })), '文章😀');
  const source = fs.readFileSync("../OpenWorker/worker.js", "utf8");
  const worker = (await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"))).default;
  const aasa = await (await worker.fetch(new Request("https://open.invalid/.well-known/apple-app-site-association"))).json();
  assert.deepEqual(aasa.applinks.details[0].paths, ["/gallery/*", "/course/*", "/paper/*"]);
  for (const route of ["gallery", "course", "paper"]) {
    const response = await worker.fetch(new Request(`https://open.invalid/${route}/42`));
    assert.equal(response.status, 200);
    const html = await response.text();
    assert(html.includes(`href="bit101://${route}/42"`) && html.includes(`href="https://bit101.cn/${route}/42"`));
  }
  for (const route of ["gallery", "course", "paper"]) {
    for (const id of ["0", "9223372036854775808", "9".repeat(100)]) {
      assert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/${id}`))).status, 302);
    }
    assert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/9223372036854775807`))).status, 200);
  }
  const jpeg = Buffer.from(fs.readFileSync("../../BIT101-iOS/Shared/Client/CommunityWriteMedia.swift", "utf8").match(/Data\(base64Encoded: "([^"]+)"/)[1], "base64");
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ9sAAAAASUVORK5CYII=", "base64");
  for (const [status, type, expected] of [[404, "text/html", 404], [200, "text/html", 502], [200, "image/jpeg", 200], [200, "image/png", 200]]) {
    global.fetch = async url => String(url).startsWith("https://itunes.apple.com/")
      ? Response.json({ results: [{ trackId: 6761147125, artworkUrl512: "https://is1-ssl.mzstatic.com/current.jpg" }] })
      : new Response(type === "image/png" ? png : jpeg, { status, headers: { "Content-Type": type } });
    const response = await worker.fetch(new Request("https://open.invalid/share-icon.jpg"));
    assert.equal(response.status, expected);
    if (expected !== 200) assert.equal(response.headers.get("Cache-Control"), "no-store"); else assert.equal(response.headers.get("Content-Type"), type);
  }
  for (const body of ["fixture", jpeg.subarray(0, jpeg.length - 2)]) {
    global.fetch = async url => String(url).startsWith("https://itunes.apple.com/")
      ? Response.json({ results: [{ trackId: 6761147125, artworkUrl512: "https://is1-ssl.mzstatic.com/current.jpg" }] })
      : new Response(body, { headers: { "Content-Type": "image/jpeg" } });
    assert.equal((await worker.fetch(new Request("https://open.invalid/share-icon.jpg"))).status, 502);
  }
  let canceledIcon = false;
  global.fetch = async url => String(url).startsWith("https://itunes.apple.com/")
    ? Response.json({ results: [{ trackId: 6761147125, artworkUrl512: "https://is1-ssl.mzstatic.com/current.jpg" }] })
    : new Response(new ReadableStream({ start(controller) {
        const chunk = new Uint8Array(8 * 1024 * 1024);
        for (let index = 0; index < 5; index++) controller.enqueue(chunk);
      }, cancel() { canceledIcon = true; } }), { headers: { "Content-Type": "image/jpeg" } });
  assert.equal((await worker.fetch(new Request("https://open.invalid/share-icon.jpg"))).status, 502);
  assert(canceledIcon);
  const originalTimeout = global.setTimeout;
  global.setTimeout = callback => originalTimeout(callback, 0);
  global.fetch = async (_, { signal }) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("expired")), { once: true }));
  try { assert.equal((await worker.fetch(new Request("https://open.invalid/share-icon.jpg"))).status, 502); }
  finally { global.setTimeout = originalTimeout; }
  for (const results of [[], [{ trackId: 1, artworkUrl512: "https://is1-ssl.mzstatic.com/icon.jpg" }],
      [{ trackId: 6761147125, artworkUrl512: "https://foreign.invalid/icon.jpg" }]]) {
    let calls = 0;
    global.fetch = async () => { calls += 1; return Response.json({ results }); };
    assert.equal((await worker.fetch(new Request("https://open.invalid/share-icon.jpg"))).status, 502);
    assert.equal(calls, 1);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    result = subprocess.run(["node", "-"], input=script, capture_output=True, text=True,
                            cwd=ROOT / "Cloudflare/EmergencyUpdateWorker", timeout=60)
    return [f"Worker 行为回归：{result.stderr[:600]}"] if result.returncode else []
