const assert = require("node:assert/strict");
const fs = require("node:fs");
const { experimental_readRawConfig } = require("wrangler");

function checkEmailText({ reportEmailSubject, reportEmailBody, forceRedact }) {
  const malformedLegacy = {
    build: { toString: null },
    context: { locale: { toString: null } },
    diagnosticSummary: { total: { toString: null } },
    diagnostics: [
      {
        statusCode: { toString: null },
        elapsedMilliseconds: { toString: null },
        method: { toString: null },
      },
    ],
  };
  assert.doesNotThrow(() => reportEmailSubject("fixture", malformedLegacy));
  assert.doesNotThrow(() => reportEmailBody("fixture", "fixture", malformedLegacy));
  const initialURL = "https://sso.bit.edu.cn/cas/login?ticket=INITIAL_SECRET";
  const finalURL = "https://jxzxehall.bit.edu.cn/fault?token=FINAL_SECRET";
  for (const finalMethod of ["GET", undefined]) {
    const message = reportEmailBody(
      "fixture",
      "fixture",
      forceRedact({
        diagnostics: [{ method: "POST", url: initialURL, finalURL, finalMethod, statusCode: 503 }],
      }),
    );
    assert(message.includes("POST https://sso.bit.edu.cn/cas/login"));
    assert(message.includes(`→ ${finalMethod || "?"} https://jxzxehall.bit.edu.cn/fault`));
    assert(!message.includes("INITIAL_SECRET") && !message.includes("FINAL_SECRET"));
  }
  assert(
    !reportEmailBody("fixture", "fixture", {
      diagnostics: [
        {
          method: "GET",
          url: initialURL,
          finalURL: initialURL,
          finalMethod: "GET",
          statusCode: 503,
        },
      ],
    }).includes("→"),
  );
}

function checkURLRedaction({ PROTECTED_NAMES, forceRedact, decodedPercent }) {
  const appNames = JSON.parse(
    "[" +
      fs
        .readFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift", "utf8")
        .match(/protectedNames = \[([\s\S]*?)\]/)[1]
        .replace(/,\s*$/, "") +
      "]",
  );
  assert.deepEqual(PROTECTED_NAMES, appNames);
  for (const value of [
    "https://example.invalid/?%70assword=TEST_ONLY_SECRET",
    "https://example.invalid/?%2570assword=TEST_ONLY_SECRET",
    "https://example.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET",
    "https://example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET",
    "https://fixture-user:TEST_ONLY_SECRET@example.invalid/",
    "https://example.invalid/#%74oken=TEST_ONLY_SECRET",
    "https://example.invalid/#%2574oken=TEST_ONLY_SECRET",
    "https://example.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad",
  ]) {
    assert(!decodeURIComponent(forceRedact(value)).includes("TEST_ONLY_SECRET"));
    assert.equal(
      forceRedact("https://example.invalid/#section"),
      "https://example.invalid/#section",
    );
  }
  for (const value of [
    "Authorization: Bearer TEST_ONLY_SECRET",
    "Authorization: Basic TEST_ONLY_SECRET",
    "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET",
    '{"password":"TEST_ONLY_\\\"SECRET"}',
  ])
    assert(!forceRedact(value).includes("TEST_ONLY") && !forceRedact(value).includes("SECRET"));
  const deepPercent = "%" + "25".repeat(20000);
  const originalDecode = globalThis.decodeURIComponent;
  let decodeCalls = 0;
  try {
    globalThis.decodeURIComponent = (value) => {
      decodeCalls += 1;
      return originalDecode(value);
    };
    assert.throws(() => decodedPercent(deepPercent), /budget/);
    assert(decodeCalls <= 8);
  } finally {
    globalThis.decodeURIComponent = originalDecode;
  }
  for (const suffix of [
    `?note=${deepPercent}`,
    `?${deepPercent}=TEST_ONLY_SECRET`,
    `#${deepPercent}`,
  ]) {
    assert.equal(forceRedact(`https://example.invalid/${suffix}`), "[REDACTED]");
  }
  let deeplyNested = "https://school.invalid/?ticket=TEST_ONLY_SECRET";
  for (let pass = 0; pass < 12; pass += 1) deeplyNested = encodeURIComponent(deeplyNested);
  assert.equal(forceRedact(`https://example.invalid/?service=${deeplyNested}`), "[REDACTED]");
}

