const fs = require("node:fs");
const { runRuntimeTests } = require("./worker-runtime-tests");
const { runDeliveryTests } = require("./worker-delivery-tests");
const { checkEmailText, runContentTests } = require("./worker-content-tests");

async function run() {
  await runRuntimeTests();
  const bodySource =
    fs
      .readFileSync("../ErrorReportWorker/worker.js", "utf8")
      .replace(
        'import { DurableObject } from "cloudflare:workers";',
        "class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }",
      ) +
    "\nexport { readReportBody, MAX_BODY_BYTES, forceRedact, decodedPercent, " +
    "PROTECTED_NAMES, reportEmailSubject, reportEmailBody };";
  const subject = await import(
    "data:text/javascript;base64," + Buffer.from(bodySource).toString("base64")
  );
  checkEmailText(subject);
  const emailEnv = await runDeliveryTests(subject);
  await runContentTests(subject, emailEnv);
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
