# Error budget on hetops.dev/lab: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the public lab page shows the live error budget and each experiment's cost, and chaos-api freezes chaos when the budget is spent.

**Architecture:**

- chaos-api polls four fixed Prometheus queries every 30 s (`SloReader`).
- It applies the freeze policy with hysteresis (`BudgetPolicy`). The policy feeds the Guard (a 423 for visitors; the bypass is exempt), `/chaos/status` and an `slo` SSE event.
- The runner computes each experiment's cost from the prober's bad-visit count.
- The page renders a budget panel and the frozen and unknown states from those events.

**Tech stack:** Node 22, Fastify, prom-client, node:test (chaos-api); plain ES modules plus node:test (hetops-portfolio); Kustomize and NetworkPolicy (hetops-k8s-lab).

**Spec:** `docs/superpowers/specs/2026-10-10-lab-error-budget-design.md`.

## Global constraints

**Data and policy:**

- **Queries are constants:**
  - `lab:slo_budget_remaining`
  - `1 - lab:visits_bad:ratio_rate7d`
  - `lab:slo_burn_rate{window="5m"}`
  - `lab:slo_burn_rate{window="1h"}`
- **No request data ever reaches Prometheus.**
- **Staleness:** a reading older than 120 000 ms counts as unknown (`null`).
- **Thresholds:** freeze at `budget <= FREEZE_AT` (default `0`); reopen at `budget >= REOPEN_AT` (default `0.05`). Both are read from the `chaos-config` ConfigMap keys `FREEZE_AT` and `REOPEN_AT`.
- **Fail-open:** an unknown SLO means not frozen.
- **The bypass token ignores the freeze.**
- **A frozen visitor POST** returns HTTP **423** with `{ ok: false, reason: 'budget-spent' }`.
- **Cost:** `cost = badVisits / 30240`, where 30,240 = 5 visits/s × 604,800 s × 1%.

**Endpoints and metrics:**

- `PROM_URL` defaults to `http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`.
- `/chaos/status` gains `slo: { budget, sli7d, burn5m, burn1h, frozen } | null`.
- The SSE event `slo` carries the same object.
- A new gauge, `chaos_frozen`, is 0 or 1.

**Page:**

- `textContent` only, never innerHTML.
- No ad-blocker words in class names (ad, banner, sponsor, promo, cookie, policy, popup).
- Works at 375 px.
- Reduced motion means no meter transition.
- Use the existing colour tokens: `--moss`, `--warn`, `--err`, `--line`, `--text-3`.

**Repo rules:**

- Commits use the author `Het Patel <patel.x.het@gmail.com>`, with no AI attribution lines.
- Work goes through PRs on the Het101 repos. Push with `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`, with `GH_TOKEN=$(gh auth token --user Het101)`.

**Deviations from the spec, found while planning:**

1. The Argo CD app `chaos` ignores `/data` on `chaos-config`, so threshold keys added in git would never reach the cluster. The defaults therefore live in code, and the owner sets or removes the keys with `kubectl` (lab P3).
2. The mock's frozen and none modes are a command-line argument (`node scripts/lab-mock.mjs frozen`), not a page query parameter, because the page talks to the mock server rather than reading those flags itself.

---

## Repo 1: chaos-api (`C:/Users/HetPatel/Personal/HetOps/chaos-api`, branch `feat/error-budget`)

Run every test with `npm test` (node:test, `test/*.test.js`). There are 74 tests today, and all must stay green.

### Task 1: `SloReader`, which reads the SLO from Prometheus

**Files:**
- Create: `src/slo.js`
- Create: `test/slo.test.js`

**Interfaces:**
- Produces:
  - `export class SloReader { constructor({ url, fetchImpl = fetch, now = Date.now, timeoutMs = 3000 }); async poll(): Promise<boolean>; read(): { budget, sli7d, burn5m, burn1h, at } | null }`;
  - `export const QUERIES` (an object mapping each field to its PromQL);
  - `export const STALE_MS = 120_000`.

- [ ] **Step 1: write the failing tests** in `test/slo.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SloReader, QUERIES, STALE_MS } from '../src/slo.js';

const VALUES = { budget: 0.7, sli7d: 0.997, burn5m: 12.5, burn1h: 1 };
// A fake Prometheus: answers each fixed query with its value, as the HTTP API does (value: [time, "string"]).
function fakeProm({ values = VALUES, fail = false, status = 200 } = {}) {
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    if (fail) throw new Error('ECONNREFUSED');
    const q = new URL(url).searchParams.get('query');
    const key = Object.keys(QUERIES).find((k) => QUERIES[k] === q);
    const result = key && values[key] !== undefined ? [{ metric: {}, value: [1, String(values[key])] }] : [];
    return { ok: status === 200, status, json: async () => ({ status: 'success', data: { resultType: 'vector', result } }) };
  };
  return { fetchImpl, urls };
}

test('reads the four SLO numbers from fixed queries', async () => {
  let t = 1_000;
  const { fetchImpl, urls } = fakeProm();
  const r = new SloReader({ url: 'http://prom:9090', fetchImpl, now: () => t });
  assert.equal(await r.poll(), true);
  assert.deepEqual(r.read(), { ...VALUES, at: 1_000 });
  assert.equal(urls.length, 4);
  for (const u of urls) assert.match(u, /^http:\/\/prom:9090\/api\/v1\/query\?query=/);
  assert.deepEqual(Object.values(QUERIES), ['lab:slo_budget_remaining', '1 - lab:visits_bad:ratio_rate7d',
    'lab:slo_burn_rate{window="5m"}', 'lab:slo_burn_rate{window="1h"}']);
});

test('unknown until the first good read, and again once the last one is stale', async () => {
  let t = 0;
  const r = new SloReader({ url: 'http://p', fetchImpl: fakeProm().fetchImpl, now: () => t });
  assert.equal(r.read(), null);
  await r.poll();
  t += STALE_MS;
  assert.notEqual(r.read(), null);
  t += 1;
  assert.equal(r.read(), null);
});

test('a failed poll keeps the last good reading (until it goes stale)', async () => {
  let t = 0;
  let fail = false;
  const good = fakeProm().fetchImpl;
  const r = new SloReader({ url: 'http://p', fetchImpl: (u) => (fail ? Promise.reject(new Error('down')) : good(u)), now: () => t });
  await r.poll();
  fail = true;
  t += 30_000;
  assert.equal(await r.poll(), false);
  assert.equal(r.read().budget, 0.7);
});

test('all four or nothing: a missing series or HTTP error is a failed poll', async () => {
  const r1 = new SloReader({ url: 'http://p', fetchImpl: fakeProm({ values: { budget: 0.7 } }).fetchImpl });
  assert.equal(await r1.poll(), false);
  assert.equal(r1.read(), null);
  const r2 = new SloReader({ url: 'http://p', fetchImpl: fakeProm({ status: 503 }).fetchImpl });
  assert.equal(await r2.poll(), false);
  const r3 = new SloReader({ url: 'http://p', fetchImpl: fakeProm({ values: { ...VALUES, sli7d: 'NaN' } }).fetchImpl });
  assert.equal(await r3.poll(), false);
});
```