function checkMarkupRedaction({ forceRedact }) {
  for (const value of [
    '<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">',
    '<input id="login-croypto" value="SENSITIVE_VALUE">',
    '<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">',
    '<input name="execution" value="SENSITIVE_VALUE',
    '<textarea name="password">SENSITIVE_VALUE</textarea>',
    '<textarea name="password">SENSITIVE_VALUE',
    '{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}',
    '{"captcha_payload":["SENSITIVE_VALUE"]}',
    '{"cookie_str":{"value":"SENSITIVE_VALUE',
  ]) {
    const masked = forceRedact(value);
    assert(
      !masked.includes("SENSITIVE_VALUE") &&
        !masked.includes("TAIL_VALUE") &&
        masked.includes("[REDACTED]"),
    );
    if (value.includes("available")) assert(masked.includes("available"));
  }
  for (const value of [
    '<span id="login-page-flowkey">SENSITIVE_VALUE</span>',
    '<span id="login-page-flowkey">SENSITIVE_VALUE',
    '<div id="login-page-flowkey">SENSITIVE_VALUE</div>',
    '<p id="login-croypto">SENSITIVE_VALUE</p>',
    '<div><p id="login-page-flowkey">SENSITIVE_VALUE</p><p>available</p></div>',
    '<div id="login-page-flowkey"><div>SENSITIVE_VALUE</div>TAIL_VALUE</div><p>available</p>',
    '<x-field name="csrf-token"><b>SENSITIVE_VALUE</b></x-field>',
    '<p id="login-page-flowkey">SENSITIVE_VALUE',
    '<meta http-equiv="Set-Cookie" content="SENSITIVE_VALUE">',
    '<meta name="csrf-token" content="SENSITIVE_VALUE">',
    '<meta content="SENSITIVE_VALUE" property="csrf&#45;token">',
    '<script>const csrfToken = "SENSITIVE_VALUE;TAIL_VALUE";</script>',
    "<script>var _token = 'SENSITIVE_VALUE;TAIL_VALUE';</script>",
    '<script>window["csrfToken"] = "SENSITIVE_VALUE";</script>',
    "csrf_token=SENSITIVE_VALUE",
    '<input type="password" value="SENSITIVE_VALUE">',
    '<input TYPE=pass&#x77;ord value="SENSITIVE_VALUE">',
    '<input name="pass&#119;ord" value="SENSITIVE_VALUE">',
    '<input name="pass&#x77ord" value="SENSITIVE_VALUE">',
    '<textarea name="access&lowbar;token">SENSITIVE_VALUE</textarea>',
  ]) {
    const masked = forceRedact(value);
    assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE"));
  }
  const ordinaryInput = '<input type="text" name="summary" value="visible">';
  assert.equal(forceRedact(ordinaryInput), ordinaryInput);
}

async function checkEmergencyNotices() {
  const emergency = (
    await import(
      "data:text/javascript;base64," +
        Buffer.from(fs.readFileSync("src/index.js", "utf8")).toString("base64")
    )
  ).default;
  const notice = {
    schema_version: 1,
    enabled: true,
    notice_id: "fixture",
    maximum_affected_build: 100,
    title: "fixture",
    message: "fixture",
  };
  for (const [value, status] of [
    [null, 503],
    [{ enabled: false }, 503],
    [{ schema_version: 1, enabled: false }, 200],
    [new Error("offline"), 503],
    [notice, 200],
    [{ ...notice, title: " " }, 503],
    [{ ...notice, maximum_affected_build: 1e20 }, 503],
  ]) {
    const response = await emergency.fetch(
      new Request("https://emergency.invalid/emergency-update.json"),
      {
        EMERGENCY_CONFIG: {
          async get() {
            if (value instanceof Error) throw value;
            return value;
          },
        },
      },
    );
    assert.equal(response.status, status);
  }
  for (const args of [
    ["1", " ", "fixture"],
    ["1", "fixture", " "],
    ["9007199254740992", "fixture", "fixture"],
  ]) {
    assert.equal(
      require("node:child_process").spawnSync("zsh", [
        "Scripts/publish-emergency-update.sh",
        ...args,
      ]).status,
      64,
    );
  }
  const publisher = fs
    .readFileSync("Scripts/publish-emergency-update.sh", "utf8")
    .replace(/\\\r?\n[ \t]*/g, "");
  assert(publisher.includes('source "$ROOT_DIR/../../Scripts/script-support.sh"'));
  assert(
    publisher.includes(
      'bit101_acquire_script_lock "$HOME/Library/Caches/BIT101-iOS/emergency-publish.lock" ' +
        'BIT101_EMERGENCY_PUBLISH_LOCK_HELD "$0" "$@"',
    ),
  );
  assert(
    publisher.indexOf("bit101_acquire_script_lock") < publisher.indexOf('"$WRANGLER" kv key put'),
  );
}

