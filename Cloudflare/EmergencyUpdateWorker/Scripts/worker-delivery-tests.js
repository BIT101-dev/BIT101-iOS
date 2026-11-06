const assert = require("node:assert/strict");

function createDeliveryState({ default: feedback, ReportQuota }) {
  const state = {
    feedback,
    saved: 0,
    sent: 0,
    offline: true,
    failStatusWrite: false,
    failJobWrite: false,
    failAcceptanceState: false,
    failAcceptanceAlarm: false,
    failExpiryAlarm: false,
    emails: [],
    records: new Map(),
    jobs: new Map(),
    quotaRecords: new Map(),
  };
  state.reportQuota = new ReportQuota(
    {
      storage: {
        kv: {
          get(key) {
            return structuredClone(state.quotaRecords.get(key));
          },
          put(key, value) {
            state.quotaRecords.set(key, structuredClone(value));
          },
          list({ prefix }) {
            return new Map([...state.quotaRecords].filter(([key]) => key.startsWith(prefix)));
          },
          delete(key) {
            return state.quotaRecords.delete(key);
          },
        },
        transactionSync(operation) {
          return operation();
        },
        async getAlarm() {
          return state.quotaAlarmAt ?? null;
        },
        async setAlarm(at) {
          state.quotaAlarmAt = at;
        },
      },
    },
    {},
  );
  return state;
}

function initializeDelivery(state, { ReportEmailDelivery }) {
  state.storage = {
    async get(key) {
      return structuredClone(state.jobs.get(key));
    },
    async put(key, value) {
      if (!value.accepted && state.failInitialJobWrite) {
        const committed = state.failInitialJobWrite === "committed";
        state.failInitialJobWrite = null;
        if (committed) state.jobs.set(key, structuredClone(value));
        throw new Error("initial job storage unavailable");
      }
      if (value.accepted && state.failAcceptanceState) {
        state.failAcceptanceState = false;
        throw new Error("acceptance state unavailable");
      }
      if (value.delivery.status === "sent" && state.failJobWrite) {
        state.failJobWrite = false;
        throw new Error("job storage unavailable");
      }
      state.jobs.set(key, structuredClone(value));
    },
    async getAlarm() {
      return state.alarmAt ?? null;
    },
    async setAlarm(at) {
      if (state.failExpiryAlarm) {
        state.failExpiryAlarm = false;
        throw new Error("retention alarm unavailable");
      }
      if (state.failAcceptanceAlarm && at < Date.now() + 10000) {
        state.failAcceptanceAlarm = false;
        throw new Error("alarm unavailable");
      }
      state.alarmAt = at;
    },
    async deleteAll() {
      state.jobs.clear();
    },
  };
  state.emailEnv = {
    ERROR_REPORTS: {
      async get(key) {
        return state.records.get(key)?.value || null;
      },
      async delete(key) {
        state.records.delete(key);
      },
      async getWithMetadata(key) {
        return state.records.get(key) || { value: null };
      },
      async put(key, value, options) {
        if (state.failAcceptanceWrite) {
          if (state.failAcceptanceWrite === "committed")
            state.records.set(key, { value, metadata: options.metadata });
          throw new Error("acceptance storage unavailable");
        }
        if (options.expirationTtl && state.failInitialWrite) {
          if (state.failInitialWrite === "committed")
            state.records.set(key, { value, metadata: options.metadata });
          throw new Error("report storage unavailable");
        }
        if (options.expiration && state.failStatusWrite)
          throw new Error("status storage unavailable");
        state.saved += 1;
        state.records.set(key, { value, metadata: options.metadata });
        if (options.expirationTtl) assert.equal(options.expirationTtl, 30 * 24 * 60 * 60);
      },
    },
    REPORT_QUOTA: {
      idFromName() {},
      get() {
        return {
          async fetch(url, options) {
            return state.reportQuota.fetch(new Request(url, options));
          },
        };
      },
    },
    REPORT_EMAIL_RECIPIENT: "recipient@fixture.invalid",
    REPORT_EMAIL: {
      async send(message) {
        assert.equal(message.to, "recipient@fixture.invalid");
        state.sent += 1;
        state.emails.push(message);
        if (state.offline) throw new Error("offline");
        if (state.duringSend) {
          const callback = state.duringSend;
          state.duringSend = null;
          await callback();
        }
        return { messageId: "fixture-receipt" };
      },
    },
  };
  let serial = Promise.resolve();
  state.delivery = new ReportEmailDelivery(
    {
      storage: state.storage,
      blockConcurrencyWhile(callback) {
        const work = serial.then(callback);
        serial = work.catch(() => {});
        return work;
      },
    },
    state.emailEnv,
  );
  state.emailEnv.REPORT_EMAIL_DELIVERY = {
    idFromName(id) {
      return id;
    },
    get(id) {
      return {
        async fetch(url, options) {
          const input = JSON.parse(options.body);
          assert.equal(options.method === "DELETE" ? input.key.split(":").at(-1) : input.id, id);
          return state.delivery.fetch(new Request(url, options));
        },
      };
    },
  };
}

