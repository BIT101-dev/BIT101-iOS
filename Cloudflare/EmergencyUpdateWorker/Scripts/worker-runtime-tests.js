const assert = require("node:assert/strict");
const fs = require("node:fs");
const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = require("miniflare");
const { experimental_readRawConfig } = require("wrangler");

async function runRuntimeTests() {
  const config = experimental_readRawConfig({
    config: "../ErrorReportWorker/wrangler.jsonc",
  }).rawConfig;
  assert.equal(
    config.vars.REPORT_EMAIL_RECIPIENT,
    config.send_email.find((binding) => binding.name === "REPORT_EMAIL").destination_address,
  );
  assert(
    config.durable_objects.bindings.some(
      (binding) => binding.name === "REPORT_QUOTA" && binding.class_name === "ReportQuota",
    ),
  );
  assert(
    config.migrations.some((migration) => migration.new_sqlite_classes.includes("ReportQuota")),
  );
  assert(
    config.durable_objects.bindings.some(
      (binding) =>
        binding.name === "REPORT_EMAIL_DELIVERY" && binding.class_name === "ReportEmailDelivery",
    ),
  );
  assert(
    config.migrations.some((migration) =>
      migration.new_sqlite_classes.includes("ReportEmailDelivery"),
    ),
  );
  const fixtureDay = "2026-01-01";
  const workerSource = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8");
  const dayExpression = "new Date().toISOString().slice(0, 10)";
  assert(workerSource.includes(dayExpression));
  const fixture =
    workerSource.replace(dayExpression, JSON.stringify(fixtureDay)) +
    `
export class QuotaFixture extends ReportQuota {
  async fetch(request) {
    if (new URL(request.url).pathname === "/seed") {
      this.ctx.storage.kv.put(
        new URL(request.url).searchParams.get("kind") || "daily", await request.json());
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname === "/inspect") {
      return Response.json(this.ctx.storage.kv.get(
        new URL(request.url).searchParams.get("kind") || "daily"));
    }
    return super.fetch(request);
  }
}`;
  const mf = new Miniflare(
    convertV4MiniflareOptions({
      name: "worker-fixture",
      modules: true,
      script: fixture,
      compatibilityDate: config.compatibility_date,
      kvNamespaces: ["ERROR_REPORTS"],
      durableObjects: {
        REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true },
        REPORT_EMAIL_DELIVERY: { className: "ReportEmailDelivery", useSQLite: true },
      },
      log: new Log(LogLevel.NONE),
    }),
  );
  try {
    const preflight = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
      method: "OPTIONS",
      headers: {
        Origin: "https://bit101.cn",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
      },
    });
    assert.equal(preflight.status, 204);
    assert.equal(await preflight.text(), "");
    assert.equal(preflight.headers.get("Access-Control-Allow-Origin"), "*");
    assert(
      preflight.headers
        .get("Access-Control-Allow-Methods")
        .split(",")
        .map((value) => value.trim())
        .includes("POST"),
    );
    assert(
      preflight.headers
        .get("Access-Control-Allow-Headers")
        .split(",")
        .map((value) => value.trim().toLowerCase())
        .includes("content-type"),
    );
    const namespace = await mf.getDurableObjectNamespace("REPORT_QUOTA");
    const quota = namespace.get(namespace.idFromName("daily"));
    const today = fixtureDay;
    const seed = (value, kind = "daily") =>
      quota.fetch(`https://quota/seed?kind=${kind}`, {
        method: "POST",
        body: JSON.stringify(value),
      });
    const inspect = async (kind = "daily") =>
      (await quota.fetch(`https://quota/inspect?kind=${kind}`)).json();
    const send = (value, ip = "192.0.2.1") =>
      mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
        method: "POST",
        headers: { "CF-Connecting-IP": ip, "x-bit101-network-smoke": "1" },
        body: JSON.stringify(value),
      });
    await checkRejectedReports(mf, today, seed, send);
    await checkReportSizeLimits(mf, inspect, send);
    const { kv, attachmentKey } = await checkStoredAttachments(mf, send);
    await checkConcurrentQuotas(today, seed, inspect, send, kv);
    await checkReportDeletion(mf, today, seed, send, kv, attachmentKey);
  } finally {
    await mf.dispose();
  }
  for (const limit of ["150", "0", "invalid"]) {
    const configured = new Miniflare(
      convertV4MiniflareOptions({
        name: "worker-fixture",
        modules: true,
        script: fixture,
        compatibilityDate: config.compatibility_date,
        bindings: { REPORT_SOURCE_DAILY_LIMIT: limit },
        durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true } },
        log: new Log(LogLevel.NONE),
      }),
    );
    try {
      const namespace = await configured.getDurableObjectNamespace("REPORT_QUOTA");
      const quota = namespace.get(namespace.idFromName("daily"));
      const day = fixtureDay;
      await quota.fetch("https://quota/seed", {
        method: "POST",
        body: JSON.stringify({ day, count: 149, sources: { fixture: 149 } }),
      });
      const reserve = () =>
        quota.fetch("https://quota/reserve", {
          method: "POST",
          body: JSON.stringify({ source: "fixture", smoke: false }),
        });
      const first = await reserve();
      if (limit === "150") {
        assert.equal((await first.json()).allowed, true);
        assert.equal((await (await reserve()).json()).error, "source_limit_reached");
        await quota.fetch("https://quota/seed", {
          method: "POST",
          body: JSON.stringify({ day, count: 1000 }),
        });
        assert.equal((await (await reserve()).json()).error, "daily_limit_reached");
      } else {
        assert.equal(first.status, 503);
        assert.equal((await first.json()).error, "invalid_source_quota");
      }
    } finally {
      await configured.dispose();
    }
  }
  await checkMailRuntime(config);
}