- [ ] **Step 2: run them and check they fail.** Run `npm test`. Expected: FAIL with `Cannot find module '../src/slo.js'`.

- [ ] **Step 3: implement `src/slo.js`:**

```js
// The lab's SLO, read from Prometheus. The SLO itself is defined once, in the recording rules (hetops-k8s-lab,
// platform/monitoring/extras/slo-rules.yaml); chaos-api only reads it. The queries are constants: no request data
// ever reaches Prometheus.
export const QUERIES = {
  budget: 'lab:slo_budget_remaining',
  sli7d: '1 - lab:visits_bad:ratio_rate7d',
  burn5m: 'lab:slo_burn_rate{window="5m"}',
  burn1h: 'lab:slo_burn_rate{window="1h"}',
};
export const STALE_MS = 120_000;

export class SloReader {
  #last = null;

  constructor({ url, fetchImpl = fetch, now = Date.now, timeoutMs = 3000 }) {
    Object.assign(this, { url, fetchImpl, now, timeoutMs });
  }

  async #query(q) {
    const res = await this.fetchImpl(`${this.url}/api/v1/query?query=${encodeURIComponent(q)}`, { signal: AbortSignal.timeout(this.timeoutMs) });
    if (!res.ok) throw new Error(`prometheus HTTP ${res.status}`);
    const v = Number((await res.json())?.data?.result?.[0]?.value?.[1]);
    if (!Number.isFinite(v)) throw new Error(`no value for ${q}`);
    return v;
  }

  // All four or nothing: a half-updated reading would mix two moments.
  async poll() {
    try {
      const pairs = await Promise.all(Object.entries(QUERIES).map(async ([k, q]) => [k, await this.#query(q)]));
      this.#last = { ...Object.fromEntries(pairs), at: this.now() };
      return true;
    } catch {
      return false;
    }
  }

  read() { return this.#last && this.now() - this.#last.at <= STALE_MS ? { ...this.#last } : null; }
}
```

- [ ] **Step 4: run the tests and check they pass.** Run `npm test`. Expected: all pass (74 + 4).

- [ ] **Step 5: commit.**

```bash
git add src/slo.js test/slo.test.js
git commit -m "slo: read the error budget and burn rates from Prometheus"
```

### Task 2: `BudgetPolicy`, the freeze with hysteresis, plus the `chaos_frozen` gauge

**Files:**
- Modify: `src/slo.js` (append)
- Modify: `src/metrics.js` (add the gauge)
- Test: `test/slo.test.js` (append), `test/metrics.test.js` (append)

**Interfaces:**
- Consumes: `SloReader` (Task 1).
- Produces:
  - `export const DEFAULTS = { freezeAt: 0, reopenAt: 0.05 }`;
  - `export function parseThresholds(data): { freezeAt, reopenAt }`;
  - `export class BudgetPolicy { constructor({ reader, readThresholds = async () => DEFAULTS, broadcast = () => {}, gauge = null }); async tick(); get frozen(): boolean; get state(): { budget, sli7d, burn5m, burn1h, frozen } | null }`;
  - `createMetrics()` also returns `frozen`, a prom-client Gauge named `chaos_frozen`.

- [ ] **Step 1: write the failing tests.** Append to `test/slo.test.js`:

```js
import { BudgetPolicy, parseThresholds, DEFAULTS } from '../src/slo.js';

// A reader whose next reading the test sets directly.
const stubReader = () => { const r = { value: null, async poll() {}, read() { return r.value; } }; return r; };
const reading = (budget) => ({ budget, sli7d: 1 - (1 - budget) * 0.01, burn5m: 0, burn1h: 0, at: 0 });

test('freezes at 0, stays frozen until 5% is back, reopens at 5%', async () => {
  const reader = stubReader();
  const events = [];
  const p = new BudgetPolicy({ reader, broadcast: (e, d) => events.push([e, d && d.frozen]) });
  reader.value = reading(0.3); await p.tick(); assert.equal(p.frozen, false);
  reader.value = reading(0); await p.tick(); assert.equal(p.frozen, true);
  reader.value = reading(0.03); await p.tick(); assert.equal(p.frozen, true);
  reader.value = reading(0.05); await p.tick(); assert.equal(p.frozen, false);
  assert.deepEqual(events.map((e) => e[1]), [false, true, true, false]);
  assert.deepEqual(events.map((e) => e[0]), ['slo', 'slo', 'slo', 'slo']);
});

test('unknown SLO fails open: never frozen, state null', async () => {
  const reader = stubReader();
  const p = new BudgetPolicy({ reader });
  reader.value = reading(-0.2); await p.tick(); assert.equal(p.frozen, true);
  reader.value = null; await p.tick();
  assert.equal(p.frozen, false);
  assert.equal(p.state, null);
});

test('state carries the four numbers and the freeze, and sets the gauge', async () => {
  const reader = stubReader();
  const set = [];
  const p = new BudgetPolicy({ reader, gauge: { set: (v) => set.push(v) } });
  reader.value = { budget: 0.7, sli7d: 0.997, burn5m: 12.5, burn1h: 1, at: 5 };
  await p.tick();
  assert.deepEqual(p.state, { budget: 0.7, sli7d: 0.997, burn5m: 12.5, burn1h: 1, frozen: false });
  assert.deepEqual(set, [0]);
});

test('thresholds come from chaos-config, with defaults; a broken read uses the defaults', async () => {
  assert.deepEqual(parseThresholds(undefined), DEFAULTS);
  assert.deepEqual(parseThresholds({ enabled: 'true' }), { freezeAt: 0, reopenAt: 0.05 });
  assert.deepEqual(parseThresholds({ FREEZE_AT: '0.9', REOPEN_AT: '0.95' }), { freezeAt: 0.9, reopenAt: 0.95 });
  assert.deepEqual(parseThresholds({ FREEZE_AT: 'abc', REOPEN_AT: '' }), DEFAULTS);
  const reader = stubReader();
  reader.value = reading(0.7);
  const raised = new BudgetPolicy({ reader, readThresholds: async () => ({ freezeAt: 0.9, reopenAt: 0.95 }) });
  await raised.tick(); assert.equal(raised.frozen, true);
  const broken = new BudgetPolicy({ reader, readThresholds: async () => { throw new Error('api down'); } });
  await broken.tick(); assert.equal(broken.frozen, false);
});
```