async function checkQuotaRetention(state) {
  const reserve = (reservationID) =>
    state.reportQuota.fetch(
      new Request("https://quota/reserve", {
        method: "POST",
        body: JSON.stringify({ source: "quota-fixture", reservationID }),
      }),
    );
  const RealDate = Date;
  let quotaTime = RealDate.parse("2026-01-01T12:00:00Z");
  globalThis.Date = class extends RealDate {
    constructor(...arguments_) {
      super(...(arguments_.length ? arguments_ : [quotaTime]));
    }
    static now() {
      return quotaTime;
    }
  };
  try {
    for (let index = 0; index < 100; index++)
      assert.equal((await (await reserve(`request-${index}`)).json()).allowed, true);
    assert.equal((await (await reserve("request-0")).json()).allowed, true);
    assert.equal((await (await reserve("new-request")).json()).allowed, false);
    assert.equal(state.quotaRecords.get("daily").count, 100);
    quotaTime += 24 * 60 * 60 * 1000;
    assert.equal((await (await reserve("request-0")).json()).allowed, true);
    assert.equal(state.quotaRecords.get("daily").count, 100);
    assert.equal((await (await reserve("next-day-request")).json()).allowed, true);
    assert.equal(state.quotaRecords.get("daily").count, 1);
    state.quotaAlarmAt = null;
    await state.reportQuota.alarm();
    assert(state.quotaAlarmAt > quotaTime);
    quotaTime += 30 * 24 * 60 * 60 * 1000;
    state.quotaAlarmAt = null;
    await state.reportQuota.alarm();
    assert.equal(
      [...state.quotaRecords.keys()].filter((key) => key.startsWith("reservation:")).length,
      0,
    );
    assert.equal((await (await reserve("request-0")).json()).allowed, true);
    assert.equal(state.quotaRecords.get("daily").count, 1);
    assert(state.quotaAlarmAt > quotaTime);
  } finally {
    globalThis.Date = RealDate;
  }
  state.quotaRecords.clear();
}

async function checkInitialStorageFailure(state) {
  for (const failure of ["rejected", "committed"]) {
    state.failInitialWrite = failure;
    const failed = await state.feedback.fetch(
      new Request("https://feedback.invalid/api/error-reports", {
        method: "POST",
        headers: { "CF-Connecting-IP": "192.0.2.1" },
        body: JSON.stringify({ mode: "suggestion", comment: "fixture" }),
      }),
      state.emailEnv,
    );
    assert.equal(failed.status, 503);
    assert.equal((await failed.json()).error, "report_storage_unavailable");
    assert.equal(state.jobs.get("job").deleted, true);
    assert.equal(state.records.size, 0);
    await state.delivery.alarm();
    assert.equal(state.sent, 0);
    state.jobs.clear();
  }
  state.failInitialWrite = null;
}

async function checkAcceptanceAlarmRecovery(state) {
  for (const failure of ["committed", "state"]) {
    state.jobs.clear();
    state.records.clear();
    state.quotaRecords.clear();
    state.alarmAt = undefined;
    state.saved = 0;
    state.sent = 0;
    state.offline = false;
    state.failAcceptanceWrite = failure === "committed" ? "committed" : null;
    state.failAcceptanceState = failure === "state";
    const requestID = crypto.randomUUID();
    const receipt = await state.feedback.fetch(
      new Request("https://feedback.invalid/api/error-reports", {
        method: "POST",
        headers: { "CF-Connecting-IP": "192.0.2.1" },
        body: JSON.stringify({ mode: "suggestion", comment: "alarm recovery", requestID }),
      }),
      state.emailEnv,
    );
    assert.equal(receipt.status, 503);
    assert.equal(state.records.size, 1);
    assert.equal(state.jobs.get("job").accepted, false);
    assert(state.alarmAt < Date.now() + 10000);
    state.failAcceptanceWrite = null;
    await state.delivery.alarm();
    assert.equal(state.jobs.get("job").accepted, true);
    assert.equal(state.sent, 1);
    assert.equal(
      JSON.parse(state.records.get(state.jobs.get("job").key).value).report.comment,
      "alarm recovery",
    );
    assert.equal(state.quotaRecords.get("daily").count, 1);
    await state.delivery.alarm();
    assert.equal(state.sent, 1);
  }
}