async function checkRejectedReports(mf, today, seed, send) {
  await seed({ day: today, count: 0 });
  for (const value of [
    {},
    [],
    { mode: "unknown" },
    { mode: "sanitized" },
    { mode: "suggestion", comment: " " },
    { mode: "network-smoke", runID: "" },
    { mode: "network-smoke", runID: "wrong/value" },
    ...[{}, [null], [1], [[]]].map((diagnostics) => ({
      mode: "suggestion",
      comment: "fixture",
      diagnostics,
    })),
  ]) {
    assert.equal((await send(value)).status, 400);
  }
  for (const [errorTitle, errorMessage] of [
    ["登录失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],
    ["身份验证失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],
    ["加载话廊失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],
    ["学校认证通道异常", "101 的学校认证通道暂时无法连接 WebVPN。"],
    ["课表同步失败", "认证信息无效。 [status=401, risk=ustc-token, flow=replaced]"],
    ["学校账号已锁定", "学校统一认证提示账号已被锁定。"],
    ["学校认证受限", "学校统一认证拒绝了本次认证请求。"],
    ["课表同步失败", "账号被锁定 (code: 1030028) [risk=error-fallback, flow=replaced]"],
    ["学期列表加载失败", "您的会话已经过期，请重新登录"],
    ["验证已失效", "jxzxehall: 解析 service url 失败"],
    ["课表同步失败", "学校教务服务返回“无权访问该资源”"],
    ["学校服务连接失败", "学校统一认证服务暂时无法建立安全连接，请稍后重试。"],
    ["课表同步失败", "学校教务服务暂时无法恢复会话，请稍后重试。"],
  ]) {
    for (const mode of ["raw", "sanitized"]) {
      const result = await send({ mode, errorTitle, errorMessage });
      assert.equal(result.status, 422);
      assert.equal((await result.json()).error, "school_service_issue");
    }
  }
  assert.equal(
    (await (await mf.getKVNamespace("ERROR_REPORTS")).list({ prefix: "report:" })).keys.length,
    0,
  );
  for (const [errorTitle, errorMessage] of [
    ["DDL 同步失败", "课表缓存读取受阻"],
    ["课表同步失败", "服务器返回了无法识别的数据"],
    ["加载话廊失败", "服务器响应异常（HTTP 500）：数据库错误Orz"],
    ["登录失败", "当前会话已过期"],
  ]) {
    const result = await send({
      mode: "raw",
      errorTitle,
      errorMessage,
      attachments: [{ data: "==" }],
    });
    assert.equal(result.status, 400);
    assert.equal((await result.json()).error, "invalid_attachment");
  }
  for (const contentType of [[], {}, 5]) {
    assert.equal(
      (
        await send({
          mode: "suggestion",
          comment: "fixture",
          attachments: [{ data: "QQ==", contentType }],
        })
      ).status,
      400,
    );
  }
}

async function checkReportSizeLimits(mf, inspect, send) {
  const deep = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
    method: "POST",
    body:
      '{"mode":"suggestion","comment":"fixture","extra":' +
      "[".repeat(5000) +
      "null" +
      "]".repeat(5000) +
      "}",
  });
  assert.equal(deep.status, 400);
  assert.equal(
    (await send({ mode: "suggestion", comment: "x".repeat(2 * 1024 * 1024) })).status,
    413,
  );
  for (const fields of [
    { name: "x".repeat(2 * 1024 * 1024) },
    { contentType: "x".repeat(2 * 1024 * 1024) },
    { details: { description: "x".repeat(2 * 1024 * 1024) } },
  ]) {
    const response = await send({
      mode: "suggestion",
      comment: "fixture",
      attachments: [{ data: "AAAA", ...fields }],
    });
    assert.equal(response.status, 413);
    assert.equal((await response.json()).error, "metadata_too_large");
  }
  const combinedMetadata = await send({
    mode: "suggestion",
    comment: "fixture",
    attachments: [
      { data: "AAAA", name: "x".repeat(600 * 1024) },
      { data: "AAAA", name: "x".repeat(600 * 1024) },
    ],
  });
  assert.equal(combinedMetadata.status, 413);
  assert.equal((await combinedMetadata.json()).error, "metadata_too_large");
  assert.equal((await inspect()).count, 0);
  for (const data of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!", "A==="]) {
    assert.equal(
      (await send({ mode: "network-smoke", runID: "invalid-base64", attachments: [{ data }] }))
        .status,
      400,
    );
  }
  assert.equal(
    (
      await send({
        mode: "network-smoke",
        runID: "maximum",
        attachments: Array.from({ length: 6 }, () => ({
          data: Buffer.alloc(2 * 1024 * 1024).toString("base64"),
        })),
      })
    ).status,
    201,
  );
}

async function checkStoredAttachments(mf, send) {
  const kv = await mf.getKVNamespace("ERROR_REPORTS");
  const binary = "ApwdAA==";
  const attachmentResponse = await send({
    mode: "suggestion",
    comment: "password=fixture-secret",
    attachments: [
      { data: binary, name: "password=attachment-secret", contentType: "application/octet-stream" },
    ],
  });
  assert.equal(attachmentResponse.status, 201);
  const attachmentID = (await attachmentResponse.json()).id;
  const attachmentKey = (await kv.list()).keys.find((key) => key.name.endsWith(attachmentID)).name;
  const savedAttachment = JSON.parse(await kv.get(attachmentKey)).report;
  assert.equal(savedAttachment.attachments[0].data, binary);
  assert.deepEqual(
    Buffer.from(savedAttachment.attachments[0].data, "base64"),
    Buffer.from(binary, "base64"),
  );
  assert(!savedAttachment.comment.includes("fixture-secret"));
  assert(!savedAttachment.attachments[0].name.includes("attachment-secret"));
  assert.equal(
    (
      await send({
        mode: "sanitized",
        errorTitle: "fixture",
        errorMessage: "fixture",
        build: { toString: null },
      })
    ).status,
    400,
  );
  for (const title of ["x".repeat(1100), "\u0000".repeat(1100), "𐐀".repeat(1100)]) {
    const response = await send({
      mode: "sanitized",
      errorTitle: title,
      errorMessage: "fixture",
      appVersion: "\u0000".repeat(1100),
      build: "1",
    });
    assert.equal(response.status, 201);
    const id = (await response.json()).id;
    const row = (await kv.list()).keys.find((key) => key.name.endsWith(id));
    assert(Buffer.byteLength(JSON.stringify(row.metadata)) <= 1024);
    assert.equal(JSON.parse(await kv.get(row.name)).report.errorTitle, title);
  }
  return { kv, attachmentKey };
}

async function checkConcurrentQuotas(today, seed, inspect, send, kv) {
  await seed({ day: today, count: 0 });
  const requestID = crypto.randomUUID();
  const identical = {
    mode: "suggestion",
    comment: "账号被锁定 (code:1030028)，希望改进认证提示。",
    errorTitle: "学校账号已锁定",
    errorMessage: "账号被锁定 (code:1030028)",
    requestID,
  };
  const receipts = await Promise.all(Array.from({ length: 5 }, () => send(identical)));
  for (const response of receipts) {
    assert.equal(response.status, 201);
    assert.equal((await response.json()).id, requestID);
  }
  assert.equal((await inspect()).count, 1);
  assert.equal((await kv.list()).keys.filter((key) => key.name.endsWith(requestID)).length, 1);
  assert.equal((await send({ ...identical, comment: "changed" })).status, 409);
  assert.equal((await send({ ...identical, requestID: "invalid" })).status, 400);
  assert.equal((await inspect()).count, 1);
  const source = Object.keys((await inspect()).sources)[0];
  assert(/^[a-f0-9]{64}$/.test(source));
  await seed({ day: today, count: 99, sources: { [source]: 99 } });
  const concurrent = () =>
    Promise.all(Array.from({ length: 5 }, () => send({ mode: "suggestion", comment: "fixture" })));
  const sourceResponses = await concurrent();
  assert.equal(sourceResponses.filter((response) => response.status === 201).length, 1);
  assert.equal(sourceResponses.filter((response) => response.status === 429).length, 4);
  assert.equal(
    (await sourceResponses.find((response) => response.status === 429).json()).error,
    "source_limit_reached",
  );
  assert.equal((await send({ mode: "suggestion", comment: "fixture" }, "192.0.2.2")).status, 201);
  await seed({ day: today, count: 999 });
  const responses = await concurrent();
  assert.equal(responses.filter((response) => response.status === 201).length, 1);
  assert.equal(responses.filter((response) => response.status === 429).length, 4);
  assert.equal((await inspect()).count, 1000);
  const nextDay = await send({ mode: "network-smoke", runID: "fixture" });
  assert.equal(nextDay.status, 201);
  assert.deepEqual(await nextDay.json(), {
    ok: true,
    recordVerified: true,
    temporaryRecordRemoved: true,
    quotaReserved: true,
  });
  await seed({ day: today, count: 1000 }, "smoke");
  assert.equal((await send({ mode: "network-smoke", runID: "fixture" })).status, 429);
  await seed({ day: "2000-01-01", count: 1000 });
  assert.equal((await send({ mode: "suggestion", comment: "fixture" })).status, 201);
  assert.equal((await inspect()).count, 1);
  assert((await kv.list()).keys.every((key) => key.name.startsWith("report:")));
  await seed({ day: today, count: 2000 }, "admission");
  assert.equal((await send({ mode: "suggestion", comment: "quota fixture" })).status, 429);
}

async function checkReportDeletion(mf, today, seed, send, kv, attachmentKey) {
  const grant = crypto.randomUUID();
  const grantKey = `report-delete-grant:${grant}`;
  const remove = (value = grant) =>
    mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
      method: "DELETE",
      headers: { "CF-Connecting-IP": "192.0.2.1" },
      body: JSON.stringify({ key: attachmentKey, grant: value }),
    });
  const oversizedDeleteBody = "{}".padEnd(1024 + 1);
  for (const declaredLength of [false, true]) {
    const headers = { "CF-Connecting-IP": "192.0.2.1" };
    if (declaredLength) headers["content-length"] = String(Buffer.byteLength(oversizedDeleteBody));
    const body = declaredLength
      ? oversizedDeleteBody
      : new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(oversizedDeleteBody));
            controller.close();
          },
        });
    assert.equal(
      (
        await mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
          method: "DELETE",
          headers,
          body,
          duplex: "half",
        })
      ).status,
      413,
    );
  }
  assert.equal(
    (
      await mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
        method: "DELETE",
        headers: { "CF-Connecting-IP": "192.0.2.1" },
        body: JSON.stringify({ key: attachmentKey, grant }).padEnd(1024),
      })
    ).status,
    403,
  );
  await kv.put(grantKey, JSON.stringify({ key: "report:mismatched" }));
  assert.equal((await remove()).status, 403);
  await kv.put(grantKey, JSON.stringify({ key: attachmentKey }));
  assert.equal((await remove()).status, 200);
  assert.equal(await kv.get(attachmentKey), null);
  assert.equal(await kv.get(grantKey), null);
  assert.equal((await remove()).status, 403);
  assert.equal((await send({ mode: "suggestion", comment: "quota fixture" })).status, 429);
  await seed({ day: today, count: 2000 }, "deletion-admission");
  assert.equal((await remove()).status, 429);
  await seed({ day: today, count: 0 }, "admission");
  assert.equal((await send({ mode: "suggestion", comment: "independent admission" })).status, 201);
}