Append to `test/metrics.test.js`:

```js
test('chaos_frozen exists from the start, at 0', async () => {
  const m = createMetrics();
  assert.match(await m.register.metrics(), /chaos_frozen 0/);
  m.frozen.set(1);
  assert.match(await m.register.metrics(), /chaos_frozen 1/);
});
```

- [ ] **Step 2: run them and check they fail.** Run `npm test`. Expected: FAIL (`BudgetPolicy` is not exported; `m.frozen` is undefined).

- [ ] **Step 3: implement.** Append to `src/slo.js`:

```js
// The error budget policy: when the budget is spent, visitor chaos freezes until 5% is back. The gap between
// freezeAt and reopenAt stops the lab flapping around zero. Thresholds live in chaos-config (FREEZE_AT, REOPEN_AT)
// so the owner can test a freeze without spending real budget.
export const DEFAULTS = { freezeAt: 0, reopenAt: 0.05 };

export function parseThresholds(data = {}) {
  const num = (v, d) => (v === undefined || v === '' || !Number.isFinite(Number(v)) ? d : Number(v));
  return { freezeAt: num(data?.FREEZE_AT, DEFAULTS.freezeAt), reopenAt: num(data?.REOPEN_AT, DEFAULTS.reopenAt) };
}

export class BudgetPolicy {
  #frozen = false;
  #state = null;

  constructor({ reader, readThresholds = async () => DEFAULTS, broadcast = () => {}, gauge = null }) {
    Object.assign(this, { reader, readThresholds, broadcast, gauge });
  }

  get frozen() { return this.#frozen; }
  get state() { return this.#state; }

  async tick() {
    await this.reader.poll();
    const slo = this.reader.read();
    const t = await this.readThresholds().catch(() => DEFAULTS);
    if (!slo) this.#frozen = false; // fail open: broken monitoring must not take the lab down (SLIMissing pages instead)
    else if (slo.budget <= t.freezeAt) this.#frozen = true;
    else if (slo.budget >= t.reopenAt) this.#frozen = false;
    this.#state = slo ? { budget: slo.budget, sli7d: slo.sli7d, burn5m: slo.burn5m, burn1h: slo.burn1h, frozen: this.#frozen } : null;
    this.gauge?.set(this.#frozen ? 1 : 0);
    this.broadcast('slo', this.#state);
  }
}
```

In `src/metrics.js`:
- change the import to `import { Registry, Counter, Histogram, Gauge, collectDefaultMetrics } from 'prom-client';`;
- before `return`, add:

```js
  const frozen = new Gauge({ name: 'chaos_frozen', help: '1 while the error budget policy has frozen visitor chaos.', registers: [register] });
  frozen.set(0);
```

- change the return to `return { register, experiments, recovery, probes, visits, frozen };`.

- [ ] **Step 4: run the tests and check they pass.** Run `npm test`. Expected: all pass.

- [ ] **Step 5: commit.**

```bash
git add src/slo.js src/metrics.js test/slo.test.js test/metrics.test.js
git commit -m "slo: error budget policy (freeze at 0, reopen at 5%), chaos_frozen gauge"
```

### Task 3: the Guard refuses while frozen; the runner records each experiment's cost

**Files:**
- Modify: `src/guard.js` (`check`)
- Modify: `src/runner.js` (constructor, `start`, `#observe`, `#finish`)
- Modify: `src/prober.js` (count bad visits)
- Test: `test/guard.test.js`, `test/runner.test.js`, new `test/prober.test.js`

**Interfaces:**
- Produces:
  - `Guard.check({ ..., frozen = false })` returns `{ ok: false, reason: 'budget-spent' }` when frozen and not bypass;
  - `Runner` constructor options `frozen = () => false` and `badVisits = () => 0`;
  - finished experiments carry `cost: number` (a fraction of the weekly budget);
  - `export const WEEKLY_BAD_VISITS = 30_240` (in `src/runner.js`);
  - `Prober#bad`, the number of bad visits since start.

- [ ] **Step 1: write the failing tests.** Append to `test/guard.test.js`:

```js
test('a spent budget freezes visitors, not the owner or the self-test', () => {
  const g = new Guard();
  assert.deepEqual(g.check({ ...ok, ipHash: 'a', frozen: true }), { ok: false, reason: 'budget-spent' });
  assert.deepEqual(g.check({ ...ok, ipHash: 'a', frozen: true, bypass: true }), { ok: true });
  assert.equal(g.check({ ...ok, enabled: false, frozen: true }).reason, 'disabled'); // the kill switch still speaks first
});
```

Append to `test/runner.test.js`:

```js
test('a frozen budget refuses visitors before anything runs', async () => {
  const { runner } = setup();
  runner.frozen = () => true;
  assert.equal((await runner.start({ actionId: 'scale-zero', ipHash: 'a' })).reason, 'budget-spent');
});

test('cost = bad visits during the experiment / the weekly allowance', async () => {
  const { runner } = setup({ healthSeq: [true, false, true] });
  runner.ctx = { k8s: { scaleDeployment: async () => {} }, cfg: { appNamespace: 'clinic' } };
  // Read once at start (100 already bad: they do not count), once at finish (402). Fixed answers, so no race with
  // the background observer, which can finish before the test's next line runs.
  const reads = [100, 402];
  runner.badVisits = () => reads.shift();
  await runner.start({ actionId: 'scale-zero', ipHash: 'a' });
  await runner.observing;
  const exp = runner.incidents.list()[0];
  assert.equal(exp.status, 'recovered');
  assert.equal(exp.cost, 302 / 30_240);
});
```

Create `test/prober.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Prober } from '../src/prober.js';

test('counts bad visits: a failed page or a failed api call', async () => {
  const answers = [{ ok: true }, { ok: true }, { ok: false }, { ok: true }, { ok: true }, { ok: false }];
  const fetchImpl = async () => { const a = answers.shift(); return { ok: a.ok, status: a.ok ? 200 : 503, headers: { get: () => null }, json: async () => ({}), body: { cancel: async () => {} } }; };
  const p = new Prober({ url: 'http://x/api', webUrl: 'http://x/', fetchImpl, onBatch: () => {} });
  await p.tick(); // page ok, api ok
  await p.tick(); // page bad, api ok
  await p.tick(); // page ok, api bad
  assert.equal(p.bad, 2);
});
```

- [ ] **Step 2: run them and check they fail.** Run `npm test`. Expected: FAIL. The guard returns `{ ok: true }` instead of `budget-spent`; `exp.cost` is undefined; `p.bad` is undefined.

- [ ] **Step 3: implement.**

In `src/guard.js`, change the `check` signature and add one line after the bypass line:

```js
  check({ ipHash, heavy = false, enabled, healthy, memoryOk, bypass = false, frozen = false }) {
    if (!enabled) return { ok: false, reason: 'disabled' };
    if (this.#running) return { ok: false, reason: 'busy' };
    if (!healthy) return { ok: false, reason: 'healing' };
    if (!memoryOk) return { ok: false, reason: 'node-memory' };
    if (bypass) return { ok: true };
    if (frozen) return { ok: false, reason: 'budget-spent' }; // the error budget policy; bypass (owner, self-test) is exempt
```

The rest of `check` is unchanged.

In `src/runner.js`:
- add, below the `switchAllows` export:

```js
// The 99% / 7-day SLO allows 1% bad visits: 5 visits/s x 604,800 s x 1% = 30,240 bad visits a week.
export const WEEKLY_BAD_VISITS = 30_240;
```

- in the constructor's destructured options add `frozen = () => false, badVisits = () => 0`, and add `frozen, badVisits` to the `Object.assign` list;
- in `start`, pass the freeze into the guard: `const verdict = this.guard.check({ ipHash, heavy: action.heavy, enabled: switchAllows(enabled, bypass), healthy: h.healthy, memoryOk, bypass, frozen: this.frozen() });`;
- in `start`, immediately before `this.guard.begin(...)`, add `const bad0 = this.badVisits();`;
- change `this.observing = this.#observe(exp, action);` to `this.observing = this.#observe(exp, action, bad0);`;
- change `async #observe(exp, action) {` to `async #observe(exp, action, bad0) {`, and its last line `this.#finish(exp);` to `this.#finish(exp, bad0);`;
- change `#finish(exp) {` to `#finish(exp, bad0) {`, and make its first two lines:

```js
    exp.endedAt = this.now();
    exp.cost = Math.max(0, this.badVisits() - bad0) / WEEKLY_BAD_VISITS; // what this experiment spent of the weekly budget
```

In `src/prober.js`:
- add the field `bad = 0; // bad visits since start: the runner reads it to price each experiment` below `#recent = [];`;
- in `tick()`, after `this.#recent.push(r);`, add `if (!(r.ok && (r.web?.ok ?? true))) this.bad += 1;`.

- [ ] **Step 4: run the tests and check they pass.** Run `npm test`. Expected: all pass.

- [ ] **Step 5: commit.**

```bash
git add src/guard.js src/runner.js src/prober.js test/guard.test.js test/runner.test.js test/prober.test.js
git commit -m "guard: freeze visitors while the budget is spent; runner: price each experiment"
```

### Task 4: expose the SLO (status, SSE, 423) and wire it up in the server

**Files:**
- Modify: `src/app.js`
- Modify: `src/config.js`
- Modify: `src/server.js`
- Test: `test/app.test.js`, `test/config.test.js`

**Interfaces:**
- Consumes:
  - `BudgetPolicy`, `SloReader`, `parseThresholds` (Tasks 1–2);
  - `Runner` options `frozen` and `badVisits`, and `Prober#bad` (Task 3);
  - `metrics.frozen` (Task 2).
- Produces:
  - `buildApp({ ..., slo = null })`, where `slo` is any object with a `state` getter;
  - `/chaos/status` returns `{ enabled, experiment, slo }`;
  - `cfg.promUrl`.

- [ ] **Step 1: write the failing tests.** In `test/app.test.js`, update the two existing status tests: their expected objects gain `slo: null`.

```js
  assert.deepEqual((await app.inject('/chaos/status')).json(), { enabled: true, experiment: { id: 'e9', action: 'kill-pod' }, slo: null });
```

```js
  assert.deepEqual((await app.inject('/chaos/status')).json(), { enabled: false, experiment: null, slo: null });
```

Then append:

```js
test('status carries the error budget', async () => {
  const state = { budget: 0.7, sli7d: 0.997, burn5m: 0.4, burn1h: 0.3, frozen: false };
  const { app } = make({ deps: { slo: { state }, runner: { start: async () => ({ ok: true }), readEnabled: async () => true, guard: { running: null } } } });
  assert.deepEqual((await app.inject('/chaos/status')).json().slo, state);
});

test('a frozen budget answers 423', async () => {
  const { app } = make({ result: { ok: false, reason: 'budget-spent' } });
  const res = await app.inject({ method: 'POST', url: '/chaos/actions/kill-pod', payload: { turnstileToken: 'human' } });
  assert.equal(res.statusCode, 423);
  assert.equal(res.json().reason, 'budget-spent');
});

test('a new viewer gets the current budget right away', async () => {
  const sent = [];
  const { app } = make({ deps: { slo: { state: { budget: 0.5, frozen: false } }, stream: { add() {}, send: (res, e, d) => sent.push([e, d]) } } });
  await app.inject('/chaos/stream');
  assert.deepEqual(sent, [['slo', { budget: 0.5, frozen: false }]]);
});
```

Note: `inject` on the hijacked stream route resolves once the handler returns; if it hangs in this harness, make the test call `app.inject({ url: '/chaos/stream', simulate: { close: true } })`. The assertion stays the same.

In `test/config.test.js`, add a line to the defaults test:

```js
  assert.equal(c.promUrl, 'http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090');
```

- [ ] **Step 2: run them and check they fail.** Run `npm test`. Expected: FAIL. The status has no `slo`; the POST answers 400 rather than 423; `promUrl` is undefined.

- [ ] **Step 3: implement.**

`src/app.js`:
- add `'budget-spent': 423` to the `STATUS` map;
- add `slo = null` to the destructured parameters of `buildApp`;
- replace the status route with:

```js
  app.get('/chaos/status', async () => ({ enabled: switchAllows(await runner.readEnabled(), false), experiment: runner.guard.running ?? null, slo: slo?.state ?? null }));
```

- in the `/chaos/stream` handler, after the snapshot lines, add:

```js
    if (slo) stream.send(reply.raw, 'slo', slo.state);
```

`src/config.js`, add to the returned object below `loadUrl`:

```js
    promUrl: env.PROM_URL ?? 'http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090',
```

`src/server.js`:
- add the import `import { SloReader, BudgetPolicy, parseThresholds } from './slo.js';`;
- after the `prober` definition, add:

```js
// The error budget policy, read from Prometheus every 30 s. Thresholds can be raised in chaos-config to test a freeze.
const budget = new BudgetPolicy({
  reader: new SloReader({ url: cfg.promUrl }),
  readThresholds: async () => parseThresholds((await k8s.readConfigMap(cfg.selfNamespace, 'chaos-config')).data),
  broadcast: (event, data) => stream.broadcast(event, data),
  gauge: metrics.frozen,
});
```

- in `new Runner({ ... })` add `frozen: () => budget.frozen,` and `badVisits: () => prober.bad,`;
- in `buildApp({ ... })` add `slo: budget`;
- replace the `timers` line with:

```js
const tickBudget = () => budget.tick().catch((err) => app.log.warn({ err: err.message }, 'slo tick failed'));
const timers = [setInterval(refresh, 1000), setInterval(() => stream.heartbeat(), 15_000), setInterval(tickBudget, 30_000)];
tickBudget();
```

- [ ] **Step 4: run the tests and check they pass.** Run `npm test`. Expected: all pass. Then smoke-check that the server module at least parses: `node --check src/server.js` should print nothing and exit 0.

- [ ] **Step 5: commit, push and open the PR. CI must be green, then merge.**

```bash
git add src/app.js src/config.js src/server.js test/app.test.js test/config.test.js
git commit -m "status and stream carry the error budget; 423 while frozen; wire the policy in"
git push -u origin feat/error-budget
gh pr create --repo Het101/chaos-api --title "Error budget: read the SLO, freeze when spent, price each experiment" --body "Sub-project 3 (hetops-k8s-lab docs/superpowers/specs/2026-10-10-lab-error-budget-design.md). Fail-open: before the lab's egress rule exists, the reader just returns null."
gh pr checks --repo Het101/chaos-api --watch
gh pr merge --repo Het101/chaos-api --squash --delete-branch
```

After the merge, note the image tag CI publishes: `git rev-parse --short=7 origin/main` after `git pull`. Task 5 needs it.

---

## Repo 2: hetops-k8s-lab (`C:/Users/HetPatel/Personal/HetOps/hetops-k8s-lab`, branch `feat/error-budget`)

### Task 5: the egress to Prometheus, `PROM_URL`, the image tag and the runbook notes