async function checkAcceptanceRetries(state) {
  for (const failure of [
    "rejected",
    "committed",
    "state",
    "alarm",
    "expiry-alarm",
    "initial-state",
    "initial-state-committed",
  ]) {
    state.jobs.clear();
    state.records.clear();
    state.quotaRecords.clear();
    state.alarmAt = undefined;
    state.saved = 0;
    state.sent = 0;
    state.offline = false;
    state.failAcceptanceWrite = ["rejected", "committed"].includes(failure) ? failure : null;
    state.failAcceptanceState = failure === "state";
    state.failAcceptanceAlarm = failure === "alarm";
    state.failExpiryAlarm = failure === "expiry-alarm";
    state.failInitialJobWrite =
      failure === "initial-state"
        ? "rejected"
        : failure === "initial-state-committed"
          ? "committed"
          : null;
    const requestID = crypto.randomUUID();
    const sendAttempt = (comment) =>
      state.feedback.fetch(
        new Request("https://feedback.invalid/api/error-reports", {
          method: "POST",
          headers: { "CF-Connecting-IP": "192.0.2.1" },
          body: JSON.stringify({ mode: "suggestion", comment, requestID }),
        }),
        state.emailEnv,
      );
    assert.equal((await sendAttempt("retained content")).status, 503);
    const firstKey = state.jobs.get("job")?.key;
    if (failure === "expiry-alarm" || failure === "initial-state") {
      assert.equal(state.jobs.size, 0);
      assert.equal(state.records.size, 0);
    }
    assert.equal(state.quotaRecords.get("daily").count, 1);
    assert.equal(state.sent, 0);
    state.failAcceptanceWrite = null;
    for (let retry = 0; retry < 2; retry++) {
      const receipt = await sendAttempt("retained content");
      assert.equal(receipt.status, 201);
      assert.equal((await receipt.json()).id, requestID);
      assert.equal(state.quotaRecords.get("daily").count, 1);
    }
    const key = state.jobs.get("job").key;
    assert.equal(state.records.size, 1);
    if (firstKey) assert.equal(key, firstKey);
    assert.equal((await sendAttempt("changed content")).status, 409);
    await state.delivery.alarm();
    assert.equal(state.sent, 1);
    assert.equal((await sendAttempt("retained content")).status, 201);
    await state.delivery.alarm();
    assert.equal(state.sent, 1);
    assert.equal(JSON.parse(state.records.get(key).value).report.comment, "retained content");
    await state.delivery.fetch(
      new Request("https://delivery/delete", { method: "DELETE", body: JSON.stringify({ key }) }),
    );
    assert.equal((await sendAttempt("retained content")).status, 410);
    const expired = state.jobs.get("job");
    expired.receivedAt = new Date(Date.now() - 31 * 24 * 60 * 60 * 1000).toISOString();
    state.jobs.set("job", expired);
    assert.equal((await sendAttempt("retained content")).status, 201);
    assert.equal(state.jobs.get("job").deleted, undefined);
  }
}

