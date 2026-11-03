"""Exercise deployed Worker contracts in the local Workers runtime."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def emergency_notice_identity_self_test() -> None:
    import json, sys
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    source = (
        ROOT / "Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh"
    ).read_text()
    stub = source.replace(
        'source "$ROOT_DIR/../../Scripts/script-support.sh"',
        "bit101_acquire_script_lock() { exit 91; }",
    )
    for arguments, expected in [
        (["--help"], 0),
        ([], 64),
        (["-1", "title", "body"], 64),
        (["1", " ", "body"], 64),
        (["9007199254740992", "title", "body"], 64),
        (["--disable"], 91),
        (["1", "title", "body"], 91),
    ]:
        result = subprocess.run(
            [
                "zsh",
                "-c",
                stub,
                str(ROOT / "Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh"),
                *arguments,
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == expected, (arguments, result.stderr)
    body = source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    identities = []
    for build, title, message in [
        ("41", "公告", "正文"),
        ("41", "公告", "正文"),
        ("41", "新公告", "正文"),
        ("41", "公告", "新正文"),
        ("42", "公告", "正文"),
    ]:
        output, console = StringIO(), StringIO()
        with (
            patch.object(sys, "argv", ["publish", "/fixture/notice.json", build, title, message]),
            patch("builtins.open", return_value=nullcontext(output)),
            redirect_stdout(console),
        ):
            exec(compile(body, "emergency-notice-payload", "exec"), {})
        payload = json.loads(output.getvalue())
        assert payload["notice_id"] == console.getvalue().strip() and payload[
            "maximum_affected_build"
        ] == int(build)
        identities.append(payload["notice_id"])
    assert identities[0] == identities[1] and len(set(identities)) == 4


def worker_boundary_findings() -> list[str]:
    "通过 Workers 本地 runtime 验证跨域预检、并发配额及 Smoke 约束。"
    emergency_notice_identity_self_test()
    script = (
        '\nconst assert = require("node:assert/strict");\nconst fs = require("node:fs");\nconst { '
        'Miniflare, Log, LogLevel, convertV4MiniflareOptions } = require("miniflare");\nconst { ex'
        'perimental_readRawConfig } = require("wrangler");\n(async () => {\n  const config = exper'
        'imental_readRawConfig({ config: "../ErrorReportWorker/wrangler.jsonc" }).rawConfig;\n  as'
        "sert.equal(config.vars.REPORT_EMAIL_RECIPIENT, config.send_email.find(binding => binding."
        'name === "REPORT_EMAIL").destination_address);\n  assert(config.durable_objects.bindings.'
        'some(binding => binding.name === "REPORT_QUOTA" && binding.class_name === "ReportQuota"))'
        ';\n  assert(config.migrations.some(migration => migration.new_sqlite_classes.includes("Re'
        'portQuota")));\n  assert(config.durable_objects.bindings.some(binding => binding.name ==='
        ' "REPORT_EMAIL_DELIVERY" && binding.class_name === "ReportEmailDelivery"));\n  assert(con'
        'fig.migrations.some(migration => migration.new_sqlite_classes.includes("ReportEmailDelive'
        'ry")));\n  const fixtureDay = "2026-01-01";\n  const workerSource = fs.readFileSync("../E'
        'rrorReportWorker/worker.js", "utf8");\n  const dayExpression = "new Date().toISOString().'
        'slice(0, 10)";\n  assert(workerSource.includes(dayExpression));\n  const fixture = worker'
        "Source.replace(dayExpression, JSON.stringify(fixtureDay)) + `\nexport class QuotaFixture "
        "extends ReportQuota {\n  async fetch(request) {\n    if (new URL(request.url).pathname =="
        '= "/seed") {\n      this.ctx.storage.kv.put(new URL(request.url).searchParams.get("kind")'
        ' || "daily", await request.json());\n      return new Response(null, { status: 204 });\n '
        '   }\n    if (new URL(request.url).pathname === "/inspect") return Response.json(this.ctx'
        '.storage.kv.get(new URL(request.url).searchParams.get("kind") || "daily"));\n    return s'
        "uper.fetch(request);\n  }\n}`;\n  const mf = new Miniflare(convertV4MiniflareOptions({ na"
        'me: "worker-fixture", modules: true, script: fixture,\n    compatibilityDate: config.comp'
        'atibility_date, kvNamespaces: ["ERROR_REPORTS"],\n    durableObjects: { REPORT_QUOTA: { c'
        'lassName: "QuotaFixture", useSQLite: true },\n      REPORT_EMAIL_DELIVERY: { className: "'
        'ReportEmailDelivery", useSQLite: true } },\n    log: new Log(LogLevel.NONE) }));\n  try {'
        '\n    const preflight = await mf.dispatchFetch("https://feedback.invalid/api/error-report'
        's", { method: "OPTIONS",\n      headers: { Origin: "https://bit101.cn", "Access-Control-R'
        'equest-Method": "POST", "Access-Control-Request-Headers": "content-type" } });\n    asser'
        't.equal(preflight.status, 204);\n    assert.equal(await preflight.text(), "");\n    asser'
        't.equal(preflight.headers.get("Access-Control-Allow-Origin"), "*");\n    assert(preflight'
        '.headers.get("Access-Control-Allow-Methods").split(",").map(value => value.trim()).includ'
        'es("POST"));\n    assert(preflight.headers.get("Access-Control-Allow-Headers").split(",")'
        '.map(value => value.trim().toLowerCase()).includes("content-type"));\n    const namespace'
        ' = await mf.getDurableObjectNamespace("REPORT_QUOTA");\n    const quota = namespace.get(n'
        'amespace.idFromName("daily"));\n    const today = fixtureDay;\n    const seed = (value, k'
        'ind = "daily") => quota.fetch(`https://quota/seed?kind=${kind}`, { method: "POST", body: '
        'JSON.stringify(value) });\n    const inspect = async (kind = "daily") => (await quota.fet'
        'ch(`https://quota/inspect?kind=${kind}`)).json();\n    const send = (value, ip = "192.0.2'
        '.1") => mf.dispatchFetch("https://feedback.invalid/api/error-reports", {\n      method: "'
        'POST", headers: { "CF-Connecting-IP": ip, "x-bit101-network-smoke": "1" }, body: JSON.str'
        "ingify(value) });\n    await seed({ day: today, count: 0 });\n    for (const value of [{}"
        ', [], { mode: "unknown" }, { mode: "sanitized" }, { mode: "suggestion", comment: " " },\n'
        '                         { mode: "network-smoke", runID: "" }, { mode: "network-smoke", r'
        'unID: "wrong/value" },\n                         ...[{}, [null], [1], [[]]].map(diagnosti'
        'cs => ({ mode: "suggestion", comment: "fixture", diagnostics }))]) {\n      assert.equal('
        "(await send(value)).status, 400);\n    }\n    for (const [errorTitle, errorMessage] of ["
        '\n      ["登录失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],\n      ["身份验证失败", "服务器响应异常（HTTP 5'
        '00）：初始化WebVPN验证失败Orz"],\n      ["加载话廊失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],\n      ['
        '"学校认证通道异常", "101 的学校认证通道暂时无法连接 WebVPN。"],\n      ["课表同步失败", "认证信息无效。 [status=401, risk=us'
        'tc-token, flow=replaced]"],\n      ["学校账号已锁定", "学校统一认证提示账号已被锁定。"],\n      ["学校认证受限", "学校统'
        '一认证拒绝了本次认证请求。"],\n      ["课表同步失败", "账号被锁定 (code: 1030028) [risk=error-fallback, flow=repl'
        'aced]"],\n      ["学期列表加载失败", "您的会话已经过期，请重新登录"],\n      ["验证已失效", "jxzxehall: 解析 service u'
        'rl 失败"],\n      ["课表同步失败", "学校教务服务返回“无权访问该资源”"],\n      ["学校服务连接失败", "学校统一认证服务暂时无法建立安全连接，'
        '请稍后重试。"],\n      ["课表同步失败", "学校教务服务暂时无法恢复会话，请稍后重试。"]\n    ]) {\n      for (const mode of '
        '["raw", "sanitized"]) {\n        const result = await send({ mode, errorTitle, errorMessa'
        "ge });\n        assert.equal(result.status, 422); assert.equal((await result.json()).erro"
        'r, "school_service_issue");\n      }\n    }\n    assert.equal((await (await mf.getKVNames'
        'pace("ERROR_REPORTS")).list({ prefix: "report:" })).keys.length, 0);\n    for (const [err'
        'orTitle, errorMessage] of [["DDL 同步失败", "课表缓存读取受阻"],\n      ["课表同步失败", "服务器返回了无法识别的数据"], '
        '["加载话廊失败", "服务器响应异常（HTTP 500）：数据库错误Orz"],\n      ["登录失败", "当前会话已过期"]]) {\n      const res'
        'ult = await send({ mode: "raw", errorTitle, errorMessage, attachments: [{ data: "==" }] }'
        ');\n      assert.equal(result.status, 400); assert.equal((await result.json()).error, "in'
        'valid_attachment");\n    }\n    for (const contentType of [[], {}, 5]) {\n      assert.eq'
        'ual((await send({ mode: "suggestion", comment: "fixture", attachments: [{ data: "QQ==", c'
        'ontentType }] })).status, 400);\n    }\n    const deep = await mf.dispatchFetch("https://'
        'feedback.invalid/api/error-reports", { method: "POST", body: \'{"mode":"suggestion","comm'
        "ent\":\"fixture\",\"extra\":' + '['.repeat(5000) + 'null' + ']'.repeat(5000) + '}' })"
        ';\n    assert.equal(deep.status, 400);\n    assert.equal((await send({ mode: "suggestion"'
        ', comment: "x".repeat(2 * 1024 * 1024) })).status, 413);\n    for (const fields of [{ nam'
        'e: "x".repeat(2 * 1024 * 1024) },\n                         { contentType: "x".repeat(2 *'
        ' 1024 * 1024) },\n                         { details: { description: "x".repeat(2 * 1024 '
        '* 1024) } }]) {\n      const response = await send({ mode: "suggestion", comment: "fixtur'
        'e", attachments: [{ data: "AAAA", ...fields }] });\n      assert.equal(response.status, 4'
        '13);\n      assert.equal((await response.json()).error, "metadata_too_large");\n    }\n  '
        '  const combinedMetadata = await send({ mode: "suggestion", comment: "fixture",\n      at'
        'tachments: [{ data: "AAAA", name: "x".repeat(600 * 1024) }, { data: "AAAA", name: "x".rep'
        "eat(600 * 1024) }] });\n    assert.equal(combinedMetadata.status, 413);\n    assert.equal"
        '((await combinedMetadata.json()).error, "metadata_too_large");\n    assert.equal((await i'
        'nspect()).count, 0);\n    for (const data of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!",'
        ' "A==="]) {\n      assert.equal((await send({ mode: "network-smoke", runID: "invalid-base'
        '64", attachments: [{ data }] })).status, 400);\n    }\n    assert.equal((await send({ mod'
        'e: "network-smoke", runID: "maximum",\n      attachments: Array.from({ length: 6 }, () =>'
        ' ({ data: Buffer.alloc(2 * 1024 * 1024).toString("base64") })) })).status, 201);\n    con'
        'st kv = await mf.getKVNamespace("ERROR_REPORTS");\n    const binary = "ApwdAA==";\n    co'
        'nst attachmentResponse = await send({ mode: "suggestion", comment: "password=fixture-secr'
        'et",\n      attachments: [{ data: binary, name: "password=attachment-secret", contentType'
        ': "application/octet-stream" }] });\n    assert.equal(attachmentResponse.status, 201);\n '
        "   const attachmentID = (await attachmentResponse.json()).id;\n    const attachmentKey = "
        "(await kv.list()).keys.find(key => key.name.endsWith(attachmentID)).name;\n    const save"
        "dAttachment = JSON.parse(await kv.get(attachmentKey)).report;\n    assert.equal(savedAtta"
        "chment.attachments[0].data, binary);\n    assert.deepEqual(Buffer.from(savedAttachment.at"
        'tachments[0].data, "base64"), Buffer.from(binary, "base64"));\n    assert(!savedAttachmen'
        't.comment.includes("fixture-secret"));\n    assert(!savedAttachment.attachments[0].name.i'
        'ncludes("attachment-secret"));\n    assert.equal((await send({ mode: "sanitized", errorTi'
        'tle: "fixture", errorMessage: "fixture", build: { toString: null } })).status, 400);\n   '
        ' for (const title of ["x".repeat(1100), "\\u0000".repeat(1100), "🧪".repeat(1100)]) {\n   '
        '   const response = await send({ mode: "sanitized", errorTitle: title, errorMessage: "fix'
        'ture",\n        appVersion: "\\u0000".repeat(1100), build: "1" });\n      assert.equal(re'
        "sponse.status, 201);\n      const id = (await response.json()).id;\n      const row = (aw"
        "ait kv.list()).keys.find(key => key.name.endsWith(id));\n      assert(Buffer.byteLength(J"
        "SON.stringify(row.metadata)) <= 1024);\n      assert.equal(JSON.parse(await kv.get(row.na"
        "me)).report.errorTitle, title);\n    }\n    await seed({ day: today, count: 0 });\n    co"
        'nst requestID = crypto.randomUUID();\n    const identical = { mode: "suggestion", comment'
        ': "账号被锁定 (code:1030028)，希望改进认证提示。",\n      errorTitle: "学校账号已锁定", errorMessage: "账号被锁定 (c'
        'ode:1030028)", requestID };\n    const receipts = await Promise.all(Array.from({ length: '
        "5 }, () => send(identical)));\n    for (const response of receipts) { assert.equal(respon"
        "se.status, 201); assert.equal((await response.json()).id, requestID); }\n    assert.equal"
        "((await inspect()).count, 1);\n    assert.equal((await kv.list()).keys.filter(key => key."
        "name.endsWith(requestID)).length, 1);\n    assert.equal((await send({ ...identical, comme"
        'nt: "changed" })).status, 409);\n    assert.equal((await send({ ...identical, requestID: '
        '"invalid" })).status, 400);\n    assert.equal((await inspect()).count, 1);\n    const sou'
        "rce = Object.keys((await inspect()).sources)[0];\n    assert(/^[a-f0-9]{64}$/.test(source"
        "));\n    await seed({ day: today, count: 99, sources: { [source]: 99 } });\n    const con"
        'current = () => Promise.all(Array.from({ length: 5 }, () => send({ mode: "suggestion", co'
        'mment: "fixture" })));\n    const sourceResponses = await concurrent();\n    assert.equal'
        "(sourceResponses.filter(response => response.status === 201).length, 1);\n    assert.equa"
        "l(sourceResponses.filter(response => response.status === 429).length, 4);\n    assert.equ"
        'al((await sourceResponses.find(response => response.status === 429).json()).error, "sourc'
        'e_limit_reached");\n    assert.equal((await send({ mode: "suggestion", comment: "fixture"'
        ' }, "192.0.2.2")).status, 201);\n    await seed({ day: today, count: 999 });\n    const r'
        "esponses = await concurrent();\n    assert.equal(responses.filter(response => response.st"
        "atus === 201).length, 1);\n    assert.equal(responses.filter(response => response.status "
        "=== 429).length, 4);\n    assert.equal((await inspect()).count, 1000);\n    const nextDay"
        ' = await send({ mode: "network-smoke", runID: "fixture" });\n    assert.equal(nextDay.sta'
        "tus, 201);\n    assert.deepEqual(await nextDay.json(), { ok: true, recordVerified: true, "
        "temporaryRecordRemoved: true, quotaReserved: true });\n    await seed({ day: today, count"
        ': 1000 }, "smoke");\n    assert.equal((await send({ mode: "network-smoke", runID: "fixtur'
        'e" })).status, 429);\n    await seed({ day: "2000-01-01", count: 1000 });\n    assert.equ'
        'al((await send({ mode: "suggestion", comment: "fixture" })).status, 201);\n    assert.equ'
        "al((await inspect()).count, 1);\n    assert((await kv.list()).keys.every(key => key.name."
        'startsWith("report:")));\n    await seed({ day: today, count: 2000 }, "admission");\n    '
        'assert.equal((await send({ mode: "suggestion", comment: "quota fixture" })).status, 429);'
        "\n    const grant = crypto.randomUUID();\n    const grantKey = `report-delete-grant:${gra"
        'nt}`;\n    const remove = (value = grant) => mf.dispatchFetch("https://feedback.invalid/a'
        'pi/error-reports", {\n      method: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" '
        "}, body: JSON.stringify({ key: attachmentKey, grant: value }) });\n    const oversizedDel"
        'eteBody = "{}".padEnd(1024 + 1);\n    for (const declaredLength of [false, true]) {\n    '
        '  const headers = { "CF-Connecting-IP": "192.0.2.1" };\n      if (declaredLength) headers'
        '["content-length"] = String(Buffer.byteLength(oversizedDeleteBody));\n      const body = '
        "declaredLength ? oversizedDeleteBody : new ReadableStream({ start(controller) {\n        "
        "controller.enqueue(new TextEncoder().encode(oversizedDeleteBody)); controller.close();\n "
        '     } });\n      assert.equal((await mf.dispatchFetch("https://feedback.invalid/api/erro'
        'r-reports", {\n        method: "DELETE", headers, body, duplex: "half" })).status, 413);'
        '\n    }\n    assert.equal((await mf.dispatchFetch("https://feedback.invalid/api/error-rep'
        'orts", {\n      method: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" },\n      bo'
        "dy: JSON.stringify({ key: attachmentKey, grant }).padEnd(1024) })).status, 403);\n    awa"
        'it kv.put(grantKey, JSON.stringify({ key: "report:mismatched" }));\n    assert.equal((awa'
        "it remove()).status, 403);\n    await kv.put(grantKey, JSON.stringify({ key: attachmentKe"
        "y }));\n    assert.equal((await remove()).status, 200);\n    assert.equal(await kv.get(at"
        "tachmentKey), null);\n    assert.equal(await kv.get(grantKey), null);\n    assert.equal(("
        'await remove()).status, 403);\n    assert.equal((await send({ mode: "suggestion", comment'
        ': "quota fixture" })).status, 429);\n    await seed({ day: today, count: 2000 }, "deletio'
        'n-admission");\n    assert.equal((await remove()).status, 429);\n    await seed({ day: to'
        'day, count: 0 }, "admission");\n    assert.equal((await send({ mode: "suggestion", commen'
        't: "independent admission" })).status, 201);\n  } finally { await mf.dispose(); }\n  for '
        '(const limit of ["150", "0", "invalid"]) {\n    const configured = new Miniflare(convertV'
        '4MiniflareOptions({ name: "worker-fixture", modules: true, script: fixture,\n      compat'
        "ibilityDate: config.compatibility_date, bindings: { REPORT_SOURCE_DAILY_LIMIT: limit },\n"
        '      durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true } }, l'
        "og: new Log(LogLevel.NONE) }));\n    try {\n      const namespace = await configured.getD"
        'urableObjectNamespace("REPORT_QUOTA");\n      const quota = namespace.get(namespace.idFro'
        'mName("daily"));\n      const day = fixtureDay;\n      await quota.fetch("https://quota/s'
        'eed", { method: "POST", body: JSON.stringify({ day, count: 149, sources: { fixture: 149 }'
        ' }) });\n      const reserve = () => quota.fetch("https://quota/reserve", { method: "POST'
        '", body: JSON.stringify({ source: "fixture", smoke: false }) });\n      const first = awa'
        'it reserve();\n      if (limit === "150") {\n        assert.equal((await first.json()).al'
        'lowed, true);\n        assert.equal((await (await reserve()).json()).error, "source_limit'
        '_reached");\n        await quota.fetch("https://quota/seed", { method: "POST", body: JSON'
        ".stringify({ day, count: 1000 }) });\n        assert.equal((await (await reserve()).json("
        ')).error, "daily_limit_reached");\n      } else {\n        assert.equal(first.status, 503'
        ');\n        assert.equal((await first.json()).error, "invalid_source_quota");\n      }\n '
        "   } finally { await configured.dispose(); }\n  }\n  const mailFixture = fs.readFileSync("
        '"../ErrorReportWorker/worker.js", "utf8") + `\nexport class DeliveryFixture extends Repor'
        'tEmailDelivery {\n  async fetch(request) {\n    if (new URL(request.url).pathname === "/i'
        'nspect") {\n      return Response.json({ job: await this.ctx.storage.get("job"), alarm: a'
        'wait this.ctx.storage.getAlarm() });\n    }\n    if (new URL(request.url).pathname === "/'
        'wake") {\n      await this.ctx.storage.setAlarm(Date.now()); return new Response(null, { '
        "status: 204 });\n    }\n    return super.fetch(request);\n  }\n}`;\n  const mail = new Mi"
        'niflare(convertV4MiniflareOptions({ workers: [\n    { name: "email-acceptance", modules: '
        "true, script: mailFixture, compatibilityDate: config.compatibility_date,\n      kvNamespa"
        'ces: ["ERROR_REPORTS"], bindings: config.vars, serviceBindings: { REPORT_EMAIL: "mail-fix'
        'ture" }, durableObjects: {\n        REPORT_QUOTA: { className: "ReportQuota", useSQLite: '
        'true },\n        REPORT_EMAIL_DELIVERY: { className: "DeliveryFixture", useSQLite: true }'
        ' } },\n    { name: "mail-fixture", modules: true, compatibilityDate: config.compatibility'
        '_date, kvNamespaces: ["MAIL_STATUS"], script: `\nimport { WorkerEntrypoint } from "cloudf'
        'lare:workers";\nexport default class extends WorkerEntrypoint {\n  async send(message) {'
        '\n    const count = Number(await this.env.MAIL_STATUS.get("attempts") || 0) + 1;\n    awa'
        'it this.env.MAIL_STATUS.put("attempts", String(count));\n    if (await this.env.MAIL_STAT'
        'US.get("offline") === "1") throw new Error("fixture offline");\n    await this.env.MAIL_S'
        'TATUS.put("delivered", String(Number(await this.env.MAIL_STATUS.get("delivered") || 0) + '
        '1));\n    return { messageId: "runtime-receipt" };\n  }\n}` }\n  ], log: new Log(LogLevel'
        '.NONE) }));\n  try {\n    const status = await mail.getKVNamespace("MAIL_STATUS", "mail-f'
        'ixture");\n    await status.put("offline", "1");\n    const runtimeReport = { mode: "sugg'
        'estion", comment: "runtime fixture", requestID: crypto.randomUUID() };\n    const accept '
        '= value => mail.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "PO'
        'ST",\n      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify(value) });'
        "\n    const accepted = await accept(runtimeReport);\n    assert.equal(accepted.status, 20"
        "1);\n    const id = (await accepted.json()).id;\n    const repeated = await accept({ requ"
        "estID: runtimeReport.requestID.toUpperCase(), comment: runtimeReport.comment, mode: runti"
        "meReport.mode });\n    assert.equal(repeated.status, 201); assert.equal((await repeated.j"
        'son()).id, id);\n    const namespace = await mail.getDurableObjectNamespace("REPORT_EMAIL'
        '_DELIVERY", "email-acceptance");\n    const identifier = namespace.idFromName(id), delive'
        'ry = namespace.get(identifier);\n    const inspect = async () => (await delivery.fetch("h'
        'ttps://delivery/inspect")).json();\n    const until = async predicate => {\n      const d'
        "eadline = Date.now() + 10000;\n      while (!(await predicate())) { assert(Date.now() < d"
        'eadline, "Runtime alarm deadline"); await new Promise(resolve => setTimeout(resolve, 20))'
        '; }\n    };\n    await until(async () => Number(await status.get("attempts")) > 0);\n    '
        "await until(async () => (await inspect()).job.delivery.attempts > 0);\n    await mail.uns"
        'afeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identifier.toString() '
        '});\n    assert.equal((await inspect()).job.delivery.status, "pending");\n    await statu'
        's.put("offline", "0");\n    await delivery.fetch("https://delivery/wake", { method: "POST'
        '" });\n    await until(async () => (await inspect()).job.delivery.status === "sent");\n  '
        '  const record = (await inspect()).job;\n    assert.equal(record.delivery.messageID, "run'
        'time-receipt");\n    const reports = await mail.getKVNamespace("ERROR_REPORTS", "email-ac'
        'ceptance");\n    assert.equal((await reports.list()).keys.length, 1);\n    await until(as'
        'ync () => JSON.parse(await reports.get(record.key)).emailDelivery.status === "sent");\n  '
        '  await mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identi'
        'fier.toString() });\n    assert.equal((await inspect()).job.delivery.status, "sent");\n  '
        '  await delivery.fetch("https://delivery/wake", { method: "POST" });\n    await until(asy'
        "nc () => (await inspect()).alarm > Date.now() + 10000);\n    assert.equal(await status.ge"
        't("delivered"), "1");\n    assert.equal((await delivery.fetch("https://delivery/delete", '
        '{ method: "DELETE", body: JSON.stringify({ key: record.key }) })).status, 200);\n    awai'
        't mail.unsafeEvictDurableObject("email-acceptance", "DeliveryFixture", { id: identifier.t'
        "oString() });\n    assert.equal((await inspect()).job.deleted, true);\n    assert.equal(a"
        "wait reports.get(record.key), null);\n  } finally { await mail.dispose(); }\n  const body"
        'Source = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8")\n    .replace(\'import'
        " { DurableObject } from \"cloudflare:workers\";', 'class DurableObject { constructor(ctx,"
        " env) { this.ctx = ctx; this.env = env; } }') + \"\\nexport { readReportBody, MAX_BODY_BY"
        "TES, forceRedact, decodedPercent, PROTECTED_NAMES, reportEmailSubject, reportEmailBody };"
        '";\n  const { default: feedback, ReportEmailDelivery, ReportQuota, readReportBody, MAX_BO'
        "DY_BYTES, forceRedact, decodedPercent, PROTECTED_NAMES, reportEmailSubject, reportEmailBo"
        'dy } = await import("data:text/javascript;base64," + Buffer.from(bodySource).toString("ba'
        'se64"));\n  const malformedLegacy = { build: { toString: null }, context: { locale: { toS'
        "tring: null } }, diagnosticSummary: { total: { toString: null } },\n    diagnostics: [{ s"
        "tatusCode: { toString: null }, elapsedMilliseconds: { toString: null }, method: { toStrin"
        'g: null } }] };\n  assert.doesNotThrow(() => reportEmailSubject("fixture", malformedLegac'
        'y));\n  assert.doesNotThrow(() => reportEmailBody("fixture", "fixture", malformedLegacy))'
        ';\n  const initialURL = "https://sso.bit.edu.cn/cas/login?ticket=INITIAL_SECRET";\n  cons'
        't finalURL = "https://jxzxehall.bit.edu.cn/fault?token=FINAL_SECRET";\n  for (const final'
        'Method of ["GET", undefined]) {\n    const message = reportEmailBody("fixture", "fixture"'
        ', forceRedact({ diagnostics: [\n      { method: "POST", url: initialURL, finalURL, finalM'
        'ethod, statusCode: 503 }\n    ] }));\n    assert(message.includes("POST https://sso.bit.e'
        'du.cn/cas/login"));\n    assert(message.includes(`→ ${finalMethod || "?"} https://jxzxeha'
        'll.bit.edu.cn/fault`));\n    assert(!message.includes("INITIAL_SECRET") && !message.inclu'
        'des("FINAL_SECRET"));\n  }\n  assert(!reportEmailBody("fixture", "fixture", { diagnostics'
        ': [\n    { method: "GET", url: initialURL, finalURL: initialURL, finalMethod: "GET", stat'
        'usCode: 503 }\n  ] }).includes("→"));\n  let saved = 0, sent = 0, offline = true, failSta'
        "tusWrite = false, failJobWrite = false, failInitialWrite, alarmAt, duringSend;\n  let fai"
        "lAcceptanceWrite, failAcceptanceState = false, failAcceptanceAlarm = false, failExpiryAla"
        "rm = false, failInitialJobWrite;\n  const emails = [];\n  const records = new Map(), jobs"
        " = new Map();\n  const quotaRecords = new Map(); let quotaAlarmAt;\n  const reportQuota ="
        " new ReportQuota({ storage: { kv: {\n    get(key) { return structuredClone(quotaRecords.g"
        "et(key)); },\n    put(key, value) { quotaRecords.set(key, structuredClone(value)); },\n  "
        "  list({ prefix }) { return new Map([...quotaRecords].filter(([key]) => key.startsWith(pr"
        "efix))); },\n    delete(key) { return quotaRecords.delete(key); }\n  }, transactionSync(o"
        "peration) { return operation(); },\n    async getAlarm() { return quotaAlarmAt ?? null; }"
        ", async setAlarm(at) { quotaAlarmAt = at; }\n  } }, {});\n  const reserve = reservationID"
        ' => reportQuota.fetch(new Request("https://quota/reserve", { method: "POST",\n    body: J'
        'SON.stringify({ source: "quota-fixture", reservationID }) }));\n  const RealDate = Date; '
        'let quotaTime = RealDate.parse("2026-01-01T12:00:00Z");\n  globalThis.Date = class extend'
        "s RealDate {\n    constructor(...arguments_) { super(...(arguments_.length ? arguments_ :"
        " [quotaTime])); }\n    static now() { return quotaTime; }\n  };\n  try {\n    for (let in"
        "dex = 0; index < 100; index++) assert.equal((await (await reserve(`request-${index}`)).js"
        'on()).allowed, true);\n    assert.equal((await (await reserve("request-0")).json()).allow'
        'ed, true);\n    assert.equal((await (await reserve("new-request")).json()).allowed, false'
        ');\n    assert.equal(quotaRecords.get("daily").count, 100);\n    quotaTime += 24 * 60 * 6'
        '0 * 1000;\n    assert.equal((await (await reserve("request-0")).json()).allowed, true);\n'
        '    assert.equal(quotaRecords.get("daily").count, 100);\n    assert.equal((await (await r'
        'eserve("next-day-request")).json()).allowed, true);\n    assert.equal(quotaRecords.get("d'
        'aily").count, 1);\n    quotaAlarmAt = null; await reportQuota.alarm(); assert(quotaAlarmA'
        "t > quotaTime);\n    quotaTime += 30 * 24 * 60 * 60 * 1000;\n    quotaAlarmAt = null; awa"
        "it reportQuota.alarm();\n    assert.equal([...quotaRecords.keys()].filter(key => key.star"
        'tsWith("reservation:")).length, 0);\n    assert.equal((await (await reserve("request-0"))'
        '.json()).allowed, true);\n    assert.equal(quotaRecords.get("daily").count, 1); assert(qu'
        "otaAlarmAt > quotaTime);\n  } finally { globalThis.Date = RealDate; }\n  quotaRecords.cle"
        "ar();\n  const storage = {\n    async get(key) { return structuredClone(jobs.get(key)); }"
        ", async put(key, value) {\n      if (!value.accepted && failInitialJobWrite) {\n        c"
        'onst committed = failInitialJobWrite === "committed"; failInitialJobWrite = null;\n      '
        '  if (committed) jobs.set(key, structuredClone(value));\n        throw new Error("initial'
        ' job storage unavailable");\n      }\n      if (value.accepted && failAcceptanceState) { '
        'failAcceptanceState = false; throw new Error("acceptance state unavailable"); }\n      if'
        ' (value.delivery.status === "sent" && failJobWrite) { failJobWrite = false; throw new Err'
        'or("job storage unavailable"); }\n      jobs.set(key, structuredClone(value));\n    },\n '
        "   async getAlarm() { return alarmAt ?? null; },\n    async setAlarm(at) {\n      if (fai"
        'lExpiryAlarm) { failExpiryAlarm = false; throw new Error("retention alarm unavailable"); '
        "}\n      if (failAcceptanceAlarm && at < Date.now() + 10000) { failAcceptanceAlarm = fals"
        'e; throw new Error("alarm unavailable"); }\n      alarmAt = at;\n    }, async deleteAll()'
        " { jobs.clear(); }\n  };\n  const emailEnv = {\n    ERROR_REPORTS: {\n      async get(key"
        ") { return records.get(key)?.value || null; },\n      async delete(key) { records.delete("
        "key); },\n      async getWithMetadata(key) { return records.get(key) || { value: null }; "
        "},\n      async put(key, value, options) {\n        if (failAcceptanceWrite) {\n         "
        ' if (failAcceptanceWrite === "committed") records.set(key, { value, metadata: options.met'
        'adata });\n          throw new Error("acceptance storage unavailable");\n        }\n     '
        '   if (options.expirationTtl && failInitialWrite) {\n          if (failInitialWrite === "'
        'committed") records.set(key, { value, metadata: options.metadata });\n          throw new'
        ' Error("report storage unavailable");\n        }\n        if (options.expiration && failS'
        'tatusWrite) throw new Error("status storage unavailable");\n        saved += 1; records.s'
        "et(key, { value, metadata: options.metadata });\n        if (options.expirationTtl) asser"
        "t.equal(options.expirationTtl, 30 * 24 * 60 * 60);\n      }\n    },\n    REPORT_QUOTA: { "
        "idFromName() {}, get() { return { async fetch(url, options) { return reportQuota.fetch(ne"
        'w Request(url, options)); } }; } },\n    REPORT_EMAIL_RECIPIENT: "recipient@fixture.inval'
        'id",\n    REPORT_EMAIL: { async send(message) {\n      assert.equal(message.to, "recipien'
        't@fixture.invalid");\n      sent += 1; emails.push(message); if (offline) throw new Error'
        '("offline");\n      if (duringSend) { const callback = duringSend; duringSend = null; awa'
        'it callback(); }\n      return { messageId: "fixture-receipt" };\n    } }\n  };\n  let se'
        "rial = Promise.resolve();\n  const delivery = new ReportEmailDelivery({ storage, blockCon"
        "currencyWhile(callback) {\n    const work = serial.then(callback); serial = work.catch(()"
        " => {}); return work;\n  } }, emailEnv);\n  emailEnv.REPORT_EMAIL_DELIVERY = { idFromName"
        "(id) { return id; }, get(id) { return {\n    async fetch(url, options) {\n      const inp"
        'ut = JSON.parse(options.body);\n      assert.equal(options.method === "DELETE" ? input.ke'
        'y.split(":").at(-1) : input.id, id);\n      return delivery.fetch(new Request(url, option'
        's));\n    }\n  }; } };\n  for (const failure of ["rejected", "committed"]) {\n    failIni'
        'tialWrite = failure;\n    const failed = await feedback.fetch(new Request("https://feedba'
        'ck.invalid/api/error-reports", { method: "POST",\n      headers: { "CF-Connecting-IP": "1'
        '92.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment: "fixture" }) }), emailEn'
        'v);\n    assert.equal(failed.status, 503); assert.equal((await failed.json()).error, "rep'
        'ort_storage_unavailable");\n    assert.equal(jobs.get("job").deleted, true); assert.equal'
        "(records.size, 0);\n    await delivery.alarm(); assert.equal(sent, 0); jobs.clear();\n  }"
        '\n  failInitialWrite = null;\n  for (const failure of ["committed", "state"]) {\n    jobs'
        ".clear(); records.clear(); quotaRecords.clear(); alarmAt = undefined; saved = 0; sent = 0"
        '; offline = false;\n    failAcceptanceWrite = failure === "committed" ? "committed" : nul'
        'l; failAcceptanceState = failure === "state";\n    const requestID = crypto.randomUUID();'
        '\n    const receipt = await feedback.fetch(new Request("https://feedback.invalid/api/erro'
        'r-reports", { method: "POST",\n      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: '
        'JSON.stringify({ mode: "suggestion", comment: "alarm recovery", requestID }) }), emailEnv'
        ");\n    assert.equal(receipt.status, 503); assert.equal(records.size, 1); assert.equal(jo"
        'bs.get("job").accepted, false);\n    assert(alarmAt < Date.now() + 10000); failAcceptance'
        'Write = null;\n    await delivery.alarm(); assert.equal(jobs.get("job").accepted, true); '
        'assert.equal(sent, 1);\n    assert.equal(JSON.parse(records.get(jobs.get("job").key).valu'
        'e).report.comment, "alarm recovery");\n    assert.equal(quotaRecords.get("daily").count, '
        '1);\n    await delivery.alarm(); assert.equal(sent, 1);\n  }\n  for (const failure of ["r'
        'ejected", "committed", "state", "alarm", "expiry-alarm", "initial-state", "initial-state-'
        'committed"]) {\n    jobs.clear(); records.clear(); quotaRecords.clear(); alarmAt = undefi'
        'ned; saved = 0; sent = 0; offline = false;\n    failAcceptanceWrite = ["rejected", "commi'
        'tted"].includes(failure) ? failure : null;\n    failAcceptanceState = failure === "state"'
        '; failAcceptanceAlarm = failure === "alarm";\n    failExpiryAlarm = failure === "expiry-a'
        'larm";\n    failInitialJobWrite = failure === "initial-state" ? "rejected" : failure === '
        '"initial-state-committed" ? "committed" : null;\n    const requestID = crypto.randomUUID('
        ');\n    const sendAttempt = comment => feedback.fetch(new Request("https://feedback.inval'
        'id/api/error-reports", { method: "POST",\n      headers: { "CF-Connecting-IP": "192.0.2.1'
        '" }, body: JSON.stringify({ mode: "suggestion", comment, requestID }) }), emailEnv);\n   '
        ' assert.equal((await sendAttempt("retained content")).status, 503);\n    const firstKey ='
        ' jobs.get("job")?.key;\n    if (failure === "expiry-alarm" || failure === "initial-state"'
        ") { assert.equal(jobs.size, 0); assert.equal(records.size, 0); }\n    assert.equal(quotaR"
        'ecords.get("daily").count, 1);\n    assert.equal(sent, 0);\n    failAcceptanceWrite = nul'
        "l;\n    for (let retry = 0; retry < 2; retry++) {\n      const receipt = await sendAttemp"
        't("retained content");\n      assert.equal(receipt.status, 201); assert.equal((await rece'
        'ipt.json()).id, requestID);\n      assert.equal(quotaRecords.get("daily").count, 1);\n   '
        ' }\n    const key = jobs.get("job").key;\n    assert.equal(records.size, 1); if (firstKey'
        ') assert.equal(key, firstKey);\n    assert.equal((await sendAttempt("changed content")).s'
        "tatus, 409);\n    await delivery.alarm(); assert.equal(sent, 1);\n    assert.equal((await"
        ' sendAttempt("retained content")).status, 201);\n    await delivery.alarm(); assert.equal'
        '(sent, 1);\n    assert.equal(JSON.parse(records.get(key).value).report.comment, "retained'
        ' content");\n    await delivery.fetch(new Request("https://delivery/delete", { method: "D'
        'ELETE", body: JSON.stringify({ key }) }));\n    assert.equal((await sendAttempt("retained'
        ' content")).status, 410);\n    const expired = jobs.get("job");\n    expired.receivedAt ='
        ' new Date(Date.now() - 31 * 24 * 60 * 60 * 1000).toISOString();\n    jobs.set("job", expi'
        'red);\n    assert.equal((await sendAttempt("retained content")).status, 201);\n    assert'
        '.equal(jobs.get("job").deleted, undefined);\n  }\n  jobs.clear(); records.clear(); alarmA'
        "t = undefined; saved = 0; sent = 0; offline = true;\n  const accepted = await feedback.fe"
        'tch(new Request("https://feedback.invalid/api/error-reports", { method: "POST", headers: '
        '{ "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment: '
        '"fixture" }) }), {\n    ...emailEnv\n  });\n  let bodyReads = 0;\n  const blockedBody = n'
        "ew ReadableStream({ pull(controller) { bodyReads++; controller.enqueue(new TextEncoder()."
        'encode("fixture")); } }, { highWaterMark: 0 });\n  const blocked = await feedback.fetch(n'
        'ew Request("https://feedback.invalid/api/error-reports", { method: "POST", headers: { "CF'
        '-Connecting-IP": "192.0.2.1" }, body: blockedBody, duplex: "half" }), {\n    ...emailEnv,'
        " REPORT_QUOTA: { idFromName() {}, get() { return { async fetch() { return Response.json({"
        ' allowed: false, error: "source_limit_reached" }); } }; } }\n  });\n  assert.equal(blocke'
        "d.status, 429); assert.equal(bodyReads, 0);\n  assert.equal(accepted.status, 201); assert"
        ".equal(saved, 1); assert.equal(sent, 0); assert(alarmAt);\n  await assert.rejects(deliver"
        'y.alarm({ retryCount: 0 }));\n  assert.equal(jobs.get("job").delivery.status, "pending");'
        " assert.equal(sent, 1);\n  offline = false; failStatusWrite = true;\n  await assert.rejec"
        'ts(delivery.alarm({ retryCount: 1 }));\n  assert.equal(jobs.get("job").delivery.status, "'
        'sent"); assert.equal(sent, 2);\n  failStatusWrite = false; await delivery.alarm({ retryCo'
        'unt: 2 });\n  assert.equal(sent, 2);\n  const job = jobs.get("job"), stored = JSON.parse('
        'records.get(job.key).value);\n  assert.equal(stored.emailDelivery.status, "sent"); assert'
        '.equal(stored.emailDelivery.messageID, "fixture-receipt");\n  assert.equal(records.get(jo'
        'b.key).metadata.emailStatus, "sent");\n  assert.equal(alarmAt, Date.parse(job.receivedAt)'
        ' + 30 * 24 * 60 * 60 * 1000);\n  jobs.set("job", { ...job, delivery: { status: "pending",'
        " attempts: 0 } }); failJobWrite = true;\n  const beforeJobFailure = sent;\n  await assert"
        '.rejects(delivery.alarm({ retryCount: 0 }));\n  assert.equal(jobs.get("job").delivery.sta'
        'tus, "pending"); assert.equal(jobs.get("job").delivery.attempts, 1);\n  await delivery.al'
        "arm({ retryCount: 1 });\n  assert.equal(sent, beforeJobFailure + 2); assert.equal(jobs.ge"
        't("job").delivery.attempts, 2);\n  assert.equal(emails.at(-1).headers["X-BIT101-Report-ID'
        '"], job.id);\n  assert.equal(emails.at(-1).subject, emails.at(-2).subject);\n  assert.equ'
        "al(emails.at(-1).text, emails.at(-2).text);\n  await delivery.alarm({ retryCount: 2 }); a"
        'ssert.equal(sent, beforeJobFailure + 2);\n  jobs.set("job", { ...job, delivery: { status:'
        ' "pending", attempts: 0 } }); offline = true;\n  for (let retryCount = 0; retryCount < 6;'
        " retryCount++) await assert.rejects(delivery.alarm({ retryCount }));\n  await delivery.al"
        'arm({ retryCount: 6 });\n  assert.equal(jobs.get("job").delivery.status, "pending"); asse'
        'rt.equal(jobs.get("job").delivery.attempts, 7);\n  assert.equal(JSON.parse(records.get(jo'
        'b.key).value).emailDelivery.status, "pending");\n  assert(alarmAt > Date.now() && alarmAt'
        " < Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 * 1000);\n  offline = false; await deli"
        'very.alarm({ retryCount: 0 });\n  assert.equal(jobs.get("job").delivery.status, "sent"); '
        'assert.equal(jobs.get("job").delivery.attempts, 8);\n  assert.equal(JSON.parse(records.ge'
        't(job.key).value).emailDelivery.status, "sent");\n  failStatusWrite = true;\n  for (let r'
        "etryCount = 0; retryCount < 6; retryCount++) await assert.rejects(delivery.alarm({ retryC"
        "ount }));\n  const sentBeforeStatusRecovery = sent;\n  await delivery.alarm({ retryCount:"
        " 6 });\n  assert(alarmAt > Date.now() && alarmAt < Date.parse(job.receivedAt) + 30 * 24 *"
        " 60 * 60 * 1000);\n  failStatusWrite = false; await delivery.alarm({ retryCount: 0 });\n "
        " assert.equal(sent, sentBeforeStatusRecovery);\n  const grant = crypto.randomUUID(), gran"
        'tKey = "report-delete-grant:" + grant;\n  const deletion = () => feedback.fetch(new Reque'
        'st("https://feedback.invalid/api/error-reports", {\n    method: "DELETE", headers: { "CF-'
        'Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ key: job.key, grant })\n  }), email'
        "Env);\n  assert.equal((await deletion()).status, 403); assert(records.has(job.key));\n  r"
        'ecords.set(grantKey, { value: JSON.stringify({ key: "report:other" }) });\n  assert.equal'
        "((await deletion()).status, 403); assert(records.has(job.key));\n  records.set(grantKey, "
        '{ value: JSON.stringify({ key: job.key }) });\n  jobs.set("job", { ...job, delivery: { st'
        'atus: "pending", attempts: 0 } });\n  duringSend = async () => { assert.equal((await dele'
        "tion()).status, 200); };\n  await delivery.alarm();\n  assert(!records.has(job.key)); ass"
        'ert(!records.has(grantKey)); assert.equal(jobs.get("job").deleted, true);\n  const sentAf'
        "terDeletion = sent;\n  await delivery.alarm(); assert.equal(sent, sentAfterDeletion); ass"
        'ert(!records.has(job.key));\n  assert.equal((await delivery.fetch(new Request("https://de'
        'livery/queue", { method: "POST", body: JSON.stringify(job) }))).status, 410);\n  jobs.set'
        '("job", { ...job, receivedAt: "2000-01-01T00:00:00Z" }); const attempts = sent;\n  await '
        "delivery.alarm(); assert.equal(jobs.size, 0); assert.equal(sent, attempts);\n  const orig"
        "inalNow = Date.now, originalTimeout = globalThis.setTimeout;\n  let clock = originalNow()"
        ";\n  try {\n    Date.now = () => clock;\n    globalThis.setTimeout = (callback, delay) =>"
        " { clock += delay; queueMicrotask(callback); };\n    for (const misses of [0, 2, Infinity"
        ', "read-error"]) {\n      let stored, reads = 0, removed = false;\n      const storage = '
        "{\n        async put(key, value, options) { stored = { value, metadata: options.metadata "
        "}; assert(options.expirationTtl * 1000 > 60000); },\n        async getWithMetadata(key, o"
        "ptions) {\n          reads += 1; assert.equal(options.cacheTtl, 30);\n          if (misse"
        's === "read-error") throw new Error("KV unavailable");\n          return reads <= misses '
        "? { value: null, metadata: null } : stored;\n        },\n        async delete() { stored "
        "= null; removed = true; }\n      };\n      const quota = { async fetch() { return Respons"
        "e.json({ allowed: true }); } };\n      const environment = { ERROR_REPORTS: storage, REPO"
        "RT_QUOTA: { idFromName: name => name, get: () => quota } };\n      const request = new Re"
        'quest("https://feedback.invalid/api/error-reports", { method: "POST",\n        headers: {'
        ' "CF-Connecting-IP": "192.0.2.1", "X-BIT101-Network-Smoke": "1" },\n        body: JSON.st'
        'ringify({ mode: "network-smoke", runID: "visible-record" }) });\n      if (misses === "re'
        'ad-error") { await assert.rejects(feedback.fetch(request, environment), /KV unavailable/)'
        "; }\n      else {\n        const response = await feedback.fetch(request, environment);\n"
        "        assert.equal(response.status, misses === Infinity ? 503 : 201);\n        if (miss"
        'es === Infinity) assert.equal((await response.json()).error, "smoke_visibility_timeout");'
        "\n      }\n      assert(removed && stored === null && reads <= 3);\n    }\n  } finally { "
        "Date.now = originalNow; globalThis.setTimeout = originalTimeout; }\n  const appNames = JS"
        'ON.parse("[" + fs.readFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift",'
        ' "utf8").match(/protectedNames = \\[([\\s\\S]*?)\\]/)[1] + "]");\n  assert.deepEqual(PROT'
        'ECTED_NAMES, appNames);\n  for (const value of ["https://example.invalid/?%70assword=TEST'
        '_ONLY_SECRET", "https://example.invalid/?%2570assword=TEST_ONLY_SECRET", "https://example'
        '.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://'
        'example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "h'
        'ttps://fixture-user:TEST_ONLY_SECRET@example.invalid/", "https://example.invalid/#%74oken'
        '=TEST_ONLY_SECRET", "https://example.invalid/#%2574oken=TEST_ONLY_SECRET", "https://examp'
        'le.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad"]) {\n    assert(!decodeURIComponent(force'
        'Redact(value)).includes("TEST_ONLY_SECRET")); assert.equal(forceRedact("https://example.i'
        'nvalid/#section"), "https://example.invalid/#section");\n  }\n  for (const value of ["Aut'
        'horization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY_SECRET", "Cookie: f'
        'irst=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", \'{"password":"TEST_ONLY_\\\\\\"SECRET"}'
        '\']) assert(!forceRedact(value).includes("TEST_ONLY") && !forceRedact(value).includes("SE'
        'CRET"));\n  const deepPercent = "%" + "25".repeat(20000);\n  const originalDecode = globa'
        "lThis.decodeURIComponent;\n  let decodeCalls = 0;\n  try {\n    globalThis.decodeURICompo"
        "nent = value => { decodeCalls += 1; return originalDecode(value); };\n    assert.throws(("
        ") => decodedPercent(deepPercent), /budget/);\n    assert(decodeCalls <= 8);\n  } finally "
        "{ globalThis.decodeURIComponent = originalDecode; }\n  for (const suffix of [`?note=${dee"
        "pPercent}`, `?${deepPercent}=TEST_ONLY_SECRET`, `#${deepPercent}`]) {\n    assert.equal(f"
        'orceRedact(`https://example.invalid/${suffix}`), "[REDACTED]");\n  }\n  let deeplyNested '
        '= "https://school.invalid/?ticket=TEST_ONLY_SECRET";\n  for (let pass = 0; pass < 12; pas'
        "s += 1) deeplyNested = encodeURIComponent(deeplyNested);\n  assert.equal(forceRedact(`htt"
        'ps://example.invalid/?service=${deeplyNested}`), "[REDACTED]");\n  for (const value of ['
        '\'<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">\', \'<input id'
        '="login-croypto" value="SENSITIVE_VALUE">\', \'<input value="SENSITIVE_VALUE>TAIL_VALUE" '
        'name="execution">\', \'<input name="execution" value="SENSITIVE_VALUE\', \'<textarea name'
        '="password">SENSITIVE_VALUE</textarea>\', \'<textarea name="password">SENSITIVE_VALUE\', '
        '\'{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}\', \'{"captcha_payloa'
        'd":["SENSITIVE_VALUE"]}\', \'{"cookie_str":{"value":"SENSITIVE_VALUE\']) {\n    const mas'
        'ked = forceRedact(value); assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes('
        '"TAIL_VALUE") && masked.includes("[REDACTED]"));\n    if (value.includes("available")) as'
        'sert(masked.includes("available"));\n  }\n  for (const value of [\'<span id="login-page-f'
        "lowkey\">SENSITIVE_VALUE</span>', '<span id=\"login-page-flowkey\">SENSITIVE_VALUE',\n   "
        ' \'<div id="login-page-flowkey">SENSITIVE_VALUE</div>\',\n    \'<p id="login-croypto">SEN'
        "SITIVE_VALUE</p>',\n    '<div><p id=\"login-page-flowkey\">SENSITIVE_VALUE</p><p>availabl"
        "e</p></div>',\n    '<div id=\"login-page-flowkey\"><div>SENSITIVE_VALUE</div>TAIL_VALUE</"
        "div><p>available</p>',\n    '<x-field name=\"csrf-token\"><b>SENSITIVE_VALUE</b></x-field"
        ">',\n    '<p id=\"login-page-flowkey\">SENSITIVE_VALUE',\n    '<meta http-equiv=\"Set-Co"
        'okie" content="SENSITIVE_VALUE">\',\n    \'<meta name="csrf-token" content="SENSITIVE_VAL'
        'UE">\', \'<meta content="SENSITIVE_VALUE" property="csrf&#45;token">\',\n    \'<script>co'
        'nst csrfToken = "SENSITIVE_VALUE;TAIL_VALUE";</script>\', "<script>var _token = \'SENSITI'
        'VE_VALUE;TAIL_VALUE\';</script>",\n    \'<script>window["csrfToken"] = "SENSITIVE_VALUE";'
        "</script>', 'csrf_token=SENSITIVE_VALUE',\n    '<input type=\"password\" value=\"SENSITI"
        "VE_VALUE\">', '<input TYPE=pass&#x77;ord value=\"SENSITIVE_VALUE\">',\n    '<input name="
        '"pass&#119;ord" value="SENSITIVE_VALUE">\', \'<input name="pass&#x77ord" value="SENSITIVE'
        "_VALUE\">',\n    '<textarea name=\"access&lowbar;token\">SENSITIVE_VALUE</textarea>']) {"
        '\n    const masked = forceRedact(value);\n    assert(!masked.includes("SENSITIVE_VALUE") '
        '&& !masked.includes("TAIL_VALUE"));\n  }\n  const ordinaryInput = \'<input type="text" na'
        'me="summary" value="visible">\';\n  assert.equal(forceRedact(ordinaryInput), ordinaryInpu'
        't);\n  const emergency = (await import("data:text/javascript;base64," + Buffer.from(fs.re'
        'adFileSync("src/index.js", "utf8")).toString("base64"))).default;\n  const notice = { sch'
        'ema_version: 1, enabled: true, notice_id: "fixture", maximum_affected_build: 100, title: '
        '"fixture", message: "fixture" };\n  for (const [value, status] of [[null, 503], [{ enable'
        'd: false }, 503], [{ schema_version: 1, enabled: false }, 200], [new Error("offline"), 50'
        '3], [notice, 200], [{ ...notice, title: " " }, 503], [{ ...notice, maximum_affected_build'
        ': 1e20 }, 503]]) {\n    const response = await emergency.fetch(new Request("https://emerg'
        'ency.invalid/emergency-update.json"), { EMERGENCY_CONFIG: { async get() { if (value insta'
        "nceof Error) throw value; return value; } } });\n    assert.equal(response.status, status"
        ');\n  }\n  for (const args of [["1", " ", "fixture"], ["1", "fixture", " "], ["9007199254'
        '740992", "fixture", "fixture"]]) {\n    assert.equal(require("node:child_process").spawnS'
        'ync("zsh", ["Scripts/publish-emergency-update.sh", ...args]).status, 64);\n  }\n  const p'
        'ublisher = fs.readFileSync("Scripts/publish-emergency-update.sh", "utf8");\n  assert(publ'
        "isher.includes('source \"$ROOT_DIR/../../Scripts/script-support.sh\"'));\n  assert(publis"
        "her.includes('bit101_acquire_script_lock \"$HOME/Library/Caches/BIT101-iOS/emergency-publ"
        'ish.lock" BIT101_EMERGENCY_PUBLISH_LOCK_HELD "$0" "$@"\'));\n  assert(publisher.indexOf("'
        'bit101_acquire_script_lock") < publisher.indexOf(\'"$WRANGLER" kv key put\'));\n  let chu'
        "nks = 0, cancelled = false;\n  const stream = new ReadableStream({\n    pull(controller) "
        "{ chunks += 1; controller.enqueue(new Uint8Array(1024 * 1024)); },\n    cancel() { cancel"
        'led = true; }\n  });\n  assert.equal(await readReportBody(new Request("https://feedback.i'
        'nvalid", { method: "POST", body: stream, duplex: "half" })), null);\n  assert(cancelled &'
        "& chunks <= Math.floor(MAX_BODY_BYTES / (1024 * 1024)) + 2);\n  chunks = 0; cancelled = f"
        "alse;\n  const deletionStream = new ReadableStream({\n    pull(controller) { chunks += 1;"
        " controller.enqueue(new Uint8Array(512)); },\n    cancel() { cancelled = true; }\n  });\n"
        '  assert.equal((await feedback.fetch(new Request("https://feedback.invalid/api/error-repo'
        'rts", {\n    method: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: deleti'
        'onStream, duplex: "half"\n  }), emailEnv)).status, 413);\n  assert(cancelled && chunks <='
        " 4);\n  const utf8 = new TextEncoder().encode('文章😀');\n  const split = new ReadableStream"
        "({ start(controller) {\n    for (const byte of utf8) controller.enqueue(new Uint8Array([b"
        "yte]));\n    controller.close();\n  }});\n  assert.equal(await readReportBody(new Request"
        '("https://feedback.invalid", { method: "POST", body: split, duplex: "half" })), \'文章😀\');'
        '\n  let source = fs.readFileSync("../OpenWorker/worker.js", "utf8");\n  const iconImport '
        '= source.match(/^import shareIcon from "([^"]+)";/);\n  assert(iconImport, "Share icon mu'
        'st use the app asset");\n  const png = fs.readFileSync(require("node:path").resolve("../O'
        'penWorker", iconImport[1]));\n  const openConfig = experimental_readRawConfig({ config: "'
        '../OpenWorker/wrangler.jsonc" }).rawConfig;\n  assert(openConfig.rules.some(rule => rule.'
        'type === "Data" && rule.globs.includes("**/*.png")));\n  source = source.replace(iconImpo'
        'rt[0], `const shareIcon = Uint8Array.from(atob("${png.toString("base64")}"), character =>'
        ' character.charCodeAt(0)).buffer;`);\n  const worker = (await import("data:text/javascrip'
        't;base64," + Buffer.from(source).toString("base64"))).default;\n  const aasa = await (awa'
        'it worker.fetch(new Request("https://open.invalid/.well-known/apple-app-site-association"'
        '))).json();\n  assert.deepEqual(aasa.applinks.details[0].paths, ["/gallery/*", "/course/*'
        '", "/paper/*"]);\n  for (const route of ["gallery", "course", "paper"]) {\n    const resp'
        "onse = await worker.fetch(new Request(`https://open.invalid/${route}/42`));\n    assert.e"
        "qual(response.status, 200);\n    const html = await response.text();\n    assert(html.inc"
        'ludes(`href="bit101://${route}/42"`) && html.includes(`href="https://bit101.cn/${route}/4'
        '2"`));\n    assert(html.includes(\'<meta property="og:image:type" content="image/png">\')'
        ');\n    assert(html.includes(`<meta property="og:image:width" content="${png.readUInt32BE'
        '(16)}">`));\n    assert(html.includes(`<meta property="og:image:height" content="${png.re'
        'adUInt32BE(20)}">`));\n    assert(html.includes(`type="image/png" sizes="${png.readUInt32'
        'BE(16)}x${png.readUInt32BE(20)}"`));\n  }\n  for (const route of ["gallery", "course", "p'
        'aper"]) {\n    for (const id of ["0", "9223372036854775808", "9".repeat(100)]) {\n      a'
        "ssert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/${id}`))).stat"
        "us, 302);\n    }\n    assert.equal((await worker.fetch(new Request(`https://open.invalid/"
        "${route}/9223372036854775807`))).status, 200);\n  }\n  let iconRequests = 0;\n  global.fe"
        'tch = async () => { iconRequests += 1; throw new Error("upstream unavailable"); };\n  for'
        " (let attempt = 0; attempt < 2; attempt++) {\n    const response = await worker.fetch(new"
        ' Request("https://open.invalid/share-icon.jpg"));\n    assert.equal(response.status, 200)'
        ';\n    assert.equal(response.headers.get("Content-Type"), "image/png");\n    assert.equal'
        '(response.headers.get("Cache-Control"), "public, max-age=604800");\n    assert.deepEqual('
        "Buffer.from(await response.arrayBuffer()), png);\n  }\n  assert.equal(iconRequests, 0);\n"
        "})().catch(error => { console.error(error); process.exitCode = 1; });\n"
    )
    result = subprocess.run(
        ["node", "-"],
        input=script,
        capture_output=True,
        text=True,
        cwd=ROOT / "Cloudflare/EmergencyUpdateWorker",
        timeout=60,
    )
    return [f"Worker 行为回归：{result.stderr}"] if result.returncode else []


def emergency_configuration_fixture(enabled: bool = False, notice_id: str | None = None) -> dict:
    import base64, json

    payload = {"schema_version": 1, "enabled": enabled}
    if notice_id is not None:
        payload["notice_id"] = notice_id
    return {
        "content": base64.b64encode(json.dumps(payload).encode()).decode("ascii"),
        "enabled": enabled,
        "noticeID": notice_id,
    }


def worker_deployment_fixture(scope: str = "all") -> dict:
    import uuid
    from validation_provenance import WORKER_FOLDERS, worker_source_revision

    return {
        folder: {
            "deploymentID": str(uuid.UUID(int=index + 1)),
            "sourceRevision": worker_source_revision(folder),
            "versions": [
                {
                    "versionID": str(uuid.UUID(int=index + 4)),
                    "percentage": 100,
                    "sourceRevision": worker_source_revision(folder),
                }
            ],
        }
        for index, folder in enumerate(WORKER_FOLDERS)
        if scope in {"all", "bit101"}
    }


def worker_deployment_self_test(network_trace_fixture) -> None:
    import copy, json, subprocess, sys, uuid
    from contextlib import contextmanager, nullcontext, redirect_stderr
    from io import BytesIO, StringIO
    from unittest.mock import patch
    from types import SimpleNamespace
    import validation_provenance as subject

    deploy_command = json.loads((subject.WRANGLER_ROOT / "package.json").read_text())["scripts"][
        "deploy"
    ]
    dispatch = subprocess.run(
        ["zsh", "-c", 'python3() { print -rl -- "$@"; }\n' + deploy_command],
        cwd=subject.WRANGLER_ROOT,
        capture_output=True,
        text=True,
    )
    assert dispatch.returncode == 0 and dispatch.stdout.splitlines() == [
        "../../Scripts/validation_provenance.py",
        "deploy-worker",
        "EmergencyUpdateWorker",
    ]
    proof = worker_deployment_fixture()
    body = b'{"schema_version":1,"enabled":false}'
    summary = network_trace_fixture({"requiredProbes": ["update.emergency"]}) | {
        "workerDeployments": proof
    }
    summary["requestEvidence"][0]["requests"][0]["responseConfiguration"]["content"] = (
        subject.base64.b64encode(body).decode("ascii")
    )
    assert subject.network_requests_complete({"update.emergency"}, summary)

    class ConfigurationResponse(BytesIO):
        status = 200

        def geturl(self):
            return "https://update.aihelpme.dev/emergency-update.json"

    with (
        patch.object(subject, "capture_worker_deployments", return_value=proof),
        patch(
            "urllib.request.urlopen",
            side_effect=lambda *args, **kwargs: ConfigurationResponse(body),
        ),
    ):
        assert subject.release_worker_findings(summary) == []
        changed = copy.deepcopy(summary)
        changed["workerDeployments"][subject.WORKER_FOLDERS[0]]["deploymentID"] = str(uuid.uuid4())
        assert any("活跃部署已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        changed["requestEvidence"][0]["requests"][0]["responseConfiguration"]["content"] = "b" * 40
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        for requests in ([], [{}], [{"responseConfiguration": None}]):
            changed = copy.deepcopy(summary)
            changed["requestEvidence"][0]["requests"] = requests
            assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        request = changed["requestEvidence"][0]["requests"][0]
        changed["requestEvidence"][0]["requests"].append(
            request | {"responseConfiguration": {"content": "b" * 40}}
        )
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        changed["requestEvidence"].append(
            {"probe": "other", "requests": [{"responseConfiguration": {"content": "b" * 40}}]}
        )
        assert subject.release_worker_findings(changed) == []
        changed["requestEvidence"][0] = {
            "probe": "update.emergency",
            "responseConfiguration": {"content": subject.base64.b64encode(body).decode("ascii")},
        }
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
    with patch.object(
        subject, "capture_worker_deployments", side_effect=ValueError("authentication")
    ):
        assert subject.release_worker_findings(summary)
    assert subject.worker_deployments_complete("all", proof)
    assert subject.worker_deployments_complete("school", {})
    assert not subject.worker_deployments_complete("all", {})
    folder = subject.WORKER_FOLDERS[0]
    original_read = Path.read_bytes
    source = subject.ROOT / "Cloudflare" / folder / "worker.js"
    with patch.object(
        Path,
        "read_bytes",
        lambda path: (
            original_read(path) + b"\nchanged\n" if path == source else original_read(path)
        ),
    ):
        assert not subject.worker_deployments_complete("all", proof)
    icon = subject.ROOT / "BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    with patch.object(
        Path,
        "read_bytes",
        lambda path: original_read(path) + b"changed" if path == icon else original_read(path),
    ):
        assert not subject.worker_deployments_complete("all", proof)
    names = subject.repository_input_names(subject.ROOT)
    for suffix in (".json", ".mjs", ".ts", ".wasm", ".html", ".css", ".png"):
        asset = subject.ROOT / "Cloudflare" / folder / ("page" + suffix)
        generated = subject.ROOT / "Cloudflare" / folder / ".wrangler/tmp/page.json"
        content = {asset: b"first", generated: b"first"}
        with (
            patch.object(
                subject,
                "repository_input_names",
                return_value=names
                + [
                    asset.relative_to(subject.ROOT).as_posix(),
                    generated.relative_to(subject.ROOT).as_posix(),
                ],
            ),
            patch.object(
                Path,
                "read_bytes",
                lambda path: content[path] if path in content else original_read(path),
            ),
        ):
            before = subject.worker_source_inputs(folder)
            content[generated] = b"second"
            assert subject.worker_source_inputs(folder) == before
            content[asset] = b"second"
            assert subject.worker_source_inputs(folder) != before, suffix
    for name in (
        "config/emergency-update.json",
        "Scripts/publish-emergency-update.sh",
        "README.md",
    ):
        operational = subject.WRANGLER_ROOT / name
        with patch.object(
            Path,
            "read_bytes",
            lambda path: b"changed" if path == operational else original_read(path),
        ):
            assert (
                subject.worker_source_revision("EmergencyUpdateWorker")
                == proof["EmergencyUpdateWorker"]["sourceRevision"]
            )
    for field, value in [
        ("deploymentID", "invalid"),
        ("sourceRevision", "b" * 40),
        ("versions", []),
    ]:
        changed = copy.deepcopy(proof)
        changed[folder][field] = value
        assert not subject.worker_deployments_complete("all", changed), field
    for field, value in [
        ("versionID", "invalid"),
        ("percentage", True),
        ("percentage", 99),
        ("percentage", float("nan")),
        ("sourceRevision", "b" * 40),
    ]:
        changed = copy.deepcopy(proof)
        changed[folder]["versions"][0][field] = value
        assert not subject.worker_deployments_complete("all", changed), field
    gradual = copy.deepcopy(proof)
    first = gradual[folder]["versions"][0]
    first["percentage"] = 40
    gradual[folder]["versions"].append(dict(first, versionID=str(uuid.uuid4()), percentage=60))
    assert subject.worker_deployments_complete("all", gradual)
    gradual[folder]["versions"][1]["sourceRevision"] = "b" * 40
    assert not subject.worker_deployments_complete("all", gradual)
    calls = []

    def cli(name, *arguments):
        calls.append((name, arguments))
        row = proof[name]
        if arguments == ("deployments", "status"):
            return {
                "id": row["deploymentID"],
                "versions": [
                    {"version_id": item["versionID"], "percentage": item["percentage"]}
                    for item in row["versions"]
                ],
            }
        identifier = arguments[-1]
        return {
            "id": identifier,
            "annotations": {
                "workers/message": subject.WORKER_SOURCE_PREFIX + row["sourceRevision"]
            },
        }

    with patch.object(subject, "worker_cli_json", cli):
        assert subject.capture_worker_deployments("all") == proof
        assert len(calls) == 6
        calls.clear()
        assert subject.capture_worker_deployments("school") == {} and calls == []
        with patch.object(subject, "worker_source_revision", return_value="b" * 40):
            try:
                subject.capture_worker_deployments("all")
            except ValueError:
                pass
            else:
                raise AssertionError("旧部署需要拒绝新源码证据。")
    with patch.object(
        subject.subprocess,
        "run",
        side_effect=lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=""
            if kwargs["env"].get("WRANGLER_LOG") == "error"
            else json.dumps({"id": "deployment"}),
        ),
    ) as run:
        assert subject.worker_cli_json(folder, "deployments", "status") == {"id": "deployment"}
        assert run.call_args.args[0][1:4] == ["deployments", "status", "--json"]
        assert run.call_args.kwargs["env"]["WRANGLER_LOG_PATH"] == str(subject.WORKER_LOG)
    with patch.object(
        subject.subprocess,
        "run",
        return_value=SimpleNamespace(
            returncode=1, stdout="", stderr="fixture authentication failed"
        ),
    ):
        try:
            subject.worker_cli_json(folder, "deployments", "status")
        except ValueError:
            pass
        else:
            raise AssertionError("认证失败需要传播读取失败。")
    report_path = Path("/fixture/release-network-smoke.json")
    report = {"scope": "all", "passed": True}
    for changed in (False, True):
        snapshot = copy.deepcopy(proof)
        if changed:
            snapshot[folder]["deploymentID"] = str(uuid.uuid4())
        with (
            patch.object(
                sys, "argv", ["worker", "worker-attach", str(report_path), json.dumps(proof)]
            ),
            patch.object(Path, "read_text", return_value=json.dumps(report)),
            patch.object(Path, "write_text") as write,
            patch.object(subject, "report_lock", side_effect=lambda **kwargs: nullcontext()),
            patch.object(subject, "capture_worker_deployments", return_value=snapshot),
            redirect_stderr(StringIO()),
        ):
            try:
                status = subject.worker_main()
            except SystemExit as error:
                status = error.code
            assert status == int(changed)
            if changed:
                assert [row.args for row in write.call_args_list] == [("",)]
            else:
                assert json.loads(write.call_args.args[0])["workerDeployments"] == proof
    console = subject.ROOT / ".build/release-network-smoke/console.log"
    logs, locked, deployments = {subject.WORKER_LOG: "previous", console: "app console"}, False, 0

    @contextmanager
    def worker_lock(*, path):
        nonlocal locked
        assert path == subject.WORKER_LOG
        locked = True
        try:
            yield
        finally:
            locked = False

    def deploy(command, **kwargs):
        nonlocal deployments
        assert locked and logs[subject.WORKER_LOG] == ""
        assert command[1:4] == ["deploy", "--message", subject.WORKER_SOURCE_PREFIX + "a" * 40]
        assert kwargs["env"]["WRANGLER_LOG_PATH"] == str(subject.WORKER_LOG)
        deployments += 1
        logs[subject.WORKER_LOG] += f"deployment {deployments}"

    with (
        patch.object(subject, "worker_source_revision", return_value="a" * 40),
        patch.object(sys, "argv", ["worker", "deploy-worker", folder]),
        patch.object(subject, "report_lock", worker_lock),
        patch.object(Path, "write_text", lambda path, text: logs.__setitem__(path, text)),
        patch.object(subject.subprocess, "run", side_effect=deploy),
    ):
        for number in (1, 2):
            assert subject.worker_main() == 0 and not locked
            assert (
                logs[subject.WORKER_LOG] == f"deployment {number}"
                and logs[console] == "app console"
            )