**Files:**
- Modify: `apps/chaos/networkpolicies.yaml` (the `chaos-api` policy's egress list)
- Modify: `apps/chaos/deployment.yaml` (env)
- Modify: `apps/chaos/kustomization.yaml` (`newTag`)
- Modify: `docs/gameday.md` (append a section)

**Interfaces:**
- Consumes: the chaos-api image tag from Task 4.

- [ ] **Step 1: add the egress rule.** In the `chaos-api` NetworkPolicy, add this as the last item of `egress:`:

```yaml
  - to:                                  # Prometheus: the error budget (fixed read-only queries, sub-project 3)
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
      podSelector: { matchLabels: { app.kubernetes.io/name: prometheus } }
    ports: [{ protocol: TCP, port: 9090 }]
```

- [ ] **Step 2: check the selector label against the real pod.** The owner runs this on the server:

```bash
kubectl -n monitoring get pod prometheus-kps-kube-prometheus-stack-prometheus-0 --show-labels | tr ',' '\n' | grep app.kubernetes.io/name
```

Expected: `app.kubernetes.io/name=prometheus`. If it differs, use the printed value.

- [ ] **Step 3: set `PROM_URL`.** In `apps/chaos/deployment.yaml`, add to the chaos-api container's `env:` list:

```yaml
        - { name: PROM_URL, value: http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090 }
```

Match the file's existing env style: if the entries are block style (`- name:` / `value:`), write it the same way.

- [ ] **Step 4: bump the image.** In `apps/chaos/kustomization.yaml`, set `newTag:` to the 7-character SHA from Task 4.

- [ ] **Step 5: document the thresholds.** Append to `docs/gameday.md`:

````markdown
## Error budget freeze (sub-project 3)

chaos-api freezes visitor chaos when the 7-day error budget is spent (`lab:slo_budget_remaining <= FREEZE_AT`) and reopens at `REOPEN_AT`. The defaults are 0 and 0.05, in code. The keys live in `chaos-config`, whose `/data` Argo CD ignores, so set them with kubectl, never in git.

- Test a freeze without spending budget:
  ```bash
  kubectl -n chaos patch cm chaos-config --type merge -p '{"data":{"FREEZE_AT":"0.99","REOPEN_AT":"0.995"}}'
  ```
- Restore the defaults:
  ```bash
  kubectl -n chaos patch cm chaos-config --type json -p '[{"op":"remove","path":"/data/FREEZE_AT"},{"op":"remove","path":"/data/REOPEN_AT"}]'
  ```
- While frozen, `CHAOS_BYPASS` requests (game day, the self-test) still run.
- If Prometheus is unreachable, the lab stays open (fail-open), and `SLIMissing` pages instead.
````

- [ ] **Step 6: render and commit.** `kubectl kustomize apps/chaos > /dev/null` should exit 0. Then:

```bash
git add apps/chaos docs/gameday.md
git commit -m "chaos: reach Prometheus for the error budget; chaos-api <sha>"
git push -u origin feat/error-budget
gh pr create --repo Het101/hetops-k8s-lab --title "chaos: error budget (egress to Prometheus, PROM_URL, image)" --body "Sub-project 3, repo 2 of 3."
gh pr merge --repo Het101/hetops-k8s-lab --squash --delete-branch
```

**Merge only after the owner has run lab P1's "before" check** (see Owner labs).

---

## Repo 3: hetops-portfolio (`C:/Users/HetPatel/Personal/HetOps/hetops-portfolio`, branch `feat/lab-error-budget`)

Test with `node --test tests/` (`tests/lab-core.test.mjs`).

### Task 6: pure helpers for the panel, the cost and the refusal

**Files:**
- Modify: `lab/core.js`
- Test: `tests/lab-core.test.mjs`

**Interfaces:**
- Produces:
  - `export function budgetView(slo): { state: 'none'|'ok'|'low'|'spent'|'frozen', meter: number /* 0..1 */, label: string, sli: string, burn: string }`;
  - `export function costText(cost): string`;
  - `refusalText('budget-spent')` returns the freeze sentence.

- [ ] **Step 1: write the failing tests.** In `tests/lab-core.test.mjs`, add `budgetView, costText` to the import list from `'../lab/core.js'`, then append:

```js
test('budgetView turns the SLO into the panel text', () => {
  assert.deepEqual(budgetView(null), { state: 'none', meter: 0, label: 'Budget unavailable right now', sli: '', burn: '' });
  const calm = budgetView({ budget: 0.714, sli7d: 0.99697, burn5m: 0.4, burn1h: 0.32, frozen: false });
  assert.equal(calm.state, 'ok');
  assert.equal(calm.meter, 0.714);
  assert.equal(calm.label, '71% of this week\'s error budget left');
  assert.equal(calm.sli, '99.70% of visits good over 7 days · target 99%');
  assert.equal(calm.burn, 'Burning 0.3× budget pace');
  const hot = budgetView({ budget: 0.2, sli7d: 0.998, burn5m: 12.5, burn1h: 1, frozen: false });
  assert.equal(hot.state, 'low');
  assert.equal(hot.burn, 'Burning 12.5× right now (1 h: 1.0×)');
  const spent = budgetView({ budget: -0.1, sli7d: 0.989, burn5m: 0, burn1h: 0, frozen: true });
  assert.equal(spent.state, 'frozen');
  assert.equal(spent.meter, 0);
  assert.equal(spent.label, 'Spent: no error budget left this week');
  assert.equal(budgetView({ budget: -0.1, sli7d: 0.989, burn5m: 0, burn1h: 0, frozen: false }).state, 'spent');
  assert.equal(budgetView({ budget: 1.3, sli7d: 1, burn5m: 0, burn1h: 0, frozen: false }).meter, 1);
});

test('costText prices an experiment', () => {
  assert.equal(costText(undefined), '');
  assert.equal(costText(0), 'cost no error budget');
  assert.equal(costText(302 / 30240), 'cost 1.00% of the weekly budget');
  assert.equal(costText(0.0012), 'cost 0.12% of the weekly budget');
  assert.equal(costText(0.00001), 'cost <0.01% of the weekly budget');
});

test('a frozen lab explains itself', () => {
  assert.match(refusalText('budget-spent'), /^Error budget spent\. The lab is frozen until reliability recovers\./);
});
```

- [ ] **Step 2: run them and check they fail.** Run `node --test tests/`. Expected: FAIL (`budgetView` is not exported).

- [ ] **Step 3: implement.** In `lab/core.js`, add this entry to the `REFUSALS` object:

```js
  'budget-spent': 'Error budget spent. The lab is frozen until reliability recovers. Reopens as older incidents age out of the 7-day window.',
```

Then append:

```js
// The error budget panel: everything as plain text, set with textContent.
export function budgetView(slo) {
  if (!slo) return { state: 'none', meter: 0, label: 'Budget unavailable right now', sli: '', burn: '' };
  const x = (n) => `${n.toFixed(1)}×`;
  return {
    state: slo.frozen ? 'frozen' : slo.budget <= 0 ? 'spent' : slo.budget < 0.25 ? 'low' : 'ok',
    meter: Math.max(0, Math.min(1, slo.budget)),
    label: slo.budget <= 0 ? 'Spent: no error budget left this week' : `${Math.round(slo.budget * 100)}% of this week's error budget left`,
    sli: `${(slo.sli7d * 100).toFixed(2)}% of visits good over 7 days · target 99%`,
    // 5 m shows an incident as it happens; otherwise the steadier 1 h pace.
    burn: slo.burn5m >= 2 ? `Burning ${x(slo.burn5m)} right now (1 h: ${x(slo.burn1h)})` : `Burning ${x(slo.burn1h)} budget pace`,
  };
}