async function checkDeliveryStatusRecovery(state) {
  state.jobs.clear();
  state.records.clear();
  state.alarmAt = undefined;
  state.saved = 0;
  state.sent = 0;
  state.offline = true;
  const accepted = await state.feedback.fetch(
    new Request("https://feedback.invalid/api/error-reports", {
      method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.1" },
      body: JSON.stringify({ mode: "suggestion", comment: "fixture" }),
    }),
    {
      ...state.emailEnv,
    },
  );
  let bodyReads = 0;
  const blockedBody = new ReadableStream(
    {
      pull(controller) {
        bodyReads++;
        controller.enqueue(new TextEncoder().encode("fixture"));
      },
    },
    { highWaterMark: 0 },
  );
  const blocked = await state.feedback.fetch(
    new Request("https://feedback.invalid/api/error-reports", {
      method: "POST",
      headers: { "CF-Connecting-IP": "192.0.2.1" },
      body: blockedBody,
      duplex: "half",
    }),
    {
      ...state.emailEnv,
      REPORT_QUOTA: {
        idFromName() {},
        get() {
          return {
            async fetch() {
              return Response.json({ allowed: false, error: "source_limit_reached" });
            },
          };
        },
      },
    },
  );
  assert.equal(blocked.status, 429);
  assert.equal(bodyReads, 0);
  assert.equal(accepted.status, 201);
  assert.equal(state.saved, 1);
  assert.equal(state.sent, 0);
  assert(state.alarmAt);
  await assert.rejects(state.delivery.alarm({ retryCount: 0 }));
  assert.equal(state.jobs.get("job").delivery.status, "pending");
  assert.equal(state.sent, 1);
  state.offline = false;
  state.failStatusWrite = true;
  await assert.rejects(state.delivery.alarm({ retryCount: 1 }));
  assert.equal(state.jobs.get("job").delivery.status, "sent");
  assert.equal(state.sent, 2);
  state.failStatusWrite = false;
  await state.delivery.alarm({ retryCount: 2 });
  assert.equal(state.sent, 2);
  ((state.job = state.jobs.get("job")),
    (stored = JSON.parse(state.records.get(state.job.key).value)));
  assert.equal(stored.emailDelivery.status, "sent");
  assert.equal(stored.emailDelivery.messageID, "fixture-receipt");
  assert.equal(state.records.get(state.job.key).metadata.emailStatus, "sent");
  assert.equal(state.alarmAt, Date.parse(state.job.receivedAt) + 30 * 24 * 60 * 60 * 1000);
}

async function checkDeliveryRetryRecovery(state) {
  state.jobs.set("job", { ...state.job, delivery: { status: "pending", attempts: 0 } });
  state.failJobWrite = true;
  const beforeJobFailure = state.sent;
  await assert.rejects(state.delivery.alarm({ retryCount: 0 }));
  assert.equal(state.jobs.get("job").delivery.status, "pending");
  assert.equal(state.jobs.get("job").delivery.attempts, 1);
  await state.delivery.alarm({ retryCount: 1 });
  assert.equal(state.sent, beforeJobFailure + 2);
  assert.equal(state.jobs.get("job").delivery.attempts, 2);
  assert.equal(state.emails.at(-1).headers["X-BIT101-Report-ID"], state.job.id);
  assert.equal(state.emails.at(-1).subject, state.emails.at(-2).subject);
  assert.equal(state.emails.at(-1).text, state.emails.at(-2).text);
  await state.delivery.alarm({ retryCount: 2 });
  assert.equal(state.sent, beforeJobFailure + 2);
  state.jobs.set("job", { ...state.job, delivery: { status: "pending", attempts: 0 } });
  state.offline = true;
  for (let retryCount = 0; retryCount < 6; retryCount++)
    await assert.rejects(state.delivery.alarm({ retryCount }));
  await state.delivery.alarm({ retryCount: 6 });
  assert.equal(state.jobs.get("job").delivery.status, "pending");
  assert.equal(state.jobs.get("job").delivery.attempts, 7);
  assert.equal(JSON.parse(state.records.get(state.job.key).value).emailDelivery.status, "pending");
  assert(
    state.alarmAt > Date.now() &&
      state.alarmAt < Date.parse(state.job.receivedAt) + 30 * 24 * 60 * 60 * 1000,
  );
  state.offline = false;
  await state.delivery.alarm({ retryCount: 0 });
  assert.equal(state.jobs.get("job").delivery.status, "sent");
  assert.equal(state.jobs.get("job").delivery.attempts, 8);
  assert.equal(JSON.parse(state.records.get(state.job.key).value).emailDelivery.status, "sent");
  state.failStatusWrite = true;
  for (let retryCount = 0; retryCount < 6; retryCount++)
    await assert.rejects(state.delivery.alarm({ retryCount }));
  const sentBeforeStatusRecovery = state.sent;
  await state.delivery.alarm({ retryCount: 6 });
  assert(
    state.alarmAt > Date.now() &&
      state.alarmAt < Date.parse(state.job.receivedAt) + 30 * 24 * 60 * 60 * 1000,
  );
  state.failStatusWrite = false;
  await state.delivery.alarm({ retryCount: 0 });
  assert.equal(state.sent, sentBeforeStatusRecovery);
}

