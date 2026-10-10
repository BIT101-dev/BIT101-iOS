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
    durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true },
      REPORT_EMAIL_DELIVERY: { className: "ReportEmailDelivery", useSQLite: true } },
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
    for (const fields of [{ name: "x".repeat(2 * 1024 * 1024) },
                         { contentType: "x".repeat(2 * 1024 * 1024) },
                         { details: { description: "x".repeat(2 * 1024 * 1024) } }]) {
      const response = await send({ mode: "suggestion", comment: "fixture", attachments: [{ data: "AAAA", ...fields }] });
      assert.equal(response.status, 413);
      assert.equal((await response.json()).error, "metadata_too_large");
    }
    const combinedMetadata = await send({ mode: "suggestion", comment: "fixture",
      attachments: [{ data: "AAAA", name: "x".repeat(600 * 1024) }, { data: "AAAA", name: "x".repeat(600 * 1024) }] });
    assert.equal(combinedMetadata.status, 413);
    assert.equal((await combinedMetadata.json()).error, "metadata_too_large");
    assert.equal((await inspect()).count, 0);
    for (const data of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!", "A==="]) {
      assert.equal((await send({ mode: "network-smoke", runID: "invalid-base64", attachments: [{ data }] })).status, 400);
    }
    assert.equal((await send({ mode: "network-smoke", runID: "maximum",
      attachments: Array.from({ length: 6 }, () => ({ data: Buffer.alloc(2 * 1024 * 1024).toString("base64") })) })).status, 201);
    const kv = await mf.getKVNamespace("ERROR_REPORTS");
    const binary = "ApwdAA==";
    const attachmentResponse = await send({ mode: "suggestion", comment: "password=fixture-secret",
      attachments: [{ data: binary, name: "password=attachment-secret", contentType: "application/octet-stream" }] });
    assert.equal(attachmentResponse.status, 201);
    const attachmentID = (await attachmentResponse.json()).id;
    const attachmentKey = (await kv.list()).keys.find(key => key.name.endsWith(attachmentID)).name;
    const savedAttachment = JSON.parse(await kv.get(attachmentKey)).report;
    assert.equal(savedAttachment.attachments[0].data, binary);
    assert.deepEqual(Buffer.from(savedAttachment.attachments[0].data, "base64"), Buffer.from(binary, "base64"));
    assert(!savedAttachment.comment.includes("fixture-secret"));
    assert(!savedAttachment.attachments[0].name.includes("attachment-secret"));
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
    await seed({ day: today, count: 0 });
    const requestID = crypto.randomUUID();
    const identical = { mode: "suggestion", comment: "idempotent fixture", requestID };
    const receipts = await Promise.all(Array.from({ length: 5 }, () => send(identical)));
    for (const response of receipts) { assert.equal(response.status, 201); assert.equal((await response.json()).id, requestID); }
    assert.equal((await inspect()).count, 1);
    assert.equal((await kv.list()).keys.filter(key => key.name.endsWith(requestID)).length, 1);
    assert.equal((await send({ ...identical, comment: "changed" })).status, 409);
    assert.equal((await send({ ...identical, requestID: "invalid" })).status, 400);
    assert.equal((await inspect()).count, 1);
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
    await seed({ day: today, count: 2000 }, "admission");
    assert.equal((await send({ mode: "suggestion", comment: "quota fixture" })).status, 429);
    const grant = crypto.randomUUID();
    const grantKey = `report-delete-grant:${grant}`;
    const remove = (value = grant) => mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
      method: "DELETE", body: JSON.stringify({ key: attachmentKey, grant: value }) });
    assert.equal((await remove()).status, 403);
    await kv.put(grantKey, JSON.stringify({ key: "report:mismatched" }));
    assert.equal((await remove()).status, 403);
    await kv.put(grantKey, JSON.stringify({ key: attachmentKey }));
    assert.equal((await remove()).status, 200);
    assert.equal(await kv.get(attachmentKey), null);
    assert.equal(await kv.get(grantKey), null);
    assert.equal((await remove()).status, 403);
    assert.equal((await send({ mode: "suggestion", comment: "quota fixture" })).status, 429);
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
  const mailFixture = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8") + `