async function checkMailRuntime(config) {
  const mailFixture =
    fs.readFileSync("../ErrorReportWorker/worker.js", "utf8") +
    `
export class DeliveryFixture extends ReportEmailDelivery {
  async fetch(request) {
    if (new URL(request.url).pathname === "/inspect") {
      return Response.json({
        job: await this.ctx.storage.get("job"), alarm: await this.ctx.storage.getAlarm()
      });
    }
    if (new URL(request.url).pathname === "/wake") {
      await this.ctx.storage.setAlarm(Date.now()); return new Response(null, { status: 204 });
    }
    return super.fetch(request);
  }
}`;
  const mail = new Miniflare(
    convertV4MiniflareOptions({
      workers: [
        {
          name: "email-acceptance",
          modules: true,
          script: mailFixture,
          compatibilityDate: config.compatibility_date,
          kvNamespaces: ["ERROR_REPORTS"],
          bindings: config.vars,
          serviceBindings: { REPORT_EMAIL: "mail-fixture" },
          durableObjects: {
            REPORT_QUOTA: { className: "ReportQuota", useSQLite: true },
            REPORT_EMAIL_DELIVERY: { className: "DeliveryFixture", useSQLite: true },
          },
        },
        {
          name: "mail-fixture",
          modules: true,
          compatibilityDate: config.compatibility_date,
          kvNamespaces: ["MAIL_STATUS"],
          script: `
import { WorkerEntrypoint } from "cloudflare:workers";
export default class extends WorkerEntrypoint {
  async send(message) {
    const count = Number(await this.env.MAIL_STATUS.get("attempts") || 0) + 1;
    await this.env.MAIL_STATUS.put("attempts", String(count));
    if (await this.env.MAIL_STATUS.get("offline") === "1") throw new Error("fixture offline");
    await this.env.MAIL_STATUS.put(
      "delivered", String(Number(await this.env.MAIL_STATUS.get("delivered") || 0) + 1));
    return { messageId: "runtime-receipt" };
  }
}`,
        },
      ],
      log: new Log(LogLevel.NONE),
    }),
  );
  try {
    const status = await mail.getKVNamespace("MAIL_STATUS", "mail-fixture");
    await status.put("offline", "1");
    const runtimeReport = {
      mode: "suggestion",
      comment: "runtime fixture",
      requestID: crypto.randomUUID(),
    };
    const accept = (value) =>
      mail.dispatchFetch("https://feedback.invalid/api/error-reports", {
        method: "POST",
        headers: { "CF-Connecting-IP": "192.0.2.1" },
        body: JSON.stringify(value),
      });
    const accepted = await accept(runtimeReport);
    assert.equal(accepted.status, 201);
    const id = (await accepted.json()).id;
    const repeated = await accept({
      requestID: runtimeReport.requestID.toUpperCase(),
      comment: runtimeReport.comment,
      mode: runtimeReport.mode,
    });
    assert.equal(repeated.status, 201);
    assert.equal((await repeated.json()).id, id);
    const namespace = await mail.getDurableObjectNamespace(
      "REPORT_EMAIL_DELIVERY",
      "email-acceptance",
    );
    const identifier = namespace.idFromName(id),
      delivery = namespace.get(identifier);
    const inspect = async () => (await delivery.fetch("https://delivery/inspect")).json();
    const until = async (predicate) => {
      const deadline = Date.now() + 10000;
      while (!(await predicate())) {
        assert(Date.now() < deadline, "Runtime alarm deadline");
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    };
    await until(async () => Number(await status.get("attempts")) > 0);
    await until(async () => (await inspect()).job.delivery.attempts > 0);
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", {
      id: identifier.toString(),
    });
    assert.equal((await inspect()).job.delivery.status, "pending");
    await status.put("offline", "0");
    await delivery.fetch("https://delivery/wake", { method: "POST" });
    await until(async () => (await inspect()).job.delivery.status === "sent");
    const record = (await inspect()).job;
    assert.equal(record.delivery.messageID, "runtime-receipt");
    const reports = await mail.getKVNamespace("ERROR_REPORTS", "email-acceptance");
    assert.equal((await reports.list()).keys.length, 1);
    await until(
      async () => JSON.parse(await reports.get(record.key)).emailDelivery.status === "sent",
    );
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", {
      id: identifier.toString(),
    });
    assert.equal((await inspect()).job.delivery.status, "sent");
    await delivery.fetch("https://delivery/wake", { method: "POST" });
    await until(async () => (await inspect()).alarm > Date.now() + 10000);
    assert.equal(await status.get("delivered"), "1");
    assert.equal(
      (
        await delivery.fetch("https://delivery/delete", {
          method: "DELETE",
          body: JSON.stringify({ key: record.key }),
        })
      ).status,
      200,
    );
    await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", {
      id: identifier.toString(),
    });
    assert.equal((await inspect()).job.deleted, true);
    assert.equal(await reports.get(record.key), null);
  } finally {
    await mail.dispose();
  }
}

module.exports = { runRuntimeTests };