async function checkDeletionDuringDelivery(state) {
  const grant = crypto.randomUUID(),
    grantKey = "report-delete-grant:" + grant;
  const deletion = () =>
    state.feedback.fetch(
      new Request("https://feedback.invalid/api/error-reports", {
        method: "DELETE",
        headers: { "CF-Connecting-IP": "192.0.2.1" },
        body: JSON.stringify({ key: state.job.key, grant }),
      }),
      state.emailEnv,
    );
  assert.equal((await deletion()).status, 403);
  assert(state.records.has(state.job.key));
  state.records.set(grantKey, { value: JSON.stringify({ key: "report:other" }) });
  assert.equal((await deletion()).status, 403);
  assert(state.records.has(state.job.key));
  state.records.set(grantKey, { value: JSON.stringify({ key: state.job.key }) });
  state.jobs.set("job", { ...state.job, delivery: { status: "pending", attempts: 0 } });
  state.duringSend = async () => {
    assert.equal((await deletion()).status, 200);
  };
  await state.delivery.alarm();
  assert(!state.records.has(state.job.key));
  assert(!state.records.has(grantKey));
  assert.equal(state.jobs.get("job").deleted, true);
  const sentAfterDeletion = state.sent;
  await state.delivery.alarm();
  assert.equal(state.sent, sentAfterDeletion);
  assert(!state.records.has(state.job.key));
  assert.equal(
    (
      await state.delivery.fetch(
        new Request("https://delivery/queue", { method: "POST", body: JSON.stringify(state.job) }),
      )
    ).status,
    410,
  );
  state.jobs.set("job", { ...state.job, receivedAt: "2000-01-01T00:00:00Z" });
  const attempts = state.sent;
  await state.delivery.alarm();
  assert.equal(state.jobs.size, 0);
  assert.equal(state.sent, attempts);
}

async function checkRecordVisibility(feedback) {
  const originalNow = Date.now,
    originalTimeout = globalThis.setTimeout;
  let clock = originalNow();
  try {
    Date.now = () => clock;
    globalThis.setTimeout = (callback, delay) => {
      clock += delay;
      queueMicrotask(callback);
    };
    for (const misses of [0, 2, Infinity, "read-error"]) {
      let stored,
        reads = 0,
        removed = false;
      const storage = {
        async put(key, value, options) {
          stored = { value, metadata: options.metadata };
          assert(options.expirationTtl * 1000 > 60000);
        },
        async getWithMetadata(key, options) {
          reads += 1;
          assert.equal(options.cacheTtl, 30);
          if (misses === "read-error") throw new Error("KV unavailable");
          return reads <= misses ? { value: null, metadata: null } : stored;
        },
        async delete() {
          stored = null;
          removed = true;
        },
      };
      const quota = {
        async fetch() {
          return Response.json({ allowed: true });
        },
      };
      const environment = {
        ERROR_REPORTS: storage,
        REPORT_QUOTA: { idFromName: (name) => name, get: () => quota },
      };
      const request = new Request("https://feedback.invalid/api/error-reports", {
        method: "POST",
        headers: { "CF-Connecting-IP": "192.0.2.1", "X-BIT101-Network-Smoke": "1" },
        body: JSON.stringify({ mode: "network-smoke", runID: "visible-record" }),
      });
      if (misses === "read-error") {
        await assert.rejects(feedback.fetch(request, environment), /KV unavailable/);
      } else {
        const response = await feedback.fetch(request, environment);
        assert.equal(response.status, misses === Infinity ? 503 : 201);
        if (misses === Infinity)
          assert.equal((await response.json()).error, "smoke_visibility_timeout");
      }
      assert(removed && stored === null && reads <= 3);
    }
  } finally {
    Date.now = originalNow;
    globalThis.setTimeout = originalTimeout;
  }
}

async function runDeliveryTests(subject) {
  const state = createDeliveryState(subject);
  await checkQuotaRetention(state);
  initializeDelivery(state, subject);
  await checkInitialStorageFailure(state);
  await checkAcceptanceAlarmRecovery(state);
  await checkAcceptanceRetries(state);
  await checkDeliveryStatusRecovery(state);
  await checkDeliveryRetryRecovery(state);
  await checkDeletionDuringDelivery(state);
  await checkRecordVisibility(state.feedback);
  return state.emailEnv;
}

module.exports = { runDeliveryTests };