export function costText(cost) {
  if (typeof cost !== 'number') return '';
  if (cost === 0) return 'cost no error budget';
  const pct = cost * 100;
  return `cost ${pct < 0.01 ? '<0.01' : pct.toFixed(2)}% of the weekly budget`;
}
```

- [ ] **Step 4: run the tests and check they pass.** Run `node --test tests/`. Expected: all pass.

- [ ] **Step 5: commit.**

```bash
git add lab/core.js tests/lab-core.test.mjs
git commit -m "lab: budget panel, cost and freeze texts"
```

### Task 7: the panel, the frozen and unknown states, the cost on the page, and the mock

**Files:**
- Modify: `lab/index.html` (the panel, inside `.lab-side` between `#lab-clock` and `#lab-actions`)
- Modify: `lab/lab.js`
- Modify: `styles.css` (after the `.lab-wait` rule, near line 1105)
- Modify: `scripts/lab-mock.mjs`

**Interfaces:**
- Consumes:
  - `budgetView`, `costText`, `refusalText` (Task 6);
  - the SSE `slo` event and `status.slo`;
  - `experiment.cost` (Task 3).

- [ ] **Step 1: add the panel markup** in `lab/index.html`, after the closing `</div>` of `#lab-clock`:

```html
        <div id="lab-budget" class="lab-budget" data-state="none">
          <h2>Error budget <button type="button" class="lab-budget-why" aria-expanded="false" aria-controls="lab-budget-help" title="What is this?">?</button></h2>
          <p id="lab-budget-help" class="lab-budget-help" hidden>The lab promises that 99% of visits are good over any 7 days. The other 1% is the error budget: about 100 minutes of failed visits a week. Every experiment spends some of it. 1× burn spends it in exactly 7 days. If it runs out, experiments freeze until it recovers.</p>
          <div class="lab-meter" role="meter" aria-label="Error budget left this week" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><span class="lab-meter-fill"></span></div>
          <p class="lab-budget-label">Budget unavailable right now</p>
          <p class="lab-budget-sli"></p>
          <p class="lab-budget-burn"></p>
        </div>
```

- [ ] **Step 2: add the styles** in `styles.css`, right after the `.lab-wait { ... }` line:

```css
.lab-budget { margin: 0 0 28px; padding: 18px 20px; border: 1px solid var(--line); border-radius: 14px; }
.lab-budget h2 { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; font-size: 16px; }
.lab-budget-why { width: 22px; height: 22px; border-radius: 50%; border: 1px solid var(--line-2); background: none; color: var(--text-3); font: 600 12px/1 var(--sans); cursor: pointer; }
.lab-budget-help { margin: 0 0 12px; font-size: 14px; color: var(--text-2); }
.lab-meter { height: 10px; border-radius: 999px; background: var(--ink-3); overflow: hidden; }
.lab-meter-fill { display: block; height: 100%; width: 0; background: var(--moss); transition: width 0.6s ease; }
.lab-budget[data-state="low"] .lab-meter-fill { background: var(--warn); }
.lab-budget[data-state="spent"] .lab-meter-fill, .lab-budget[data-state="frozen"] .lab-meter-fill { background: var(--err); }
.lab-budget-label { margin: 10px 0 2px; font-weight: 600; font-variant-numeric: tabular-nums; }
.lab-budget[data-state="spent"] .lab-budget-label, .lab-budget[data-state="frozen"] .lab-budget-label { color: var(--err); }
.lab-budget-sli, .lab-budget-burn { margin: 0; font: 13px var(--mono); color: var(--text-3); font-variant-numeric: tabular-nums; }
.lab-log-cost { grid-column: 1 / -1; font: 13px var(--mono); color: var(--text-3); }
@media (prefers-reduced-motion: reduce) { .lab-meter-fill { transition: none; } }
```

- [ ] **Step 3: wire up `lab/lab.js`.**

(a) Add `budgetView, costText` to the import from `'./core.js'`.

(b) Below `const say = ...`, add the frozen flag and the renderer:

```js
// The error budget: chaos-api reads it from Prometheus every 30 s. Frozen means the budget is spent and visitor
// experiments are refused (423) until 5% is back.
let frozen = false;
const budgetEl = $('#lab-budget');
function renderBudget(slo) {
  const v = budgetView(slo);
  budgetEl.dataset.state = v.state;
  $('.lab-meter-fill', budgetEl).style.width = `${Math.round(v.meter * 100)}%`;
  $('.lab-meter', budgetEl).setAttribute('aria-valuenow', String(Math.round(v.meter * 100)));
  $('.lab-budget-label', budgetEl).textContent = v.label;
  $('.lab-budget-sli', budgetEl).textContent = v.sli;
  $('.lab-budget-burn', budgetEl).textContent = v.burn;
  const was = frozen;
  frozen = v.state === 'frozen';
  $('#lab-check').hidden = frozen;
  if (frozen) say(refusalText('budget-spent'));
  else if (was && enabled) say('');
  setButtons();
}
$('.lab-budget-why').addEventListener('click', (e) => {
  const help = $('#lab-budget-help');
  help.hidden = !help.hidden;
  e.currentTarget.setAttribute('aria-expanded', String(!help.hidden));
});
```

(c) In `setButtons()`, add `|| frozen` to the `off` expression:

```js
  const off = !token || !!running || !enabled || pending || frozen || Date.now() < waitUntil;
```

(d) In `enterLive()`, inside the `if (status.status === 'fulfilled' && status.value) { ... }` block, add as its last line:

```js
    if ('slo' in status.value) renderBudget(status.value.slo);
```

(e) In `connect()`, after the `experiment` listener, add:

```js
  es.addEventListener('slo', (e) => renderBudget(parse(e)));
```

(f) In `addIncident`, after the `li.append(...)` call, add:

```js
  const cost = costText(exp.cost);
  if (cost) li.append(make('span', 'lab-log-cost', cost));
```

(g) In `finishClock`, before `addIncident(exp, true);`, add:

```js
  const cost = costText(exp.cost);
  if (cost) narrate([{ text: `This experiment ${cost}.`, tone: 'warn' }]);
```

(h) In `press()`, inside the `else { ... }` branch that reads `body`, refusals already go through `refusalText(body.reason, ...)`, so a 423 shows the freeze sentence. Add one line after that `say(...)`, so a freeze that began between two `slo` events also locks the buttons:

```js
      if (body.reason === 'budget-spent') { frozen = true; setButtons(); }
```

- [ ] **Step 4: update the mock.** In `scripts/lab-mock.mjs`:

(a) Below the `heavy` constant, add:

```js
// node scripts/lab-mock.mjs [ok|frozen|none]: the error budget state to show.
const sloMode = process.argv[2] ?? 'ok';
const slo = { budget: sloMode === 'frozen' ? -0.04 : 0.71, sli7d: sloMode === 'frozen' ? 0.9896 : 0.99712, burn5m: 0.3, burn1h: 0.3, frozen: sloMode === 'frozen' };
const sloNow = () => (sloMode === 'none' ? null : { ...slo });
```

(b) In `play`, before `incidents.unshift(...)`, price the experiment and make the burn rate react:

```js
  exp.cost = id === 'nuke-namespace' ? 0.0193 : id === 'kill-postgres' ? 0.0122 : 0.0011;
  slo.budget -= exp.cost; slo.burn5m = 12.5; slo.burn1h = 1.0;
  setTimeout(() => { slo.burn5m = 0.3; slo.burn1h = 0.4; }, 20_000);
```

(c) Below `setInterval(() => send('snapshot', snapshot()), 1000);`, add:

```js
setInterval(() => send('slo', sloNow()), 5000); // the real chaos-api sends every 30 s; faster here to see changes
```

(d) In the `/chaos/stream` branch, after the snapshot write, add:

```js
    res.write(`event: slo\ndata: ${JSON.stringify(sloNow())}\n\n`);
```

(e) Change the status line to `if (req.url === '/chaos/status') return json(200, { enabled: true, experiment: state.running, slo: sloNow() });`.

(f) In the POST branch, before the busy check, add:

```js
    if (sloNow()?.frozen) return json(423, { ok: false, reason: 'budget-spent' });
```

- [ ] **Step 5: verify by hand in the browser.** Start the static site and the mock using the `.claude/launch.json` entries `hetops-portfolio` and `lab-mock`. Open `/lab/?api=http://localhost:8787` and check:

1. **Normal:** the panel shows `71% of this week's error budget left`, the `99.71%…` line and `Burning 0.3× budget pace`.
2. **Press "Kill Postgres"** (Turnstile won't load locally, so the buttons stay off; to test the click, temporarily run `token='x';setButtons()` in the console). Expected:
   - the incident row shows `cost 1.22% of the weekly budget`;
   - the story line reads `This experiment cost 1.22%…`;
   - the burn line reads `Burning 12.5× right now (1 h: 1.0×)`, then calms after 20 s.
3. **Frozen:** restart the mock with `node scripts/lab-mock.mjs frozen`. Expected: a red "Spent" meter, the freeze sentence under the buttons, disabled buttons and a hidden Turnstile box.
4. **None:** restart it with `node scripts/lab-mock.mjs none`. Expected: `Budget unavailable right now`, and the buttons behave as before.
5. Resize to **375 px**: no horizontal scroll and the panel is readable. Toggle **reduced motion**: the meter jumps without animating.
6. **Console:** no errors.

Take a screenshot of states 1 and 3 for the PR.

- [ ] **Step 6: commit, push, open the PR, merge.** The repo has no CI, so run `node --test tests/` once more first.

```bash
git add lab/index.html lab/lab.js styles.css scripts/lab-mock.mjs
git commit -m "lab: live error budget panel, per-experiment cost, frozen state"
git push -u origin feat/lab-error-budget
gh pr create --repo Het101/hetops-portfolio --title "Lab: live error budget, cost per experiment, freeze" --body "Sub-project 3, repo 3 of 3. Needs chaos-api with /chaos/status slo (deployed first); before that the panel reads 'Budget unavailable'."
gh pr merge --repo Het101/hetops-portfolio --squash --delete-branch
```

Then the owner presses **Deploy** in Coolify and checks the built commit matches.

---

## Owner labs (run on `ubuntu@my-workspace`, in order with the PRs)

**P1: the network path.** Do the "before" half while Task 5's PR is open but not merged. Any chaos-api pod has Node 22, so the running pod can make the call.

The command asks Prometheus for the budget from inside the chaos-api pod:

```bash
kubectl -n chaos exec deploy/chaos-api -- node -e "fetch('http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/query?query=lab:slo_budget_remaining',{signal:AbortSignal.timeout(3000)}).then(r=>r.text()).then(console.log,e=>console.log('FAILED',e.cause?.code??e.name))"
```

1. **Before Task 5 is merged:** predict first (it should be `FAILED TimeoutError`, because default-deny drops the packets silently, so there's no "refused").
2. **Merge Task 5** and wait for Argo CD.
3. **Rerun:** expect a JSON reply with the budget.
4. **Then check the endpoint:** `curl -s -H 'Host: lab.hetops.dev' localhost:30870/chaos/status`. It should show `slo` with real numbers.

**P2: the panel live.** After Coolify deploys Task 7:

1. Open hetops.dev/lab.
2. Predict a kill-postgres's cost. 37 s × 5 visits/s ≈ 185 bad visits ÷ 30,240 ≈ 0.6%.
3. Run `scripts/gameday.sh kill-postgres` and compare the cost with your prediction.
4. Watch the burn line spike, and the budget drop by about that much on the next 30 s tick.

**P3: a real freeze, without spending budget.**

1. Raise the thresholds (see `docs/gameday.md`).
2. Within 30 s, the page should show "Spent/frozen" and the buttons should lock.
3. Check that `curl -s -X POST -H 'Host: lab.hetops.dev' localhost:30870/chaos/actions/kill-pod` returns 423, or 403 without Turnstile. The ordering is part of the lesson: Turnstile is checked before the guard.
4. Check that `scripts/gameday.sh kill-pod` (the bypass) still runs.
5. Check that Grafana `chaos_frozen` reads 1.
6. Remove the keys. The lab reopens on the next tick.

Record P1–P3 in journal Part 6 under "Sub-project 3".
