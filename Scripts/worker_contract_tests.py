"""Exercise deployed Worker contracts in the local Workers runtime."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

from worker_deployment_tests import (
    emergency_configuration_fixture as emergency_configuration_fixture,
    worker_deployment_fixture as worker_deployment_fixture,
    worker_deployment_self_test as worker_deployment_self_test,
)


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
        '\nconst assert = require("node:assert/strict");\nconst fs = require("node:f'
        's");\nconst { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = requi'
        're("miniflare");\nconst { experimental_readRawConfig } = require("wrangler"'
        ');\n(async () => {\n  const config = experimental_readRawConfig({ config: "'
        '../ErrorReportWorker/wrangler.jsonc" }).rawConfig;\n  assert.equal(config.v'
        "ars.REPORT_EMAIL_RECIPIENT, config.send_email.find(binding => binding.name "
        '=== "REPORT_EMAIL").destination_address);\n  assert(config.durable_objects.'
        'bindings.some(binding => binding.name === "REPORT_QUOTA" && binding.class_n'
        'ame === "ReportQuota"));\n  assert(config.migrations.some(migration => migr'
        'ation.new_sqlite_classes.includes("ReportQuota")));\n  assert(config.durabl'
        'e_objects.bindings.some(binding => binding.name === "REPORT_EMAIL_DELIVERY"'
        ' && binding.class_name === "ReportEmailDelivery"));\n  assert(config.migrat'
        'ions.some(migration => migration.new_sqlite_classes.includes("ReportEmailDe'
        'livery")));\n  const fixtureDay = "2026-01-01";\n  const workerSource = fs.'
        'readFileSync("../ErrorReportWorker/worker.js", "utf8");\n  const dayExpress'
        'ion = "new Date().toISOString().slice(0, 10)";\n  assert(workerSource.inclu'
        "des(dayExpression));\n  const fixture = workerSource.replace(dayExpression,"
        " JSON.stringify(fixtureDay)) + `\nexport class QuotaFixture extends ReportQ"
        "uota {\n  async fetch(request) {\n    if (new URL(request.url).pathname ==="
        ' "/seed") {\n      this.ctx.storage.kv.put(new URL(request.url).searchParam'
        's.get("kind") || "daily", await request.json());\n      return new Response'
        "(null, { status: 204 });\n    }\n    if (new URL(request.url).pathname === "
        '"/inspect") return Response.json(this.ctx.storage.kv.get(new URL(request.ur'
        'l).searchParams.get("kind") || "daily"));\n    return super.fetch(request);'
        '\n  }\n}`;\n  const mf = new Miniflare(convertV4MiniflareOptions({ name: "w'
        'orker-fixture", modules: true, script: fixture,\n    compatibilityDate: con'
        'fig.compatibility_date, kvNamespaces: ["ERROR_REPORTS"],\n    durableObject'
        's: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true },\n      R'
        'EPORT_EMAIL_DELIVERY: { className: "ReportEmailDelivery", useSQLite: true }'
        " },\n    log: new Log(LogLevel.NONE) }));\n  try {\n    const preflight = a"
        'wait mf.dispatchFetch("https://feedback.invalid/api/error-reports", { metho'
        'd: "OPTIONS",\n      headers: { Origin: "https://bit101.cn", "Access-Contro'
        'l-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"'
        " } });\n    assert.equal(preflight.status, 204);\n    assert.equal(await pr"
        'eflight.text(), "");\n    assert.equal(preflight.headers.get("Access-Contro'
        'l-Allow-Origin"), "*");\n    assert(preflight.headers.get("Access-Control-A'
        'llow-Methods").split(",").map(value => value.trim()).includes("POST"));\n  '
        '  assert(preflight.headers.get("Access-Control-Allow-Headers").split(",").m'
        'ap(value => value.trim().toLowerCase()).includes("content-type"));\n    con'
        'st namespace = await mf.getDurableObjectNamespace("REPORT_QUOTA");\n    con'
        'st quota = namespace.get(namespace.idFromName("daily"));\n    const today ='
        ' fixtureDay;\n    const seed = (value, kind = "daily") => quota.fetch(`http'
        's://quota/seed?kind=${kind}`, { method: "POST", body: JSON.stringify(value)'
        ' });\n    const inspect = async (kind = "daily") => (await quota.fetch(`htt'
        'ps://quota/inspect?kind=${kind}`)).json();\n    const send = (value, ip = "'
        '192.0.2.1") => mf.dispatchFetch("https://feedback.invalid/api/error-reports'
        '", {\n      method: "POST", headers: { "CF-Connecting-IP": ip, "x-bit101-ne'
        'twork-smoke": "1" }, body: JSON.stringify(value) });\n    await seed({ day:'
        ' today, count: 0 });\n    for (const value of [{}, [], { mode: "unknown" },'
        ' { mode: "sanitized" }, { mode: "suggestion", comment: " " },\n            '
        '             { mode: "network-smoke", runID: "" }, { mode: "network-smoke",'
        ' runID: "wrong/value" },\n                         ...[{}, [null], [1], [[]'
        ']].map(diagnostics => ({ mode: "suggestion", comment: "fixture", diagnostic'
        "s }))]) {\n      assert.equal((await send(value)).status, 400);\n    }\n   "
        ' for (const [errorTitle, errorMessage] of [\n      ["登录失败", "服务器响应异常（HTTP 5'
        '00）：初始化WebVPN验证失败Orz"],\n      ["身份验证失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败O'
        'rz"],\n      ["加载话廊失败", "服务器响应异常（HTTP 500）：初始化WebVPN验证失败Orz"],\n      ["学校认'
        '证通道异常", "101 的学校认证通道暂时无法连接 WebVPN。"],\n      ["课表同步失败", "认证信息无效。 [status=40'
        '1, risk=ustc-token, flow=replaced]"],\n      ["学校账号已锁定", "学校统一认证提示账号已被锁定。"]'
        ',\n      ["学校认证受限", "学校统一认证拒绝了本次认证请求。"],\n      ["课表同步失败", "账号被锁定 (code: 10'
        '30028) [risk=error-fallback, flow=replaced]"],\n      ["学期列表加载失败", "您的会话已经过'
        '期，请重新登录"],\n      ["验证已失效", "jxzxehall: 解析 service url 失败"],\n      ["课表同步失'
        '败", "学校教务服务返回“无权访问该资源”"],\n      ["学校服务连接失败", "学校统一认证服务暂时无法建立安全连接，请稍后重试。"],'
        '\n      ["课表同步失败", "学校教务服务暂时无法恢复会话，请稍后重试。"]\n    ]) {\n      for (const mod'
        'e of ["raw", "sanitized"]) {\n        const result = await send({ mode, err'
        "orTitle, errorMessage });\n        assert.equal(result.status, 422); assert"
        '.equal((await result.json()).error, "school_service_issue");\n      }\n    '
        '}\n    assert.equal((await (await mf.getKVNamespace("ERROR_REPORTS")).list('
        '{ prefix: "report:" })).keys.length, 0);\n    for (const [errorTitle, error'
        'Message] of [["DDL 同步失败", "课表缓存读取受阻"],\n      ["课表同步失败", "服务器返回了无法识别的数据"], '
        '["加载话廊失败", "服务器响应异常（HTTP 500）：数据库错误Orz"],\n      ["登录失败", "当前会话已过期"]]) {\n '
        '     const result = await send({ mode: "raw", errorTitle, errorMessage, att'
        'achments: [{ data: "==" }] });\n      assert.equal(result.status, 400); ass'
        'ert.equal((await result.json()).error, "invalid_attachment");\n    }\n    f'
        "or (const contentType of [[], {}, 5]) {\n      assert.equal((await send({ m"
        'ode: "suggestion", comment: "fixture", attachments: [{ data: "QQ==", conten'
        "tType }] })).status, 400);\n    }\n    const deep = await mf.dispatchFetch("
        '"https://feedback.invalid/api/error-reports", { method: "POST", body: \'{"m'
        'ode":"suggestion","comment":"fixture","extra":\' + \'[\'.repeat(5000) + \'n'
        "ull' + ']'.repeat(5000) + '}' });\n    assert.equal(deep.status, 400);\n   "
        ' assert.equal((await send({ mode: "suggestion", comment: "x".repeat(2 * 102'
        '4 * 1024) })).status, 413);\n    for (const fields of [{ name: "x".repeat(2'
        ' * 1024 * 1024) },\n                         { contentType: "x".repeat(2 * '
        '1024 * 1024) },\n                         { details: { description: "x".rep'
        'eat(2 * 1024 * 1024) } }]) {\n      const response = await send({ mode: "su'
        'ggestion", comment: "fixture", attachments: [{ data: "AAAA", ...fields }] }'
        ");\n      assert.equal(response.status, 413);\n      assert.equal((await re"
        'sponse.json()).error, "metadata_too_large");\n    }\n    const combinedMeta'
        'data = await send({ mode: "suggestion", comment: "fixture",\n      attachme'
        'nts: [{ data: "AAAA", name: "x".repeat(600 * 1024) }, { data: "AAAA", name:'
        ' "x".repeat(600 * 1024) }] });\n    assert.equal(combinedMetadata.status, 4'
        '13);\n    assert.equal((await combinedMetadata.json()).error, "metadata_too'
        '_large");\n    assert.equal((await inspect()).count, 0);\n    for (const da'
        'ta of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!", "A==="]) {\n      assert'
        '.equal((await send({ mode: "network-smoke", runID: "invalid-base64", attach'
        "ments: [{ data }] })).status, 400);\n    }\n    assert.equal((await send({ "
        'mode: "network-smoke", runID: "maximum",\n      attachments: Array.from({ l'
        'ength: 6 }, () => ({ data: Buffer.alloc(2 * 1024 * 1024).toString("base64")'
        ' })) })).status, 201);\n    const kv = await mf.getKVNamespace("ERROR_REPOR'
        'TS");\n    const binary = "ApwdAA==";\n    const attachmentResponse = await'
        ' send({ mode: "suggestion", comment: "password=fixture-secret",\n      atta'
        'chments: [{ data: binary, name: "password=attachment-secret", contentType: '
        '"application/octet-stream" }] });\n    assert.equal(attachmentResponse.stat'
        "us, 201);\n    const attachmentID = (await attachmentResponse.json()).id;\n"
        "    const attachmentKey = (await kv.list()).keys.find(key => key.name.endsW"
        "ith(attachmentID)).name;\n    const savedAttachment = JSON.parse(await kv.g"
        "et(attachmentKey)).report;\n    assert.equal(savedAttachment.attachments[0]"
        ".data, binary);\n    assert.deepEqual(Buffer.from(savedAttachment.attachmen"
        'ts[0].data, "base64"), Buffer.from(binary, "base64"));\n    assert(!savedAt'
        'tachment.comment.includes("fixture-secret"));\n    assert(!savedAttachment.'
        'attachments[0].name.includes("attachment-secret"));\n    assert.equal((awai'
        't send({ mode: "sanitized", errorTitle: "fixture", errorMessage: "fixture",'
        ' build: { toString: null } })).status, 400);\n    for (const title of ["x".'
        'repeat(1100), "\\u0000".repeat(1100), "𐐀".repeat(1100)]) {\n      const res'
        'ponse = await send({ mode: "sanitized", errorTitle: title, errorMessage: "f'
        'ixture",\n        appVersion: "\\u0000".repeat(1100), build: "1" });\n     '
        " assert.equal(response.status, 201);\n      const id = (await response.json"
        "()).id;\n      const row = (await kv.list()).keys.find(key => key.name.ends"
        "With(id));\n      assert(Buffer.byteLength(JSON.stringify(row.metadata)) <="
        " 1024);\n      assert.equal(JSON.parse(await kv.get(row.name)).report.error"
        "Title, title);\n    }\n    await seed({ day: today, count: 0 });\n    const"
        ' requestID = crypto.randomUUID();\n    const identical = { mode: "suggestio'
        'n", comment: "账号被锁定 (code:1030028)，希望改进认证提示。",\n      errorTitle: "学校账号已锁定"'
        ', errorMessage: "账号被锁定 (code:1030028)", requestID };\n    const receipts = '
        "await Promise.all(Array.from({ length: 5 }, () => send(identical)));\n    f"
        "or (const response of receipts) { assert.equal(response.status, 201); asser"
        "t.equal((await response.json()).id, requestID); }\n    assert.equal((await "
        "inspect()).count, 1);\n    assert.equal((await kv.list()).keys.filter(key ="
        "> key.name.endsWith(requestID)).length, 1);\n    assert.equal((await send({"
        ' ...identical, comment: "changed" })).status, 409);\n    assert.equal((awai'
        't send({ ...identical, requestID: "invalid" })).status, 400);\n    assert.e'
        "qual((await inspect()).count, 1);\n    const source = Object.keys((await in"
        "spect()).sources)[0];\n    assert(/^[a-f0-9]{64}$/.test(source));\n    awai"
        "t seed({ day: today, count: 99, sources: { [source]: 99 } });\n    const co"
        'ncurrent = () => Promise.all(Array.from({ length: 5 }, () => send({ mode: "'
        'suggestion", comment: "fixture" })));\n    const sourceResponses = await co'
        "ncurrent();\n    assert.equal(sourceResponses.filter(response => response.s"
        "tatus === 201).length, 1);\n    assert.equal(sourceResponses.filter(respons"
        "e => response.status === 429).length, 4);\n    assert.equal((await sourceRe"
        'sponses.find(response => response.status === 429).json()).error, "source_li'
        'mit_reached");\n    assert.equal((await send({ mode: "suggestion", comment:'
        ' "fixture" }, "192.0.2.2")).status, 201);\n    await seed({ day: today, cou'
        "nt: 999 });\n    const responses = await concurrent();\n    assert.equal(re"
        "sponses.filter(response => response.status === 201).length, 1);\n    assert"
        ".equal(responses.filter(response => response.status === 429).length, 4);\n "
        "   assert.equal((await inspect()).count, 1000);\n    const nextDay = await "
        'send({ mode: "network-smoke", runID: "fixture" });\n    assert.equal(nextDa'
        "y.status, 201);\n    assert.deepEqual(await nextDay.json(), { ok: true, rec"
        "ordVerified: true, temporaryRecordRemoved: true, quotaReserved: true });\n "
        '   await seed({ day: today, count: 1000 }, "smoke");\n    assert.equal((awa'
        'it send({ mode: "network-smoke", runID: "fixture" })).status, 429);\n    aw'
        'ait seed({ day: "2000-01-01", count: 1000 });\n    assert.equal((await send'
        '({ mode: "suggestion", comment: "fixture" })).status, 201);\n    assert.equ'
        "al((await inspect()).count, 1);\n    assert((await kv.list()).keys.every(ke"
        'y => key.name.startsWith("report:")));\n    await seed({ day: today, count:'
        ' 2000 }, "admission");\n    assert.equal((await send({ mode: "suggestion", '
        'comment: "quota fixture" })).status, 429);\n    const grant = crypto.random'
        "UUID();\n    const grantKey = `report-delete-grant:${grant}`;\n    const re"
        'move = (value = grant) => mf.dispatchFetch("https://feedback.invalid/api/er'
        'ror-reports", {\n      method: "DELETE", headers: { "CF-Connecting-IP": "19'
        '2.0.2.1" }, body: JSON.stringify({ key: attachmentKey, grant: value }) });'
        '\n    const oversizedDeleteBody = "{}".padEnd(1024 + 1);\n    for (const de'
        'claredLength of [false, true]) {\n      const headers = { "CF-Connecting-IP'
        '": "192.0.2.1" };\n      if (declaredLength) headers["content-length"] = St'
        "ring(Buffer.byteLength(oversizedDeleteBody));\n      const body = declaredL"
        "ength ? oversizedDeleteBody : new ReadableStream({ start(controller) {\n   "
        "     controller.enqueue(new TextEncoder().encode(oversizedDeleteBody)); con"
        'troller.close();\n      } });\n      assert.equal((await mf.dispatchFetch("'
        'https://feedback.invalid/api/error-reports", {\n        method: "DELETE", h'
        'eaders, body, duplex: "half" })).status, 413);\n    }\n    assert.equal((aw'
        'ait mf.dispatchFetch("https://feedback.invalid/api/error-reports", {\n     '
        ' method: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" },\n      bod'
        "y: JSON.stringify({ key: attachmentKey, grant }).padEnd(1024) })).status, 4"
        '03);\n    await kv.put(grantKey, JSON.stringify({ key: "report:mismatched" '
        "}));\n    assert.equal((await remove()).status, 403);\n    await kv.put(gra"
        "ntKey, JSON.stringify({ key: attachmentKey }));\n    assert.equal((await re"
        "move()).status, 200);\n    assert.equal(await kv.get(attachmentKey), null);"
        "\n    assert.equal(await kv.get(grantKey), null);\n    assert.equal((await "
        'remove()).status, 403);\n    assert.equal((await send({ mode: "suggestion",'
        ' comment: "quota fixture" })).status, 429);\n    await seed({ day: today, c'
        'ount: 2000 }, "deletion-admission");\n    assert.equal((await remove()).sta'
        'tus, 429);\n    await seed({ day: today, count: 0 }, "admission");\n    ass'
        'ert.equal((await send({ mode: "suggestion", comment: "independent admission'
        '" })).status, 201);\n  } finally { await mf.dispose(); }\n  for (const limi'
        't of ["150", "0", "invalid"]) {\n    const configured = new Miniflare(conve'
        'rtV4MiniflareOptions({ name: "worker-fixture", modules: true, script: fixtu'
        "re,\n      compatibilityDate: config.compatibility_date, bindings: { REPORT"
        "_SOURCE_DAILY_LIMIT: limit },\n      durableObjects: { REPORT_QUOTA: { clas"
        'sName: "QuotaFixture", useSQLite: true } }, log: new Log(LogLevel.NONE) }))'
        ";\n    try {\n      const namespace = await configured.getDurableObjectName"
        'space("REPORT_QUOTA");\n      const quota = namespace.get(namespace.idFromN'
        'ame("daily"));\n      const day = fixtureDay;\n      await quota.fetch("htt'
        'ps://quota/seed", { method: "POST", body: JSON.stringify({ day, count: 149,'
        " sources: { fixture: 149 } }) });\n      const reserve = () => quota.fetch("
        '"https://quota/reserve", { method: "POST", body: JSON.stringify({ source: "'
        'fixture", smoke: false }) });\n      const first = await reserve();\n      '
        'if (limit === "150") {\n        assert.equal((await first.json()).allowed, '
        'true);\n        assert.equal((await (await reserve()).json()).error, "sourc'
        'e_limit_reached");\n        await quota.fetch("https://quota/seed", { metho'
        'd: "POST", body: JSON.stringify({ day, count: 1000 }) });\n        assert.e'
        'qual((await (await reserve()).json()).error, "daily_limit_reached");\n     '
        " } else {\n        assert.equal(first.status, 503);\n        assert.equal(("
        'await first.json()).error, "invalid_source_quota");\n      }\n    } finally'
        " { await configured.dispose(); }\n  }\n  const mailFixture = fs.readFileSyn"
        'c("../ErrorReportWorker/worker.js", "utf8") + `\nexport class DeliveryFixtu'
        "re extends ReportEmailDelivery {\n  async fetch(request) {\n    if (new URL"
        '(request.url).pathname === "/inspect") {\n      return Response.json({ job:'
        ' await this.ctx.storage.get("job"), alarm: await this.ctx.storage.getAlarm('
        ') });\n    }\n    if (new URL(request.url).pathname === "/wake") {\n      a'
        "wait this.ctx.storage.setAlarm(Date.now()); return new Response(null, { sta"
        "tus: 204 });\n    }\n    return super.fetch(request);\n  }\n}`;\n  const ma"
        'il = new Miniflare(convertV4MiniflareOptions({ workers: [\n    { name: "ema'
        'il-acceptance", modules: true, script: mailFixture, compatibilityDate: conf'
        'ig.compatibility_date,\n      kvNamespaces: ["ERROR_REPORTS"], bindings: co'
        'nfig.vars, serviceBindings: { REPORT_EMAIL: "mail-fixture" }, durableObject'
        's: {\n        REPORT_QUOTA: { className: "ReportQuota", useSQLite: true },'
        '\n        REPORT_EMAIL_DELIVERY: { className: "DeliveryFixture", useSQLite:'
        ' true } } },\n    { name: "mail-fixture", modules: true, compatibilityDate:'
        ' config.compatibility_date, kvNamespaces: ["MAIL_STATUS"], script: `\nimpor'
        't { WorkerEntrypoint } from "cloudflare:workers";\nexport default class ext'
        "ends WorkerEntrypoint {\n  async send(message) {\n    const count = Number("
        'await this.env.MAIL_STATUS.get("attempts") || 0) + 1;\n    await this.env.M'
        'AIL_STATUS.put("attempts", String(count));\n    if (await this.env.MAIL_STA'
        'TUS.get("offline") === "1") throw new Error("fixture offline");\n    await '
        'this.env.MAIL_STATUS.put("delivered", String(Number(await this.env.MAIL_STA'
        'TUS.get("delivered") || 0) + 1));\n    return { messageId: "runtime-receipt'
        '" };\n  }\n}` }\n  ], log: new Log(LogLevel.NONE) }));\n  try {\n    const '
        'status = await mail.getKVNamespace("MAIL_STATUS", "mail-fixture");\n    awa'
        'it status.put("offline", "1");\n    const runtimeReport = { mode: "suggesti'
        'on", comment: "runtime fixture", requestID: crypto.randomUUID() };\n    con'
        'st accept = value => mail.dispatchFetch("https://feedback.invalid/api/error'
        '-reports", { method: "POST",\n      headers: { "CF-Connecting-IP": "192.0.2'
        '.1" }, body: JSON.stringify(value) });\n    const accepted = await accept(r'
        "untimeReport);\n    assert.equal(accepted.status, 201);\n    const id = (aw"
        "ait accepted.json()).id;\n    const repeated = await accept({ requestID: ru"
        "ntimeReport.requestID.toUpperCase(), comment: runtimeReport.comment, mode: "
        "runtimeReport.mode });\n    assert.equal(repeated.status, 201); assert.equa"
        "l((await repeated.json()).id, id);\n    const namespace = await mail.getDur"
        'ableObjectNamespace("REPORT_EMAIL_DELIVERY", "email-acceptance");\n    cons'
        "t identifier = namespace.idFromName(id), delivery = namespace.get(identifie"
        'r);\n    const inspect = async () => (await delivery.fetch("https://deliver'
        'y/inspect")).json();\n    const until = async predicate => {\n      const d'
        "eadline = Date.now() + 10000;\n      while (!(await predicate())) { assert("
        'Date.now() < deadline, "Runtime alarm deadline"); await new Promise(resolve'
        " => setTimeout(resolve, 20)); }\n    };\n    await until(async () => Number"
        '(await status.get("attempts")) > 0);\n    await until(async () => (await in'
        "spect()).job.delivery.attempts > 0);\n    await mail.unsafeEvictDurableObje"
        'ct("email-acceptance", "DeliveryFixture", { id: identifier.toString() });\n'
        '    assert.equal((await inspect()).job.delivery.status, "pending");\n    aw'
        'ait status.put("offline", "0");\n    await delivery.fetch("https://delivery'
        '/wake", { method: "POST" });\n    await until(async () => (await inspect())'
        '.job.delivery.status === "sent");\n    const record = (await inspect()).job'
        ';\n    assert.equal(record.delivery.messageID, "runtime-receipt");\n    con'
        'st reports = await mail.getKVNamespace("ERROR_REPORTS", "email-acceptance")'
        ";\n    assert.equal((await reports.list()).keys.length, 1);\n    await unti"
        "l(async () => JSON.parse(await reports.get(record.key)).emailDelivery.statu"
        's === "sent");\n    await mail.unsafeEvictDurableObject("email-acceptance",'
        ' "DeliveryFixture", { id: identifier.toString() });\n    assert.equal((awai'
        't inspect()).job.delivery.status, "sent");\n    await delivery.fetch("https'
        '://delivery/wake", { method: "POST" });\n    await until(async () => (await'
        " inspect()).alarm > Date.now() + 10000);\n    assert.equal(await status.get"
        '("delivered"), "1");\n    assert.equal((await delivery.fetch("https://deliv'
        'ery/delete", { method: "DELETE", body: JSON.stringify({ key: record.key }) '
        '})).status, 200);\n    await mail.unsafeEvictDurableObject("email-acceptanc'
        'e", "DeliveryFixture", { id: identifier.toString() });\n    assert.equal((a'
        "wait inspect()).job.deleted, true);\n    assert.equal(await reports.get(rec"
        "ord.key), null);\n  } finally { await mail.dispose(); }\n  const bodySource"
        ' = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8")\n    .replace('
        "'import { DurableObject } from \"cloudflare:workers\";', 'class DurableObj"
        "ect { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }') + \"\\n"
        "export { readReportBody, MAX_BODY_BYTES, forceRedact, decodedPercent, PROTE"
        'CTED_NAMES, reportEmailSubject, reportEmailBody };";\n  const { default: fe'
        "edback, ReportEmailDelivery, ReportQuota, readReportBody, MAX_BODY_BYTES, f"
        "orceRedact, decodedPercent, PROTECTED_NAMES, reportEmailSubject, reportEmai"
        'lBody } = await import("data:text/javascript;base64," + Buffer.from(bodySou'
        'rce).toString("base64"));\n  const malformedLegacy = { build: { toString: n'
        "ull }, context: { locale: { toString: null } }, diagnosticSummary: { total:"
        " { toString: null } },\n    diagnostics: [{ statusCode: { toString: null },"
        " elapsedMilliseconds: { toString: null }, method: { toString: null } }] };"
        '\n  assert.doesNotThrow(() => reportEmailSubject("fixture", malformedLegacy'
        '));\n  assert.doesNotThrow(() => reportEmailBody("fixture", "fixture", malf'
        'ormedLegacy));\n  const initialURL = "https://sso.bit.edu.cn/cas/login?tick'
        'et=INITIAL_SECRET";\n  const finalURL = "https://jxzxehall.bit.edu.cn/fault'
        '?token=FINAL_SECRET";\n  for (const finalMethod of ["GET", undefined]) {\n '
        '   const message = reportEmailBody("fixture", "fixture", forceRedact({ diag'
        'nostics: [\n      { method: "POST", url: initialURL, finalURL, finalMethod,'
        ' statusCode: 503 }\n    ] }));\n    assert(message.includes("POST https://s'
        'so.bit.edu.cn/cas/login"));\n    assert(message.includes(`→ ${finalMethod |'
        '| "?"} https://jxzxehall.bit.edu.cn/fault`));\n    assert(!message.includes'
        '("INITIAL_SECRET") && !message.includes("FINAL_SECRET"));\n  }\n  assert(!r'
        'eportEmailBody("fixture", "fixture", { diagnostics: [\n    { method: "GET",'
        ' url: initialURL, finalURL: initialURL, finalMethod: "GET", statusCode: 503'
        ' }\n  ] }).includes("→"));\n  let saved = 0, sent = 0, offline = true, fail'
        "StatusWrite = false, failJobWrite = false, failInitialWrite, alarmAt, durin"
        "gSend;\n  let failAcceptanceWrite, failAcceptanceState = false, failAccepta"
        "nceAlarm = false, failExpiryAlarm = false, failInitialJobWrite;\n  const em"
        "ails = [];\n  const records = new Map(), jobs = new Map();\n  const quotaRe"
        "cords = new Map(); let quotaAlarmAt;\n  const reportQuota = new ReportQuota"
        "({ storage: { kv: {\n    get(key) { return structuredClone(quotaRecords.get"
        "(key)); },\n    put(key, value) { quotaRecords.set(key, structuredClone(val"
        "ue)); },\n    list({ prefix }) { return new Map([...quotaRecords].filter((["
        "key]) => key.startsWith(prefix))); },\n    delete(key) { return quotaRecord"
        "s.delete(key); }\n  }, transactionSync(operation) { return operation(); },"
        "\n    async getAlarm() { return quotaAlarmAt ?? null; }, async setAlarm(at)"
        " { quotaAlarmAt = at; }\n  } }, {});\n  const reserve = reservationID => re"
        'portQuota.fetch(new Request("https://quota/reserve", { method: "POST",\n   '
        ' body: JSON.stringify({ source: "quota-fixture", reservationID }) }));\n  c'
        'onst RealDate = Date; let quotaTime = RealDate.parse("2026-01-01T12:00:00Z"'
        ");\n  globalThis.Date = class extends RealDate {\n    constructor(...argume"
        "nts_) { super(...(arguments_.length ? arguments_ : [quotaTime])); }\n    st"
        "atic now() { return quotaTime; }\n  };\n  try {\n    for (let index = 0; in"
        "dex < 100; index++) assert.equal((await (await reserve(`request-${index}`))"
        '.json()).allowed, true);\n    assert.equal((await (await reserve("request-0'
        '")).json()).allowed, true);\n    assert.equal((await (await reserve("new-re'
        'quest")).json()).allowed, false);\n    assert.equal(quotaRecords.get("daily'
        '").count, 100);\n    quotaTime += 24 * 60 * 60 * 1000;\n    assert.equal((a'
        'wait (await reserve("request-0")).json()).allowed, true);\n    assert.equal'
        '(quotaRecords.get("daily").count, 100);\n    assert.equal((await (await res'
        'erve("next-day-request")).json()).allowed, true);\n    assert.equal(quotaRe'
        'cords.get("daily").count, 1);\n    quotaAlarmAt = null; await reportQuota.a'
        "larm(); assert(quotaAlarmAt > quotaTime);\n    quotaTime += 30 * 24 * 60 * "
        "60 * 1000;\n    quotaAlarmAt = null; await reportQuota.alarm();\n    assert"
        '.equal([...quotaRecords.keys()].filter(key => key.startsWith("reservation:"'
        ')).length, 0);\n    assert.equal((await (await reserve("request-0")).json()'
        ').allowed, true);\n    assert.equal(quotaRecords.get("daily").count, 1); as'
        "sert(quotaAlarmAt > quotaTime);\n  } finally { globalThis.Date = RealDate; "
        "}\n  quotaRecords.clear();\n  const storage = {\n    async get(key) { retur"
        "n structuredClone(jobs.get(key)); }, async put(key, value) {\n      if (!va"
        "lue.accepted && failInitialJobWrite) {\n        const committed = failIniti"
        'alJobWrite === "committed"; failInitialJobWrite = null;\n        if (commit'
        'ted) jobs.set(key, structuredClone(value));\n        throw new Error("initi'
        'al job storage unavailable");\n      }\n      if (value.accepted && failAcc'
        'eptanceState) { failAcceptanceState = false; throw new Error("acceptance st'
        'ate unavailable"); }\n      if (value.delivery.status === "sent" && failJob'
        'Write) { failJobWrite = false; throw new Error("job storage unavailable"); '
        "}\n      jobs.set(key, structuredClone(value));\n    },\n    async getAlarm"
        "() { return alarmAt ?? null; },\n    async setAlarm(at) {\n      if (failEx"
        'piryAlarm) { failExpiryAlarm = false; throw new Error("retention alarm unav'
        'ailable"); }\n      if (failAcceptanceAlarm && at < Date.now() + 10000) { f'
        'ailAcceptanceAlarm = false; throw new Error("alarm unavailable"); }\n      '
        "alarmAt = at;\n    }, async deleteAll() { jobs.clear(); }\n  };\n  const em"
        "ailEnv = {\n    ERROR_REPORTS: {\n      async get(key) { return records.get"
        "(key)?.value || null; },\n      async delete(key) { records.delete(key); },"
        "\n      async getWithMetadata(key) { return records.get(key) || { value: nu"
        "ll }; },\n      async put(key, value, options) {\n        if (failAcceptanc"
        'eWrite) {\n          if (failAcceptanceWrite === "committed") records.set(k'
        'ey, { value, metadata: options.metadata });\n          throw new Error("acc'
        'eptance storage unavailable");\n        }\n        if (options.expirationTt'
        'l && failInitialWrite) {\n          if (failInitialWrite === "committed") r'
        "ecords.set(key, { value, metadata: options.metadata });\n          throw ne"
        'w Error("report storage unavailable");\n        }\n        if (options.expi'
        'ration && failStatusWrite) throw new Error("status storage unavailable");\n'
        "        saved += 1; records.set(key, { value, metadata: options.metadata })"
        ";\n        if (options.expirationTtl) assert.equal(options.expirationTtl, 3"
        "0 * 24 * 60 * 60);\n      }\n    },\n    REPORT_QUOTA: { idFromName() {}, g"
        "et() { return { async fetch(url, options) { return reportQuota.fetch(new Re"
        'quest(url, options)); } }; } },\n    REPORT_EMAIL_RECIPIENT: "recipient@fix'
        'ture.invalid",\n    REPORT_EMAIL: { async send(message) {\n      assert.equ'
        'al(message.to, "recipient@fixture.invalid");\n      sent += 1; emails.push('
        'message); if (offline) throw new Error("offline");\n      if (duringSend) {'
        " const callback = duringSend; duringSend = null; await callback(); }\n     "
        ' return { messageId: "fixture-receipt" };\n    } }\n  };\n  let serial = Pr'
        "omise.resolve();\n  const delivery = new ReportEmailDelivery({ storage, blo"
        "ckConcurrencyWhile(callback) {\n    const work = serial.then(callback); ser"
        "ial = work.catch(() => {}); return work;\n  } }, emailEnv);\n  emailEnv.REP"
        "ORT_EMAIL_DELIVERY = { idFromName(id) { return id; }, get(id) { return {\n "
        "   async fetch(url, options) {\n      const input = JSON.parse(options.body"
        ');\n      assert.equal(options.method === "DELETE" ? input.key.split(":").a'
        "t(-1) : input.id, id);\n      return delivery.fetch(new Request(url, option"
        's));\n    }\n  }; } };\n  for (const failure of ["rejected", "committed"]) '
        "{\n    failInitialWrite = failure;\n    const failed = await feedback.fetch"
        '(new Request("https://feedback.invalid/api/error-reports", { method: "POST"'
        ',\n      headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify'
        '({ mode: "suggestion", comment: "fixture" }) }), emailEnv);\n    assert.equ'
        'al(failed.status, 503); assert.equal((await failed.json()).error, "report_s'
        'torage_unavailable");\n    assert.equal(jobs.get("job").deleted, true); ass'
        "ert.equal(records.size, 0);\n    await delivery.alarm(); assert.equal(sent,"
        " 0); jobs.clear();\n  }\n  failInitialWrite = null;\n  for (const failure o"
        'f ["committed", "state"]) {\n    jobs.clear(); records.clear(); quotaRecord'
        "s.clear(); alarmAt = undefined; saved = 0; sent = 0; offline = false;\n    "
        'failAcceptanceWrite = failure === "committed" ? "committed" : null; failAcc'
        'eptanceState = failure === "state";\n    const requestID = crypto.randomUUI'
        'D();\n    const receipt = await feedback.fetch(new Request("https://feedbac'
        'k.invalid/api/error-reports", { method: "POST",\n      headers: { "CF-Conne'
        'cting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", commen'
        't: "alarm recovery", requestID }) }), emailEnv);\n    assert.equal(receipt.'
        'status, 503); assert.equal(records.size, 1); assert.equal(jobs.get("job").a'
        "ccepted, false);\n    assert(alarmAt < Date.now() + 10000); failAcceptanceW"
        'rite = null;\n    await delivery.alarm(); assert.equal(jobs.get("job").acce'
        "pted, true); assert.equal(sent, 1);\n    assert.equal(JSON.parse(records.ge"
        't(jobs.get("job").key).value).report.comment, "alarm recovery");\n    asser'
        't.equal(quotaRecords.get("daily").count, 1);\n    await delivery.alarm(); a'
        'ssert.equal(sent, 1);\n  }\n  for (const failure of ["rejected", "committed'
        '", "state", "alarm", "expiry-alarm", "initial-state", "initial-state-commit'
        'ted"]) {\n    jobs.clear(); records.clear(); quotaRecords.clear(); alarmAt '
        "= undefined; saved = 0; sent = 0; offline = false;\n    failAcceptanceWrite"
        ' = ["rejected", "committed"].includes(failure) ? failure : null;\n    failA'
        'cceptanceState = failure === "state"; failAcceptanceAlarm = failure === "al'
        'arm";\n    failExpiryAlarm = failure === "expiry-alarm";\n    failInitialJo'
        'bWrite = failure === "initial-state" ? "rejected" : failure === "initial-st'
        'ate-committed" ? "committed" : null;\n    const requestID = crypto.randomUU'
        'ID();\n    const sendAttempt = comment => feedback.fetch(new Request("https'
        '://feedback.invalid/api/error-reports", { method: "POST",\n      headers: {'
        ' "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestio'
        'n", comment, requestID }) }), emailEnv);\n    assert.equal((await sendAttem'
        'pt("retained content")).status, 503);\n    const firstKey = jobs.get("job")'
        '?.key;\n    if (failure === "expiry-alarm" || failure === "initial-state") '
        "{ assert.equal(jobs.size, 0); assert.equal(records.size, 0); }\n    assert."
        'equal(quotaRecords.get("daily").count, 1);\n    assert.equal(sent, 0);\n   '
        " failAcceptanceWrite = null;\n    for (let retry = 0; retry < 2; retry++) {"
        '\n      const receipt = await sendAttempt("retained content");\n      asser'
        "t.equal(receipt.status, 201); assert.equal((await receipt.json()).id, reque"
        'stID);\n      assert.equal(quotaRecords.get("daily").count, 1);\n    }\n   '
        ' const key = jobs.get("job").key;\n    assert.equal(records.size, 1); if (f'
        "irstKey) assert.equal(key, firstKey);\n    assert.equal((await sendAttempt("
        '"changed content")).status, 409);\n    await delivery.alarm(); assert.equal'
        '(sent, 1);\n    assert.equal((await sendAttempt("retained content")).status'
        ", 201);\n    await delivery.alarm(); assert.equal(sent, 1);\n    assert.equ"
        'al(JSON.parse(records.get(key).value).report.comment, "retained content");'
        '\n    await delivery.fetch(new Request("https://delivery/delete", { method:'
        ' "DELETE", body: JSON.stringify({ key }) }));\n    assert.equal((await send'
        'Attempt("retained content")).status, 410);\n    const expired = jobs.get("j'
        'ob");\n    expired.receivedAt = new Date(Date.now() - 31 * 24 * 60 * 60 * 1'
        '000).toISOString();\n    jobs.set("job", expired);\n    assert.equal((await'
        ' sendAttempt("retained content")).status, 201);\n    assert.equal(jobs.get('
        '"job").deleted, undefined);\n  }\n  jobs.clear(); records.clear(); alarmAt '
        "= undefined; saved = 0; sent = 0; offline = true;\n  const accepted = await"
        ' feedback.fetch(new Request("https://feedback.invalid/api/error-reports", {'
        ' method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.s'
        'tringify({ mode: "suggestion", comment: "fixture" }) }), {\n    ...emailEnv'
        "\n  });\n  let bodyReads = 0;\n  const blockedBody = new ReadableStream({ p"
        "ull(controller) { bodyReads++; controller.enqueue(new TextEncoder().encode("
        '"fixture")); } }, { highWaterMark: 0 });\n  const blocked = await feedback.'
        'fetch(new Request("https://feedback.invalid/api/error-reports", { method: "'
        'POST", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: blockedBody, dup'
        'lex: "half" }), {\n    ...emailEnv, REPORT_QUOTA: { idFromName() {}, get() '
        '{ return { async fetch() { return Response.json({ allowed: false, error: "s'
        'ource_limit_reached" }); } }; } }\n  });\n  assert.equal(blocked.status, 42'
        "9); assert.equal(bodyReads, 0);\n  assert.equal(accepted.status, 201); asse"
        "rt.equal(saved, 1); assert.equal(sent, 0); assert(alarmAt);\n  await assert"
        '.rejects(delivery.alarm({ retryCount: 0 }));\n  assert.equal(jobs.get("job"'
        ').delivery.status, "pending"); assert.equal(sent, 1);\n  offline = false; f'
        "ailStatusWrite = true;\n  await assert.rejects(delivery.alarm({ retryCount:"
        ' 1 }));\n  assert.equal(jobs.get("job").delivery.status, "sent"); assert.eq'
        "ual(sent, 2);\n  failStatusWrite = false; await delivery.alarm({ retryCount"
        ': 2 });\n  assert.equal(sent, 2);\n  const job = jobs.get("job"), stored = '
        "JSON.parse(records.get(job.key).value);\n  assert.equal(stored.emailDeliver"
        'y.status, "sent"); assert.equal(stored.emailDelivery.messageID, "fixture-re'
        'ceipt");\n  assert.equal(records.get(job.key).metadata.emailStatus, "sent")'
        ";\n  assert.equal(alarmAt, Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 *"
        ' 1000);\n  jobs.set("job", { ...job, delivery: { status: "pending", attempt'
        "s: 0 } }); failJobWrite = true;\n  const beforeJobFailure = sent;\n  await "
        "assert.rejects(delivery.alarm({ retryCount: 0 }));\n  assert.equal(jobs.get"
        '("job").delivery.status, "pending"); assert.equal(jobs.get("job").delivery.'
        "attempts, 1);\n  await delivery.alarm({ retryCount: 1 });\n  assert.equal(s"
        'ent, beforeJobFailure + 2); assert.equal(jobs.get("job").delivery.attempts,'
        ' 2);\n  assert.equal(emails.at(-1).headers["X-BIT101-Report-ID"], job.id);'
        "\n  assert.equal(emails.at(-1).subject, emails.at(-2).subject);\n  assert.e"
        "qual(emails.at(-1).text, emails.at(-2).text);\n  await delivery.alarm({ ret"
        'ryCount: 2 }); assert.equal(sent, beforeJobFailure + 2);\n  jobs.set("job",'
        ' { ...job, delivery: { status: "pending", attempts: 0 } }); offline = true;'
        "\n  for (let retryCount = 0; retryCount < 6; retryCount++) await assert.rej"
        "ects(delivery.alarm({ retryCount }));\n  await delivery.alarm({ retryCount:"
        ' 6 });\n  assert.equal(jobs.get("job").delivery.status, "pending"); assert.'
        'equal(jobs.get("job").delivery.attempts, 7);\n  assert.equal(JSON.parse(rec'
        'ords.get(job.key).value).emailDelivery.status, "pending");\n  assert(alarmA'
        "t > Date.now() && alarmAt < Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 "
        "* 1000);\n  offline = false; await delivery.alarm({ retryCount: 0 });\n  as"
        'sert.equal(jobs.get("job").delivery.status, "sent"); assert.equal(jobs.get('
        '"job").delivery.attempts, 8);\n  assert.equal(JSON.parse(records.get(job.ke'
        'y).value).emailDelivery.status, "sent");\n  failStatusWrite = true;\n  for '
        "(let retryCount = 0; retryCount < 6; retryCount++) await assert.rejects(del"
        "ivery.alarm({ retryCount }));\n  const sentBeforeStatusRecovery = sent;\n  "
        "await delivery.alarm({ retryCount: 6 });\n  assert(alarmAt > Date.now() && "
        "alarmAt < Date.parse(job.receivedAt) + 30 * 24 * 60 * 60 * 1000);\n  failSt"
        "atusWrite = false; await delivery.alarm({ retryCount: 0 });\n  assert.equal"
        "(sent, sentBeforeStatusRecovery);\n  const grant = crypto.randomUUID(), gra"
        'ntKey = "report-delete-grant:" + grant;\n  const deletion = () => feedback.'
        'fetch(new Request("https://feedback.invalid/api/error-reports", {\n    meth'
        'od: "DELETE", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stri'
        "ngify({ key: job.key, grant })\n  }), emailEnv);\n  assert.equal((await del"
        "etion()).status, 403); assert(records.has(job.key));\n  records.set(grantKe"
        'y, { value: JSON.stringify({ key: "report:other" }) });\n  assert.equal((aw'
        "ait deletion()).status, 403); assert(records.has(job.key));\n  records.set("
        'grantKey, { value: JSON.stringify({ key: job.key }) });\n  jobs.set("job", '
        '{ ...job, delivery: { status: "pending", attempts: 0 } });\n  duringSend = '
        "async () => { assert.equal((await deletion()).status, 200); };\n  await del"
        "ivery.alarm();\n  assert(!records.has(job.key)); assert(!records.has(grantK"
        'ey)); assert.equal(jobs.get("job").deleted, true);\n  const sentAfterDeleti'
        "on = sent;\n  await delivery.alarm(); assert.equal(sent, sentAfterDeletion)"
        "; assert(!records.has(job.key));\n  assert.equal((await delivery.fetch(new "
        'Request("https://delivery/queue", { method: "POST", body: JSON.stringify(jo'
        'b) }))).status, 410);\n  jobs.set("job", { ...job, receivedAt: "2000-01-01T'
        '00:00:00Z" }); const attempts = sent;\n  await delivery.alarm(); assert.equ'
        "al(jobs.size, 0); assert.equal(sent, attempts);\n  const originalNow = Date"
        ".now, originalTimeout = globalThis.setTimeout;\n  let clock = originalNow()"
        ";\n  try {\n    Date.now = () => clock;\n    globalThis.setTimeout = (callb"
        "ack, delay) => { clock += delay; queueMicrotask(callback); };\n    for (con"
        'st misses of [0, 2, Infinity, "read-error"]) {\n      let stored, reads = 0'
        ", removed = false;\n      const storage = {\n        async put(key, value, "
        "options) { stored = { value, metadata: options.metadata }; assert(options.e"
        "xpirationTtl * 1000 > 60000); },\n        async getWithMetadata(key, option"
        "s) {\n          reads += 1; assert.equal(options.cacheTtl, 30);\n          "
        'if (misses === "read-error") throw new Error("KV unavailable");\n          '
        "return reads <= misses ? { value: null, metadata: null } : stored;\n       "
        " },\n        async delete() { stored = null; removed = true; }\n      };\n "
        "     const quota = { async fetch() { return Response.json({ allowed: true }"
        "); } };\n      const environment = { ERROR_REPORTS: storage, REPORT_QUOTA: "
        "{ idFromName: name => name, get: () => quota } };\n      const request = ne"
        'w Request("https://feedback.invalid/api/error-reports", { method: "POST",\n'
        '        headers: { "CF-Connecting-IP": "192.0.2.1", "X-BIT101-Network-Smoke'
        '": "1" },\n        body: JSON.stringify({ mode: "network-smoke", runID: "vi'
        'sible-record" }) });\n      if (misses === "read-error") { await assert.rej'
        "ects(feedback.fetch(request, environment), /KV unavailable/); }\n      else"
        " {\n        const response = await feedback.fetch(request, environment);\n "
        "       assert.equal(response.status, misses === Infinity ? 503 : 201);\n   "
        '     if (misses === Infinity) assert.equal((await response.json()).error, "'
        'smoke_visibility_timeout");\n      }\n      assert(removed && stored === nu'
        "ll && reads <= 3);\n    }\n  } finally { Date.now = originalNow; globalThis"
        '.setTimeout = originalTimeout; }\n  const appNames = JSON.parse("[" + fs.re'
        'adFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift", "utf8'
        '").match(/protectedNames = \\[([\\s\\S]*?)\\]/)[1].replace(/,\\s*$/, "") + '
        '"]");\n  assert.deepEqual(PROTECTED_NAMES, appNames);\n  for (const value o'
        'f ["https://example.invalid/?%70assword=TEST_ONLY_SECRET", "https://example'
        '.invalid/?%2570assword=TEST_ONLY_SECRET", "https://example.invalid/?service'
        '=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://exa'
        "mple.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_"
        'SECRET", "https://fixture-user:TEST_ONLY_SECRET@example.invalid/", "https:/'
        '/example.invalid/#%74oken=TEST_ONLY_SECRET", "https://example.invalid/#%257'
        '4oken=TEST_ONLY_SECRET", "https://example.invalid/#%74oken=TEST_ONLY_SECRET'
        '&note=%bad"]) {\n    assert(!decodeURIComponent(forceRedact(value)).include'
        's("TEST_ONLY_SECRET")); assert.equal(forceRedact("https://example.invalid/#'
        'section"), "https://example.invalid/#section");\n  }\n  for (const value of'
        ' ["Authorization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY'
        '_SECRET", "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", \'{"pa'
        'ssword":"TEST_ONLY_\\\\\\"SECRET"}\']) assert(!forceRedact(value).includes('
        '"TEST_ONLY") && !forceRedact(value).includes("SECRET"));\n  const deepPerce'
        'nt = "%" + "25".repeat(20000);\n  const originalDecode = globalThis.decodeU'
        "RIComponent;\n  let decodeCalls = 0;\n  try {\n    globalThis.decodeURIComp"
        "onent = value => { decodeCalls += 1; return originalDecode(value); };\n    "
        "assert.throws(() => decodedPercent(deepPercent), /budget/);\n    assert(dec"
        "odeCalls <= 8);\n  } finally { globalThis.decodeURIComponent = originalDeco"
        "de; }\n  for (const suffix of [`?note=${deepPercent}`, `?${deepPercent}=TES"
        "T_ONLY_SECRET`, `#${deepPercent}`]) {\n    assert.equal(forceRedact(`https:"
        '//example.invalid/${suffix}`), "[REDACTED]");\n  }\n  let deeplyNested = "h'
        'ttps://school.invalid/?ticket=TEST_ONLY_SECRET";\n  for (let pass = 0; pass'
        " < 12; pass += 1) deeplyNested = encodeURIComponent(deeplyNested);\n  asser"
        't.equal(forceRedact(`https://example.invalid/?service=${deeplyNested}`), "['
        'REDACTED]");\n  for (const value of [\'<input id="login-page-flowkey" name='
        '"execution" value="SENSITIVE_VALUE">\', \'<input id="login-croypto" value="'
        'SENSITIVE_VALUE">\', \'<input value="SENSITIVE_VALUE>TAIL_VALUE" name="exec'
        "ution\">', '<input name=\"execution\" value=\"SENSITIVE_VALUE', '<textarea "
        'name="password">SENSITIVE_VALUE</textarea>\', \'<textarea name="password">S'
        'ENSITIVE_VALUE\', \'{"access_token":{"value":"SENSITIVE_VALUE"},"status":"a'
        'vailable"}\', \'{"captcha_payload":["SENSITIVE_VALUE"]}\', \'{"cookie_str":'
        '{"value":"SENSITIVE_VALUE\']) {\n    const masked = forceRedact(value); ass'
        'ert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE") &'
        '& masked.includes("[REDACTED]"));\n    if (value.includes("available")) ass'
        'ert(masked.includes("available"));\n  }\n  for (const value of [\'<span id='
        '"login-page-flowkey">SENSITIVE_VALUE</span>\', \'<span id="login-page-flowk'
        'ey">SENSITIVE_VALUE\',\n    \'<div id="login-page-flowkey">SENSITIVE_VALUE<'
        "/div>',\n    '<p id=\"login-croypto\">SENSITIVE_VALUE</p>',\n    '<div><p"
        ' id="login-page-flowkey">SENSITIVE_VALUE</p><p>available</p></div>\',\n    '
        '\'<div id="login-page-flowkey"><div>SENSITIVE_VALUE</div>TAIL_VALUE</div><p'
        ">available</p>',\n    '<x-field name=\"csrf-token\"><b>SENSITIVE_VALUE</b><"
        "/x-field>',\n    '<p id=\"login-page-flowkey\">SENSITIVE_VALUE',\n    '<m"
        'eta http-equiv="Set-Cookie" content="SENSITIVE_VALUE">\',\n    \'<meta name'
        '="csrf-token" content="SENSITIVE_VALUE">\', \'<meta content="SENSITIVE_VALU'
        'E" property="csrf&#45;token">\',\n    \'<script>const csrfToken = "SENSITIV'
        "E_VALUE;TAIL_VALUE\";</script>', \"<script>var _token = 'SENSITIVE_VALUE;TA"
        'IL_VALUE\';</script>",\n    \'<script>window["csrfToken"] = "SENSITIVE_VALU'
        "E\";</script>', 'csrf_token=SENSITIVE_VALUE',\n    '<input type=\"passwor"
        'd" value="SENSITIVE_VALUE">\', \'<input TYPE=pass&#x77;ord value="SENSITIVE'
        '_VALUE">\',\n    \'<input name="pass&#119;ord" value="SENSITIVE_VALUE">\', '
        '\'<input name="pass&#x77ord" value="SENSITIVE_VALUE">\',\n    \'<textarea n'
        'ame="access&lowbar;token">SENSITIVE_VALUE</textarea>\']) {\n    const maske'
        'd = forceRedact(value);\n    assert(!masked.includes("SENSITIVE_VALUE") && '
        '!masked.includes("TAIL_VALUE"));\n  }\n  const ordinaryInput = \'<input typ'
        'e="text" name="summary" value="visible">\';\n  assert.equal(forceRedact(ord'
        'inaryInput), ordinaryInput);\n  const emergency = (await import("data:text/'
        'javascript;base64," + Buffer.from(fs.readFileSync("src/index.js", "utf8")).'
        'toString("base64"))).default;\n  const notice = { schema_version: 1, enable'
        'd: true, notice_id: "fixture", maximum_affected_build: 100, title: "fixture'
        '", message: "fixture" };\n  for (const [value, status] of [[null, 503], [{ '
        "enabled: false }, 503], [{ schema_version: 1, enabled: false }, 200], [new "
        'Error("offline"), 503], [notice, 200], [{ ...notice, title: " " }, 503], [{'
        " ...notice, maximum_affected_build: 1e20 }, 503]]) {\n    const response = "
        'await emergency.fetch(new Request("https://emergency.invalid/emergency-upda'
        'te.json"), { EMERGENCY_CONFIG: { async get() { if (value instanceof Error) '
        "throw value; return value; } } });\n    assert.equal(response.status, statu"
        's);\n  }\n  for (const args of [["1", " ", "fixture"], ["1", "fixture", " "'
        '], ["9007199254740992", "fixture", "fixture"]]) {\n    assert.equal(require'
        '("node:child_process").spawnSync("zsh", ["Scripts/publish-emergency-update.'
        'sh", ...args]).status, 64);\n  }\n  const publisher = fs.readFileSync("Scri'
        'pts/publish-emergency-update.sh", "utf8").replace(/\\\\\\r?\\n[ \\t]*/g, ""'
        ");\n  assert(publisher.includes('source \"$ROOT_DIR/../../Scripts/script-su"
        "pport.sh\"'));\n  assert(publisher.includes('bit101_acquire_script_lock \"$"
        'HOME/Library/Caches/BIT101-iOS/emergency-publish.lock" BIT101_EMERGENCY_PUB'
        'LISH_LOCK_HELD "$0" "$@"\'));\n  assert(publisher.indexOf("bit101_acquire_s'
        'cript_lock") < publisher.indexOf(\'"$WRANGLER" kv key put\'));\n  let chunk'
        "s = 0, cancelled = false;\n  const stream = new ReadableStream({\n    pull("
        "controller) { chunks += 1; controller.enqueue(new Uint8Array(1024 * 1024));"
        " },\n    cancel() { cancelled = true; }\n  });\n  assert.equal(await readRe"
        'portBody(new Request("https://feedback.invalid", { method: "POST", body: st'
        'ream, duplex: "half" })), null);\n  assert(cancelled && chunks <= Math.floo'
        "r(MAX_BODY_BYTES / (1024 * 1024)) + 2);\n  chunks = 0; cancelled = false;\n"
        "  const deletionStream = new ReadableStream({\n    pull(controller) { chunk"
        "s += 1; controller.enqueue(new Uint8Array(512)); },\n    cancel() { cancell"
        'ed = true; }\n  });\n  assert.equal((await feedback.fetch(new Request("http'
        's://feedback.invalid/api/error-reports", {\n    method: "DELETE", headers: '
        '{ "CF-Connecting-IP": "192.0.2.1" }, body: deletionStream, duplex: "half"\n'
        "  }), emailEnv)).status, 413);\n  assert(cancelled && chunks <= 4);\n  cons"
        "t utf8 = new TextEncoder().encode('文章𐐀');\n  const split = new ReadableStre"
        "am({ start(controller) {\n    for (const byte of utf8) controller.enqueue(n"
        "ew Uint8Array([byte]));\n    controller.close();\n  }});\n  assert.equal(aw"
        'ait readReportBody(new Request("https://feedback.invalid", { method: "POST"'
        ", body: split, duplex: \"half\" })), '文章𐐀');\n  let source = fs.readFileSyn"
        'c("../OpenWorker/worker.js", "utf8");\n  const iconImport = source.match(/^'
        'import shareIcon from "([^"]+)";/);\n  assert(iconImport, "Share icon must '
        'use the app asset");\n  const png = fs.readFileSync(require("node:path").re'
        'solve("../OpenWorker", iconImport[1]));\n  const openConfig = experimental_'
        'readRawConfig({ config: "../OpenWorker/wrangler.jsonc" }).rawConfig;\n  ass'
        'ert(openConfig.rules.some(rule => rule.type === "Data" && rule.globs.includ'
        'es("**/*.png")));\n  source = source.replace(iconImport[0], `const shareIco'
        'n = Uint8Array.from(atob("${png.toString("base64")}"), character => charact'
        'er.charCodeAt(0)).buffer;`);\n  const worker = (await import("data:text/jav'
        'ascript;base64," + Buffer.from(source).toString("base64"))).default;\n  con'
        'st aasa = await (await worker.fetch(new Request("https://open.invalid/.well'
        '-known/apple-app-site-association"))).json();\n  assert.deepEqual(aasa.appl'
        'inks.details[0].paths, ["/gallery/*", "/course/*", "/paper/*"]);\n  for (co'
        'nst route of ["gallery", "course", "paper"]) {\n    const response = await '
        "worker.fetch(new Request(`https://open.invalid/${route}/42`));\n    assert."
        "equal(response.status, 200);\n    const html = await response.text();\n    "
        'assert(html.includes(`href="bit101://${route}/42"`) && html.includes(`href='
        '"https://bit101.cn/${route}/42"`));\n    assert(html.includes(\'<meta prope'
        'rty="og:image:type" content="image/png">\'));\n    assert(html.includes(`<m'
        'eta property="og:image:width" content="${png.readUInt32BE(16)}">`));\n    a'
        'ssert(html.includes(`<meta property="og:image:height" content="${png.readUI'
        'nt32BE(20)}">`));\n    assert(html.includes(`type="image/png" sizes="${png.'
        'readUInt32BE(16)}x${png.readUInt32BE(20)}"`));\n  }\n  for (const route of '
        '["gallery", "course", "paper"]) {\n    for (const id of ["0", "922337203685'
        '4775808", "9".repeat(100)]) {\n      assert.equal((await worker.fetch(new R'
        "equest(`https://open.invalid/${route}/${id}`))).status, 302);\n    }\n    a"
        "ssert.equal((await worker.fetch(new Request(`https://open.invalid/${route}/"
        "9223372036854775807`))).status, 200);\n  }\n  let iconRequests = 0;\n  glob"
        'al.fetch = async () => { iconRequests += 1; throw new Error("upstream unava'
        'ilable"); };\n  for (let attempt = 0; attempt < 2; attempt++) {\n    const '
        'response = await worker.fetch(new Request("https://open.invalid/share-icon.'
        'jpg"));\n    assert.equal(response.status, 200);\n    assert.equal(response'
        '.headers.get("Content-Type"), "image/png");\n    assert.equal(response.head'
        'ers.get("Cache-Control"), "public, max-age=604800");\n    assert.deepEqual('
        "Buffer.from(await response.arrayBuffer()), png);\n  }\n  assert.equal(iconR"
        "equests, 0);\n})().catch(error => { console.error(error); process.exitCode "
        "= 1; });\n"
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