async function checkRequestStreams(
  { readReportBody, MAX_BODY_BYTES, default: feedback },
  emailEnv,
) {
  let chunks = 0,
    cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      chunks += 1;
      controller.enqueue(new Uint8Array(1024 * 1024));
    },
    cancel() {
      cancelled = true;
    },
  });
  assert.equal(
    await readReportBody(
      new Request("https://feedback.invalid", { method: "POST", body: stream, duplex: "half" }),
    ),
    null,
  );
  assert(cancelled && chunks <= Math.floor(MAX_BODY_BYTES / (1024 * 1024)) + 2);
  chunks = 0;
  cancelled = false;
  const deletionStream = new ReadableStream({
    pull(controller) {
      chunks += 1;
      controller.enqueue(new Uint8Array(512));
    },
    cancel() {
      cancelled = true;
    },
  });
  assert.equal(
    (
      await feedback.fetch(
        new Request("https://feedback.invalid/api/error-reports", {
          method: "DELETE",
          headers: { "CF-Connecting-IP": "192.0.2.1" },
          body: deletionStream,
          duplex: "half",
        }),
        emailEnv,
      )
    ).status,
    413,
  );
  assert(cancelled && chunks <= 4);
  const utf8 = new TextEncoder().encode("文章𐐀");
  const split = new ReadableStream({
    start(controller) {
      for (const byte of utf8) controller.enqueue(new Uint8Array([byte]));
      controller.close();
    },
  });
  assert.equal(
    await readReportBody(
      new Request("https://feedback.invalid", { method: "POST", body: split, duplex: "half" }),
    ),
    "文章𐐀",
  );
}

async function checkOpenWorker() {
  let source = fs.readFileSync("../OpenWorker/worker.js", "utf8");
  const iconImport = source.match(/^import shareIcon from "([^"]+)";/);
  assert(iconImport, "Share icon must use the app asset");
  const png = fs.readFileSync(require("node:path").resolve("../OpenWorker", iconImport[1]));
  const openConfig = experimental_readRawConfig({
    config: "../OpenWorker/wrangler.jsonc",
  }).rawConfig;
  assert(openConfig.rules.some((rule) => rule.type === "Data" && rule.globs.includes("**/*.png")));
  source = source.replace(
    iconImport[0],
    `const shareIcon = Uint8Array.from(atob("${png.toString("base64")}"), ` +
      "character => character.charCodeAt(0)).buffer;",
  );
  const worker = (
    await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"))
  ).default;
  const aasa = await (
    await worker.fetch(new Request("https://open.invalid/.well-known/apple-app-site-association"))
  ).json();
  assert.deepEqual(aasa.applinks.details[0].paths, ["/gallery/*", "/course/*", "/paper/*"]);
  for (const route of ["gallery", "course", "paper"]) {
    const response = await worker.fetch(new Request(`https://open.invalid/${route}/42`));
    assert.equal(response.status, 200);
    const html = await response.text();
    assert(
      html.includes(`href="bit101://${route}/42"`) &&
        html.includes(`href="https://bit101.cn/${route}/42"`),
    );
    assert(html.includes('<meta property="og:image:type" content="image/png">'));
    assert(html.includes(`<meta property="og:image:width" content="${png.readUInt32BE(16)}">`));
    assert(html.includes(`<meta property="og:image:height" content="${png.readUInt32BE(20)}">`));
    assert(
      html.includes(`type="image/png" sizes="${png.readUInt32BE(16)}x${png.readUInt32BE(20)}"`),
    );
  }
  for (const route of ["gallery", "course", "paper"]) {
    for (const id of ["0", "9223372036854775808", "9".repeat(100)]) {
      assert.equal(
        (await worker.fetch(new Request(`https://open.invalid/${route}/${id}`))).status,
        302,
      );
    }
    assert.equal(
      (await worker.fetch(new Request(`https://open.invalid/${route}/9223372036854775807`))).status,
      200,
    );
  }
  let iconRequests = 0;
  const originalFetch = global.fetch;
  try {
    global.fetch = async () => {
      iconRequests += 1;
      throw new Error("upstream unavailable");
    };
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await worker.fetch(new Request("https://open.invalid/share-icon.jpg"));
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("Content-Type"), "image/png");
      assert.equal(response.headers.get("Cache-Control"), "public, max-age=604800");
      assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
    }
    assert.equal(iconRequests, 0);
  } finally {
    global.fetch = originalFetch;
  }
}

async function runContentTests(subject, emailEnv) {
  checkURLRedaction(subject);
  checkMarkupRedaction(subject);
  await checkEmergencyNotices();
  await checkRequestStreams(subject, emailEnv);
  await checkOpenWorker();
}

module.exports = { checkEmailText, runContentTests };