export class DeliveryFixture extends ReportEmailDelivery {
  async fetch(request) {
    if (new URL(request.url).pathname === "/inspect") {
      return Response.json({ job: await this.ctx.storage.get("job"), alarm: await this.ctx.storage.getAlarm() });
    }
    if (new URL(request.url).pathname === "/wake") {
      await this.ctx.storage.setAlarm(Date.now()); return new Response(null, { status: 204 });
    }
    return super.fetch(request);
  }
}`;
  const mail = new Miniflare(convertV4MiniflareOptions({ workers: [
    { name: "email-acceptance", modules: true, script: mailFixture, compatibilityDate: config.compatibility_date,
      kvNamespaces: ["ERROR_REPORTS"], serviceBindings: { REPORT_EMAIL: "mail-fixture" }, durableObjects: {
        REPORT_QUOTA: { className: "ReportQuota", useSQLite: true },
        REPORT_EMAIL_DELIVERY: { className: "DeliveryFixture", useSQLite: true } } },
    { name: "mail-fixture", modules: true, compatibilityDate: config.compatibility_date, kvNamespaces: ["MAIL_STATUS"], script: `
import { WorkerEntrypoint } from "cloudflare:workers";
export default class extends WorkerEntrypoint {
  async send(message) {
    const count = Number(await this.env.MAIL_STATUS.get("attempts") || 0) + 1;
    await this.env.MAIL_STATUS.put("attempts", String(count));
    if (await this.env.MAIL_STATUS.get("offline") === "1") throw new Error("fixture offline");
    await this.env.MAIL_STATUS.put("delivered", String(Number(await this.env.MAIL_STATUS.get("delivered") || 0) + 1));
    return { messageId: "runtime-receipt" };
  }
}` }
  ], log: new Log(LogLevel.NONE) }));
  try {
    const status = await mail.getKVNamespace("MAIL_STATUS", "mail-fixture");
    await status.put("offline", "1");
    const runtimeReport = { mode: "suggestion", comment: "runtime fixture", requestID: crypto.randomUUID() };
    const accept = value => mail.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify(value) });
    const accepted = await accept(runtimeReport);
    assert.equal(accepted.status, 201);
    const id = (await accepted.json()).id;
    const repeated = await accept({ requestID: runtimeReport.requestID.toUpperCase(), comment: runtimeReport.comment, mode: runtimeReport.mode });
    assert.equal(repeated.status, 201); assert.equal((await repeated.json()).id, id);
    const namespace = await mail.getDurableObjectNamespace("REPORT_EMAIL_DELIVERY", "email-acceptance");
    const identifier = namespace.idFromName(id), delivery = namespace.get(identifier);
    const inspect = async () => (await delivery.fetch("https://delivery/inspect")).json();
    const until = async predicate => {
      const deadline = Date.now() + 10000;
      while (!(await predicate())) { assert(Date.now() < deadline, "Runtime alarm deadline"); await new Promise(resolve => setTimeout(resolve, 20)); }
    };
    await until(async () => Number(await status.get("attempts")) > 0);
    await until(async () => (await inspect()).job.delivery.attempts > 0);
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identifier.toString() });
    assert.equal((await inspect()).job.delivery.status, "pending");
    await status.put("offline", "0");
    await delivery.fetch("https://delivery/wake", { method: "POST" });
    await until(async () => (await inspect()).job.delivery.status === "sent");
    const record = (await inspect()).job;
    assert.equal(record.delivery.messageID, "runtime-receipt");
    const reports = await mail.getKVNamespace("ERROR_REPORTS", "email-acceptance");
    assert.equal((await reports.list()).keys.length, 1);
    await until(async () => JSON.parse(await reports.get(record.key)).emailDelivery.status === "sent");
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identifier.toString() });
    assert.equal((await inspect()).job.delivery.status, "sent");
    await delivery.fetch("https://delivery/wake", { method: "POST" });
    await until(async () => (await inspect()).alarm > Date.now() + 10000);
    assert.equal(await status.get("delivered"), "1");
    assert.equal((await delivery.fetch("https://delivery/delete", { method: "DELETE", body: JSON.stringify({ key: record.key }) })).status, 200);
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identifier.toString() });
    assert.equal((await inspect()).job.deleted, true);
    assert.equal(await reports.get(record.key), null);
  } finally { await mail.dispose(); }
  const bodySource = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8")
    .replace('import { DurableObject } from "cloudflare:workers";', 'class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }') + "\nexport { readReportBody, MAX_BODY_BYTES, forceRedact, decodedPercent, PROTECTED_NAMES, reportEmailSubject, reportEmailBody };";
  const { default: feedback, ReportEmailDelivery, readReportBody, MAX_BODY_BYTES, forceRedact, decodedPercent, PROTECTED_NAMES, reportEmailSubject, reportEmailBody } = await import("data:text/javascript;base64," + Buffer.from(bodySource).toString("base64"));
  const malformedLegacy = { build: { toString: null }, context: { locale: { toString: null } }, diagnosticSummary: { total: { toString: null } },
    diagnostics: [{ statusCode: { toString: null }, elapsedMilliseconds: { toString: null }, method: { toString: null } }] };
  assert.doesNotThrow(() => reportEmailSubject("fixture", malformedLegacy));
  assert.doesNotThrow(() => reportEmailBody("fixture", "fixture", malformedLegacy));
  let saved = 0, sent = 0, offline = true, failStatusWrite = false, failJobWrite = false, failInitialWrite, alarmAt, duringSend;
  let failAcceptanceWrite, failAcceptanceState = false, failAcceptanceAlarm = false, failExpiryAlarm = false;
  const emails = [];
  const records = new Map(), jobs = new Map();
  const storage = {
    async get(key) { return structuredClone(jobs.get(key)); }, async put(key, value) {
      if (value.accepted && failAcceptanceState) { failAcceptanceState = false; throw new Error("acceptance state unavailable"); }
      if (value.delivery.status === "sent" && failJobWrite) { failJobWrite = false; throw new Error("job storage unavailable"); }
      jobs.set(key, structuredClone(value));
    },
    async getAlarm() { return alarmAt ?? null; },
    async setAlarm(at) {
      if (failExpiryAlarm) { failExpiryAlarm = false; throw new Error("retention alarm unavailable"); }
      if (failAcceptanceAlarm && at < Date.now() + 10000) { failAcceptanceAlarm = false; throw new Error("alarm unavailable"); }
      alarmAt = at;
    }, async deleteAll() { jobs.clear(); }
  };
  const emailEnv = {
    ERROR_REPORTS: {
      async get(key) { return records.get(key)?.value || null; },
      async delete(key) { records.delete(key); },
      async getWithMetadata(key) { return records.get(key) || { value: null }; },
      async put(key, value, options) {
        if (failAcceptanceWrite) {
          if (failAcceptanceWrite === "committed") records.set(key, { value, metadata: options.metadata });
          throw new Error("acceptance storage unavailable");
        }
        if (options.expirationTtl && failInitialWrite) {
          if (failInitialWrite === "committed") records.set(key, { value, metadata: options.metadata });
          throw new Error("report storage unavailable");
        }
        if (options.expiration && failStatusWrite) throw new Error("status storage unavailable");
        saved += 1; records.set(key, { value, metadata: options.metadata });
        if (options.expirationTtl) assert.equal(options.expirationTtl, 30 * 24 * 60 * 60);
      }
    },
    REPORT_QUOTA: { idFromName() {}, get() { return { async fetch() { return Response.json({ allowed: true }); } }; } },
    REPORT_EMAIL: { async send(message) {
      sent += 1; emails.push(message); if (offline) throw new Error("offline");
      if (duringSend) { const callback = duringSend; duringSend = null; await callback(); }
      return { messageId: "fixture-receipt" };
    } }
  };
  let serial = Promise.resolve();
  const delivery = new ReportEmailDelivery({ storage, blockConcurrencyWhile(callback) {
    const work = serial.then(callback); serial = work.catch(() => {}); return work;
  } }, emailEnv);
  emailEnv.REPORT_EMAIL_DELIVERY = { idFromName(id) { return id; }, get(id) { return {
    async fetch(url, options) {
      const input = JSON.parse(options.body);
      assert.equal(options.method === "DELETE" ? input.key.split(":").at(-1) : input.id, id);
      return delivery.fetch(new Request(url, options));
    }
  }; } };
  for (const failure of ["rejected", "committed"]) {
    failInitialWrite = failure;
    const failed = await feedback.fetch(new Request("https://feedback.invalid/api/error-reports", { method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment: "fixture" }) }), emailEnv);
    assert.equal(failed.status, 503); assert.equal((await failed.json()).error, "report_storage_unavailable");
    assert.equal(jobs.get("job").deleted, true); assert.equal(records.size, 0);
    await delivery.alarm(); assert.equal(sent, 0); jobs.clear();
  }
  failInitialWrite = null;
  for (const failure of ["rejected", "committed", "state", "alarm", "expiry-alarm"]) {
    jobs.clear(); records.clear(); alarmAt = undefined; saved = 0; sent = 0; offline = false;
    failAcceptanceWrite = ["rejected", "committed"].includes(failure) ? failure : null;
    failAcceptanceState = failure === "state"; failAcceptanceAlarm = failure === "alarm";
    failExpiryAlarm = failure === "expiry-alarm";
    const requestID = crypto.randomUUID();
    const sendAttempt = comment => feedback.fetch(new Request("https://feedback.invalid/api/error-reports", { method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment, requestID }) }), emailEnv);
    assert.equal((await sendAttempt("retained content")).status, 503);
    const firstKey = jobs.get("job")?.key;
    if (failure === "expiry-alarm") { assert.equal(jobs.size, 0); assert.equal(records.size, 0); }
    assert.equal(sent, 0);
    failAcceptanceWrite = null;
    for (let retry = 0; retry < 2; retry++) {
      const receipt = await sendAttempt("retained content");
      assert.equal(receipt.status, 201); assert.equal((await receipt.json()).id, requestID);
    }
    const key = jobs.get("job").key;
    assert.equal(records.size, 1); if (firstKey) assert.equal(key, firstKey);
    assert.equal((await sendAttempt("changed content")).status, 409);
    await delivery.alarm(); assert.equal(sent, 1);
    assert.equal((await sendAttempt("retained content")).status, 201);
    await delivery.alarm(); assert.equal(sent, 1);
    assert.equal(JSON.parse(records.get(key).value).report.comment, "retained content");
    await delivery.fetch(new Request("https://delivery/delete", { method: "DELETE", body: JSON.stringify({ key }) }));
    assert.equal((await sendAttempt("retained content")).status, 410);
    const expired = jobs.get("job");
    expired.receivedAt = new Date(Date.now() - 31 * 24 * 60 * 60 * 1000).toISOString();
    jobs.set("job", expired);
    assert.equal((await sendAttempt("retained content")).status, 201);
    assert.equal(jobs.get("job").deleted, undefined);
  }
  jobs.clear(); records.clear(); alarmAt = undefined; saved = 0; sent = 0; offline = true;
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
  assert.equal(jobs.get("job").delivery.status, "pending"); assert.equal(jobs.get("job").delivery.attempts, 7);
  assert.equal(JSON.parse(records.get(job.key).value).emailDelivery.status, "pending");
  assert(alarmAt > Date.now() && alarmAt < Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 * 1000);
  offline = false; await delivery.alarm({ retryCount: 0 });
  assert.equal(jobs.get("job").delivery.status, "sent"); assert.equal(jobs.get("job").delivery.attempts, 8);
  assert.equal(JSON.parse(records.get(job.key).value).emailDelivery.status, "sent");
  failStatusWrite = true;
  for (let retryCount = 0; retryCount < 6; retryCount++) await assert.rejects(delivery.alarm({ retryCount }));
  const sentBeforeStatusRecovery = sent;
  await delivery.alarm({ retryCount: 6 });
  assert(alarmAt > Date.now() && alarmAt < Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 * 1000);
  failStatusWrite = false; await delivery.alarm({ retryCount: 0 });
  assert.equal(sent, sentBeforeStatusRecovery);
  const grant = crypto.randomUUID(), grantKey = "report-delete-grant:" + grant;
  const deletion = () => feedback.fetch(new Request("https://feedback.invalid/api/error-reports", {
    method: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ key: job.key, grant })
  }), emailEnv);
  assert.equal((await deletion()).status, 403); assert(records.has(job.key));
  records.set(grantKey, { value: JSON.stringify({ key: "report:other" }) });
  assert.equal((await deletion()).status, 403); assert(records.has(job.key));
  records.set(grantKey, { value: JSON.stringify({ key: job.key }) });
  jobs.set("job", { ...job, delivery: { status: "pending", attempts: 0 } });
  duringSend = async () => { assert.equal((await deletion()).status, 200); };
  await delivery.alarm();
  assert(!records.has(job.key)); assert(!records.has(grantKey)); assert.equal(jobs.get("job").deleted, true);
  const sentAfterDeletion = sent;
  await delivery.alarm(); assert.equal(sent, sentAfterDeletion); assert(!records.has(job.key));
  assert.equal((await delivery.fetch(new Request("https://delivery/queue", { method: "POST", body: JSON.stringify(job) }))).status, 410);
  jobs.set("job", { ...job, receivedAt: "2000-01-01T00:00:00Z" }); const attempts = sent;
  await delivery.alarm(); assert.equal(jobs.size, 0); assert.equal(sent, attempts);
  const appNames = JSON.parse("[" + fs.readFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift", "utf8").match(/protectedNames = \[([\s\S]*?)\]/)[1] + "]");
  assert.deepEqual(PROTECTED_NAMES, appNames);
  for (const value of ["https://example.invalid/?%70assword=TEST_ONLY_SECRET", "https://example.invalid/?%2570assword=TEST_ONLY_SECRET", "https://example.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://fixture-user:TEST_ONLY_SECRET@example.invalid/", "https://example.invalid/#%74oken=TEST_ONLY_SECRET", "https://example.invalid/#%2574oken=TEST_ONLY_SECRET", "https://example.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad"]) {
    assert(!decodeURIComponent(forceRedact(value)).includes("TEST_ONLY_SECRET")); assert.equal(forceRedact("https://example.invalid/#section"), "https://example.invalid/#section");
  }
  for (const value of ["Authorization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY_SECRET", "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", '{"password":"TEST_ONLY_\\\"SECRET"}']) assert(!forceRedact(value).includes("TEST_ONLY") && !forceRedact(value).includes("SECRET"));
  const deepPercent = "%" + "25".repeat(20000);
  const originalDecode = globalThis.decodeURIComponent;
  let decodeCalls = 0;
  try {
    globalThis.decodeURIComponent = value => { decodeCalls += 1; return originalDecode(value); };
    assert.throws(() => decodedPercent(deepPercent), /budget/);
    assert(decodeCalls <= 8);
  } finally { globalThis.decodeURIComponent = originalDecode; }
  for (const suffix of [`?note=${deepPercent}`, `?${deepPercent}=TEST_ONLY_SECRET`, `#${deepPercent}`]) {
    assert.equal(forceRedact(`https://example.invalid/${suffix}`), "[REDACTED]");
  }
  let deeplyNested = "https://school.invalid/?ticket=TEST_ONLY_SECRET";
  for (let pass = 0; pass < 12; pass += 1) deeplyNested = encodeURIComponent(deeplyNested);
  assert.equal(forceRedact(`https://example.invalid/?service=${deeplyNested}`), "[REDACTED]");
  for (const value of ['<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">', '<input id="login-croypto" value="SENSITIVE_VALUE">', '<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">', '<input name="execution" value="SENSITIVE_VALUE', '<textarea name="password">SENSITIVE_VALUE</textarea>', '<textarea name="password">SENSITIVE_VALUE', '{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}', '{"captcha_payload":["SENSITIVE_VALUE"]}', '{"cookie_str":{"value":"SENSITIVE_VALUE']) {
    const masked = forceRedact(value); assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE") && masked.includes("[REDACTED]"));
    if (value.includes("available")) assert(masked.includes("available"));
  }
  for (const value of ['<span id="login-page-flowkey">SENSITIVE_VALUE</span>', '<span id="login-page-flowkey">SENSITIVE_VALUE',
    '<meta http-equiv="Set-Cookie" content="SENSITIVE_VALUE">',
    '<meta name="csrf-token" content="SENSITIVE_VALUE">', '<meta content="SENSITIVE_VALUE" property="csrf&#45;token">',
    '<script>const csrfToken = "SENSITIVE_VALUE;TAIL_VALUE";</script>', "<script>var _token = 'SENSITIVE_VALUE;TAIL_VALUE';</script>",
    '<script>window["csrfToken"] = "SENSITIVE_VALUE";</script>', 'csrf_token=SENSITIVE_VALUE',
    '<input type="password" value="SENSITIVE_VALUE">', '<input TYPE=pass&#x77;ord value="SENSITIVE_VALUE">',
    '<input name="pass&#119;ord" value="SENSITIVE_VALUE">', '<input name="pass&#x77ord" value="SENSITIVE_VALUE">',
    '<textarea name="access&lowbar;token">SENSITIVE_VALUE</textarea>']) {
    const masked = forceRedact(value);
    assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE"));
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
  let source = fs.readFileSync("../OpenWorker/worker.js", "utf8");
  const iconImport = source.match(/^import shareIcon from "([^"]+)";/);
  assert(iconImport, "Share icon must use the app asset");
  const png = fs.readFileSync(require("node:path").resolve("../OpenWorker", iconImport[1]));
  const openConfig = JSON.parse(fs.readFileSync("../OpenWorker/wrangler.jsonc", "utf8"));
  assert(openConfig.rules.some(rule => rule.type === "Data" && rule.globs.includes("**/*.png")));
  source = source.replace(iconImport[0], `const shareIcon = Uint8Array.from(atob("${png.toString("base64")}"), character => character.charCodeAt(0)).buffer;`);
  const worker = (await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"))).default;
  const aasa = await (await worker.fetch(new Request("https://open.invalid/.well-known/apple-app-site-association"))).json();
  assert.deepEqual(aasa.applinks.details[0].paths, ["/gallery/*", "/course/*", "/paper/*"]);
  for (const route of ["gallery", "course", "paper"]) {
    const response = await worker.fetch(new Request(`https://open.invalid/${route}/42`));
    assert.equal(response.status, 200);
    const html = await response.text();
    assert(html.includes(`href="bit101://${route}/42"`) && html.includes(`href="https://bit101.cn/${route}/42"`));
    assert(html.includes('<meta property="og:image:type" content="image/png">'));
    assert(html.includes(`<meta property="og:image:width" content="${png.readUInt32BE(16)}">`));
    assert(html.includes(`<meta property="og:image:height" content="${png.readUInt32BE(20)}">`));
    assert(html.includes(`type="image/png" sizes="${png.readUInt32BE(16)}x${png.readUInt32BE(20)}"`));
  }
  for (const route of ["gallery", "course", "paper"]) {
    for (const id of ["0", "9223372036854775808", "9".repeat(100)]) {
      assert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/${id}`))).status, 302);
    }
    assert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/9223372036854775807`))).status, 200);
  }
  let iconRequests = 0;
  global.fetch = async () => { iconRequests += 1; throw new Error("upstream unavailable"); };
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await worker.fetch(new Request("https://open.invalid/share-icon.jpg"));
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "image/png");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=604800");
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  }
  assert.equal(iconRequests, 0);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    result = subprocess.run(["node", "-"], input=script, capture_output=True, text=True,
                            cwd=ROOT / "Cloudflare/EmergencyUpdateWorker", timeout=60)
    return [f"Worker 行为回归：{result.stderr[:600]}"] if result.returncode else []
