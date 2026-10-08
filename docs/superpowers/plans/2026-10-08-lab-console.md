# Lab Console (hetops.dev/lab) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Task 7 is the owner's (Cloudflare dashboard).

**Goal:** A public page at `hetops.dev/lab` where visitors watch the real Kubernetes lab live, press one of 15 chaos buttons, and watch Kubernetes and Argo CD heal it. When the live lab can't be reached, the page falls back to the existing homepage simulation, clearly labelled.

**Architecture:**

- **Static page.** `hetops-portfolio` stays plain HTML/CSS/JS with no build step:
  - `lab/index.html` is the shell;
  - `lab/core.js` is a pure ES module (no DOM; it is unit-tested with `node --test`);
  - `lab/lab.js` holds the DOM and network glue.
- **The scene follows the site's "Watching Eye" concept.**
  - The ingress is a **pupil** at the centre.
  - Each namespace is a **ring**: `clinic-data` is the inner ring (the data at the core), and `clinic` is the outer ring.
  - Each pod is a node on its ring, coloured by its true state.
  - Every prober request is a dot that travels from the pupil to the pod that answered it.
  - Argo CD is a gold arc around the outer ring: full when Synced, broken and pulsing while it reverts drift.
- **Data source.** The live data comes from chaos-api: the SSE events `snapshot`, `probes` and `experiment`, plus `GET /chaos/actions`, `/chaos/incidents` and a new `/chaos/status`.

**Tech Stack:** HTML, CSS, vanilla ES modules, the `EventSource` API, Cloudflare Turnstile (explicit render), `node --test`, nginx (existing image), and chaos-api (Fastify) for the one new route.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-08-chaos-lab-design.md`, section "Console page".
- Design: `hetops-portfolio/DESIGN.md`.
  - Dark only; tokens from `styles.css :root`.
  - Rings and pills, **never boxed cards**, no glows, no gradient text, no eyebrow labels.
  - Gold marks one thing per region: here, the recovery timer.
  - Moss means live/ok, alert `#ef7a64` only for failures.
  - Mono only for kubectl commands, pod names and measurements.
- **Class and id names must avoid ad-blocker trigger words** (the owner uses Brave): `ad`, `ads`, `banner`, `cookie`, `policy`, `sponsor`, `promo`, `popup`. Prefix new classes with `lab-`.
- **Reduced motion:** no travelling dots and no pulsing. A text status line replaces the dots: `Last second: 5 of 5 requests answered (api-…bpl9b, api-…g7clh)`.
- **No `innerHTML` with data from the network.** Use `textContent` and `createElement` only, because pod names and reasons come from a server.
- **Live API base:** `https://lab.hetops.dev`. A `?api=` query parameter is honoured **only** when it matches `^http://localhost:\d+$` (for the mock server).
- **Turnstile:**
  - Explicit render; `appearance: 'interaction-only'`.
  - The site key comes from `data-sitekey` on `#lab-check`. It starts as Cloudflare's always-pass test key `1x00000000000000000000AA`, matching the test secret sealed today; Task 7 swaps both.
  - A token is single-use: call `turnstile.reset()` after every POST.
- **One deliberate change from the spec.** The spec says the page falls back to the simulation when the stream is unreachable *or* chaos is disabled. This plan falls back only when the stream is unreachable. With the kill switch off, the page still shows the real live cluster, and the buttons are paused with a sentence saying so. Watching the real thing is the point; the simulation is only for when there is nothing real to show.
- **Recovery targets** are the spec's chaos-actions table. Action 7 now scales `web`, not `api`.
- **Copy:** plain, calm, first person where it's Het speaking; no invented claims.
- **Commits:**
  - Author `patel.x.het@gmail.com`; the portfolio repo signs commits (key already configured locally).
  - Conventional commit messages; **no Co-Authored-By or Claude lines** (the portfolio CI rejects attributed commits).
  - PRs only. GH CLI with `GH_TOKEN=$(gh auth token --user Het101)`; push with `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.

## File Structure

```text
chaos-api/src/app.js                 + GET /chaos/status
chaos-api/test/app.test.js           + its test
hetops-k8s-lab/apps/chaos/kustomization.yaml   image tag bump
hetops-portfolio/
  lab/index.html          page shell, scene SVG, panels, simulation fallback markup
  lab/core.js             pure logic: action info, tones, layout, diff narration, formatting
  lab/lab.js              DOM + EventSource + fetch + Turnstile
  tests/lab-core.test.mjs node --test for core.js (not copied into the image)
  scripts/lab-mock.mjs    local mock chaos-api (SSE + actions) for development and screenshots
  styles.css              + .lab-* section
  index.html              "Break production" links to /lab/
  sitemap.xml, Dockerfile, nginx/security-headers.conf, .github/workflows/ci.yml
```

---

### Task 1: chaos-api `GET /chaos/status`

**Repo:** `Het101/chaos-api` (local `C:/Users/HetPatel/Personal/HetOps/chaos-api`).

**Interfaces:**
- Produces: `GET /chaos/status` → `{ enabled: boolean, experiment: object | null }`. `experiment` is `runner.guard.running`, the running experiment or `null`.

- [ ] **Step 1: Failing test.** Append to `test/app.test.js`:

```js
test('status says whether experiments are on and what is running', async () => {
  const { app } = make({ deps: { runner: { start: async () => ({ ok: true }), readEnabled: async () => true, guard: { running: { id: 'e9', action: 'kill-pod' } } } } });
  assert.deepEqual((await app.inject('/chaos/status')).json(), { enabled: true, experiment: { id: 'e9', action: 'kill-pod' } });
});
```

- [ ] **Step 2:** `npm test`. Expect a failure (404).
- [ ] **Step 3: Implement.** In `src/app.js`, next to `/chaos/health`:

```js
  app.get('/chaos/status', async () => ({ enabled: await runner.readEnabled(), experiment: runner.guard.running ?? null }));
```

- [ ] **Step 4:** `npm test`. Expect 54 passing.
- [ ] **Step 5: Ship it.**
  - Branch `feat/status`; commit `feat: GET /chaos/status for the console page`; open the PR.
  - When CI is green, merge it (squash) and wait for the `main` CI run to finish.
  - In `hetops-k8s-lab`, on branch `chore/chaos-api-<sha7>`, set `newTag:` in `apps/chaos/kustomization.yaml` to the new short SHA. Open the PR and merge it.

---

### Task 2: `lab/core.js` (pure logic) and its tests

**Repo:** `Het101/hetops-portfolio` (local `C:/Users/HetPatel/Personal/HetOps/hetops-portfolio`). Branch: `feat/lab`.

**Interfaces (used by Task 4 and Task 5):**
- `ACTIONS[id]` → `{ group: 'kubernetes'|'kubelet'|'argo', target: seconds, explain: string, kubectl: string }`.
- `GROUPS` → `[{ id, title, note }]`, three entries in display order.
- `tone(pod)` → `'ok' | 'starting' | 'down'`.
- `livePods(pods)` → only long-running pods (Job pods with state `Completed` are left out).
- `ringLayout(pods, { cx, cy, r })` → the same pods plus `x` and `y` evenly around the ring, starting at 12 o'clock.
- `diffSnapshots(prev, next)` → `[{ text, tone: 'ok'|'warn'|'down' }]`, the narration lines for what changed.
- `probeSummary(batch)` → `{ ok, failed, pods }`.
- `refusalText(reason, retryAfterMs)` → a sentence.
- `formatMs(ms)` → `'4.1 s'`, `'2 min 05 s'`.
- `verdict(exp)` → `{ label, within }`.
- `apiBase(search)` → the API origin (see Global Constraints).

- [ ] **Step 1: Failing tests.** `tests/lab-core.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ACTIONS, GROUPS, tone, livePods, ringLayout, diffSnapshots, probeSummary, refusalText, formatMs, verdict, apiBase } from '../lab/core.js';

const IDS = ['kill-pod', 'evict-api', 'delete-api-pods', 'crash', 'leak', 'hang', 'scale-zero', 'delete-web', 'delete-api-svc',
  'bad-release', 'delete-secret', 'rogue-netpol', 'kill-postgres', 'traffic-spike', 'nuke-namespace'];

test('every chaos-api action has a group, a target, an explanation and a command', () => {
  assert.deepEqual(Object.keys(ACTIONS), IDS);
  for (const id of IDS) {
    const a = ACTIONS[id];
    assert.ok(GROUPS.some((g) => g.id === a.group), id);
    assert.ok(a.target > 0 && a.explain.length > 20 && a.kubectl.startsWith('kubectl '), id);
  }
  assert.equal(ACTIONS['kill-pod'].target, 30);
  assert.equal(ACTIONS['nuke-namespace'].target, 300);
});

const pod = (name, over = {}) => ({ name, app: name.split('-')[0], state: 'Running', ready: true, restarts: 0, lastReason: null, ...over });

test('tone reads the true state', () => {
  assert.equal(tone(pod('api-a')), 'ok');
  assert.equal(tone(pod('api-a', { ready: false, state: 'ContainerCreating' })), 'starting');
  assert.equal(tone(pod('api-a', { ready: false, state: 'CrashLoopBackOff' })), 'down');
  assert.equal(tone(pod('api-a', { ready: false, state: 'OOMKilled' })), 'down');
  assert.equal(tone(pod('api-a', { ready: false, state: 'ImagePullBackOff' })), 'down');
  assert.equal(tone(pod('api-a', { ready: true, state: 'Terminating' })), 'down');
});

test('finished job pods are not part of the live cluster', () => {
  assert.deepEqual(livePods([pod('api-a'), pod('migrate-x', { state: 'Completed', ready: false })]).map((p) => p.name), ['api-a']);
});

test('ring layout starts at 12 o\'clock and spaces pods evenly', () => {
  const [a, b] = ringLayout([pod('api-a'), pod('api-b')], { cx: 100, cy: 100, r: 50 });
  assert.deepEqual([a.x, a.y], [100, 50]);
  assert.deepEqual([b.x, b.y], [100, 150]);
});

const snap = (pods, argo = { sync: 'Synced', health: 'Healthy', operation: null }, exists = true) =>
  ({ clinic: { exists, pods, deployments: [] }, 'clinic-data': { exists: true, pods: [pod('postgres-0')], deployments: [] }, argo });

test('narration: created, gone, state changes and restarts', () => {
  const prev = snap([pod('api-a'), pod('api-b')]);
  const next = snap([pod('api-a', { restarts: 1, lastReason: 'OOMKilled' }), pod('api-c', { ready: false, state: 'ContainerCreating' })]);
  assert.deepEqual(diffSnapshots(prev, next), [
    { text: 'api-a restarted (OOMKilled)', tone: 'warn' },
    { text: 'api-b is gone', tone: 'down' },
    { text: 'api-c created: ContainerCreating', tone: 'warn' },
  ]);
  assert.deepEqual(diffSnapshots(next, snap([pod('api-a', { restarts: 1 }), pod('api-c')])), [{ text: 'api-c is Ready', tone: 'ok' }]);
});

test('narration: Argo CD drift, revert and a vanished namespace', () => {
  const ok = snap([pod('api-a')]);
  const drift = snap([pod('api-a')], { sync: 'OutOfSync', health: 'Healthy', operation: 'Running' });
  assert.deepEqual(diffSnapshots(ok, drift), [{ text: 'Argo CD: drift detected, reverting to git', tone: 'warn' }]);
  assert.deepEqual(diffSnapshots(drift, ok), [{ text: 'Argo CD: back in sync with git', tone: 'ok' }]);
  const nuked = snap([], ok.argo, false);
  assert.deepEqual(diffSnapshots(ok, nuked)[0], { text: 'namespace clinic is gone', tone: 'down' });
  assert.deepEqual(diffSnapshots(nuked, ok)[0], { text: 'namespace clinic is back', tone: 'ok' });
  assert.deepEqual(diffSnapshots(null, ok), []);
});

test('probe summary', () => {
  assert.deepEqual(probeSummary([{ ok: true, pod: 'api-a' }, { ok: true, pod: 'api-b' }, { ok: true, pod: 'api-a' }, { ok: false, pod: null }]),
    { ok: 3, failed: 1, pods: ['api-a', 'api-b'] });
});

test('refusals become plain sentences', () => {
  assert.equal(refusalText('cooldown', 41_200), 'You can break something again in 42 s.');
  assert.match(refusalText('busy'), /Someone else/);
  assert.match(refusalText('healing'), /still healing/);
  assert.match(refusalText('who-knows'), /did not work/);
});

test('times and verdicts', () => {
  assert.equal(formatMs(4104), '4.1 s');
  assert.equal(formatMs(125_000), '2 min 05 s');
  assert.deepEqual(verdict({ action: 'kill-pod', status: 'recovered', recoveryMs: 4104 }), { label: '4.1 s', within: true });
  assert.deepEqual(verdict({ action: 'kill-pod', status: 'recovered', recoveryMs: 31_000 }), { label: '31.0 s', within: false });
  assert.deepEqual(verdict({ action: 'kill-pod', status: 'timeout' }), { label: 'did not recover in 10 min', within: false });
});

test('only a localhost api override is honoured', () => {
  assert.equal(apiBase(''), 'https://lab.hetops.dev');
  assert.equal(apiBase('?api=http://localhost:8787'), 'http://localhost:8787');
  assert.equal(apiBase('?api=https://evil.example'), 'https://lab.hetops.dev');
});
```

- [ ] **Step 2:** `node --test tests/`. Expect a failure (module not found).
- [ ] **Step 3: Implement.** `lab/core.js`:

```js
// Pure logic for the lab console. No DOM here, so `node --test tests/` can check all of it.

export const GROUPS = [
  { id: 'kubernetes', title: 'Kubernetes heals it', note: 'ReplicaSets, StatefulSets, PodDisruptionBudgets, the autoscaler' },
  { id: 'kubelet', title: 'The kubelet heals it', note: 'restarts a sick container inside its pod' },
  { id: 'argo', title: 'Argo CD heals it', note: 'puts the cluster back to what git says' },
];

// Targets are the spec's recovery targets, in seconds.
export const ACTIONS = {
  'kill-pod': { group: 'kubernetes', target: 30, kubectl: 'kubectl -n clinic get pods -l app=api -w',
    explain: 'One api pod was deleted. Its ReplicaSet wants 3, counted 2, and started a replacement. Traffic kept flowing to the other two.' },
  'evict-api': { group: 'kubernetes', target: 90, kubectl: 'kubectl -n clinic get pdb api',
    explain: 'Evictions ask permission first. The PodDisruptionBudget keeps 2 api pods serving, so it let one go and refused the rest (HTTP 429).' },
  'delete-api-pods': { group: 'kubernetes', target: 60, kubectl: 'kubectl -n clinic get rs -l app=api',
    explain: 'A plain delete skips the PodDisruptionBudget. Every api pod went at once, so requests failed until the first replacement was Ready.' },
  crash: { group: 'kubelet', target: 30, kubectl: 'kubectl -n clinic get pods -l app=api',
    explain: 'The process exited. The kubelet restarted the container inside the same pod: watch its restart count go up.' },
  leak: { group: 'kubelet', target: 60, kubectl: 'kubectl -n clinic describe pod -l app=api | grep -A3 "Last State"',
    explain: 'Memory grew until the 256 MiB limit. The kernel killed the container (OOMKilled) and the kubelet started it again.' },
  hang: { group: 'kubelet', target: 60, kubectl: 'kubectl -n clinic get events --field-selector reason=Unhealthy',
    explain: 'The app froze. Its readiness probe failed first, so traffic moved away; then the liveness probe failed and the kubelet restarted it.' },
  'scale-zero': { group: 'argo', target: 120, kubectl: 'kubectl -n argocd get app clinic',
    explain: 'The web tier was scaled to 0 by hand. Git says 2, so Argo CD saw the drift and scaled it back.' },
  'delete-web': { group: 'argo', target: 120, kubectl: 'kubectl -n argocd get app clinic',
    explain: 'The web Deployment was deleted. It still exists in git, so Argo CD recreated it.' },
  'delete-api-svc': { group: 'argo', target: 120, kubectl: 'kubectl -n clinic get endpointslices -l kubernetes.io/service-name=api',
    explain: 'The api Service was deleted: the pods were healthy but nothing could find them. Argo CD recreated the Service from git.' },
  'bad-release': { group: 'argo', target: 180, kubectl: 'kubectl -n clinic rollout status deploy/api',
    explain: 'Someone set an image that does not exist. maxUnavailable: 0 kept the old pods serving while the new one failed, and Argo CD put the image back.' },
  'delete-secret': { group: 'argo', target: 120, kubectl: 'kubectl -n clinic get sealedsecret,secret clinic-db',
    explain: 'The database Secret was deleted. Its encrypted copy still lives in git, so it was decrypted again. Running pods never noticed.' },
  'rogue-netpol': { group: 'argo', target: 180, kubectl: 'kubectl -n clinic get networkpolicy',
    explain: 'A deny-all NetworkPolicy cut every pod off. It was marked as owned by Argo CD but is not in git, so Argo CD pruned it.' },
  'kill-postgres': { group: 'kubernetes', target: 120, kubectl: 'kubectl -n clinic-data get pod,pvc',
    explain: 'The database pod was deleted. The StatefulSet brought back postgres-0 with the same name and the same disk, so no data was lost.' },
  'traffic-spike': { group: 'kubernetes', target: 480, kubectl: 'kubectl -n clinic get hpa api -w',
    explain: '90 seconds of heavy requests. CPU rose and the HorizontalPodAutoscaler added api pods (3 to 5); it scales back down a few minutes later.' },
  'nuke-namespace': { group: 'argo', target: 300, kubectl: 'kubectl -n argocd get app clinic -w',
    explain: 'The whole clinic namespace was deleted. Argo CD rebuilt the namespace and everything in it from git. The database lives in clinic-data, untouched.' },
};

const DOWN = /Terminating|Error|CrashLoop|OOMKilled|ImagePull|ErrImage|Evicted/;

export const tone = (pod) => (DOWN.test(pod.state) ? 'down' : pod.ready ? 'ok' : 'starting');

// Finished Job pods (migrations, reports) are history, not the running cluster.
export const livePods = (pods) => pods.filter((p) => p.state !== 'Completed' && p.state !== 'Succeeded');

export function ringLayout(pods, { cx, cy, r }) {
  return pods.map((p, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / pods.length;
    return { ...p, x: Math.round(cx + r * Math.cos(a)), y: Math.round(cy + r * Math.sin(a)) };
  });
}

function diffPods(prev, next, out) {
  const before = new Map(livePods(prev).map((p) => [p.name, p]));
  const after = new Map(livePods(next).map((p) => [p.name, p]));
  for (const name of new Set([...before.keys(), ...after.keys()].sort())) {
    const a = before.get(name), b = after.get(name);
    if (!b) out.push({ text: `${name} is gone`, tone: 'down' });
    else if (!a) out.push({ text: `${name} created: ${b.state}`, tone: tone(b) === 'ok' ? 'ok' : 'warn' });
    else if (b.restarts > a.restarts) out.push({ text: `${name} restarted (${b.lastReason ?? 'exited'})`, tone: 'warn' });
    else if (b.ready && !a.ready) out.push({ text: `${name} is Ready`, tone: 'ok' });
    else if (b.state !== a.state) out.push({ text: `${name}: ${b.state}`, tone: tone(b) === 'down' ? 'down' : 'warn' });
  }
}

// What changed between two snapshots, as lines a visitor can read.
export function diffSnapshots(prev, next) {
  if (!prev) return [];
  const out = [];
  for (const ns of ['clinic', 'clinic-data']) {
    const a = prev[ns], b = next[ns];
    if (a.exists && !b.exists) { out.push({ text: `namespace ${ns} is gone`, tone: 'down' }); continue; }
    if (!a.exists && b.exists) out.push({ text: `namespace ${ns} is back`, tone: 'ok' });
    diffPods(a.pods, b.pods, out);
  }
  if (prev.argo.sync === 'Synced' && next.argo.sync === 'OutOfSync') out.push({ text: 'Argo CD: drift detected, reverting to git', tone: 'warn' });
  if (prev.argo.sync !== 'Synced' && next.argo.sync === 'Synced') out.push({ text: 'Argo CD: back in sync with git', tone: 'ok' });
  return out;
}

export function probeSummary(batch) {
  const ok = batch.filter((p) => p.ok).length;
  return { ok, failed: batch.length - ok, pods: [...new Set(batch.filter((p) => p.ok && p.pod).map((p) => p.pod))].sort() };
}

const REFUSALS = {
  busy: 'Someone else\'s experiment is running. Watch it heal, then try yours.',
  healing: 'The lab is still healing from the last experiment. Give it a moment.',
  'hourly-cap': 'The two heavy experiments are capped at 3 an hour. Try a lighter one.',
  disabled: 'Experiments are paused right now. You can still watch the live cluster.',
  'node-memory': 'The server is short on memory right now. Try again in a minute.',
  turnstile: 'The human check did not pass. Try again.',
  'busy-stream': 'Too many people are watching right now. Try again shortly.',
};

export const refusalText = (reason, retryAfterMs) =>
  reason === 'cooldown' ? `You can break something again in ${Math.ceil(retryAfterMs / 1000)} s.` : REFUSALS[reason] ?? 'That did not work. Try again.';

export function formatMs(ms) {
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, '0')} s`;
}

export function verdict(exp) {
  if (exp.status !== 'recovered') return { label: 'did not recover in 10 min', within: false };
  return { label: formatMs(exp.recoveryMs), within: exp.recoveryMs <= ACTIONS[exp.action].target * 1000 };
}

export function apiBase(search) {
  const api = new URLSearchParams(search).get('api') ?? '';
  return /^http:\/\/localhost:\d+$/.test(api) ? api : 'https://lab.hetops.dev';
}
```

- [ ] **Step 4:** `node --test tests/`. Expect 10 passing.
- [ ] **Step 5: CI.** In `.github/workflows/ci.yml`, right after the `app.js parses` step, add:

```yaml
      - name: lab console logic
        run: |
          node --check lab/core.js
          node --check lab/lab.js
          node --test tests/
```

(`lab/lab.js` arrives in Task 4. Until then, add only the `core.js` and `--test` lines; Task 4 adds its `node --check`.)

- [ ] **Step 6: Commit** `feat(lab): console logic and its tests`

---

### Task 3: Mock chaos-api for local development

**Files:** Create `scripts/lab-mock.mjs` (not copied into the image).

**Interfaces:**
- `node scripts/lab-mock.mjs` serves `http://localhost:8787` with the same routes and events as chaos-api.
- It sends `access-control-allow-origin: *`.
- Pages opened with `?api=http://localhost:8787` use it.

- [ ] **Step 1: Write it.**

```js
// A fake chaos-api for building the console without the cluster: node scripts/lab-mock.mjs, then open /lab/?api=http://localhost:8787
import { createServer } from 'node:http';

const ids = ['kill-pod', 'evict-api', 'delete-api-pods', 'crash', 'leak', 'hang', 'scale-zero', 'delete-web', 'delete-api-svc',
  'bad-release', 'delete-secret', 'rogue-netpol', 'kill-postgres', 'traffic-spike', 'nuke-namespace'];
const titles = ['Kill a pod', 'Evict every API pod', 'Delete every API pod', 'Crash the process', 'Memory leak', 'Hang the app',
  'Scale the web tier to 0', 'Delete the web Deployment', 'Delete the api Service', 'Ship a bad release by hand',
  'Delete the database Secret', 'Inject a rogue deny-all NetworkPolicy', 'Kill Postgres', 'Traffic spike', 'Nuke the clinic namespace'];
const heavy = new Set(['traffic-spike', 'nuke-namespace']);

let n = 0;
const mk = (app) => ({ name: `${app}-7f9c${(n++).toString(36).padStart(3, '0')}`, app, state: 'Running', ready: true, restarts: 0, lastReason: null });
const state = { pods: [mk('api'), mk('api'), mk('api'), mk('web'), mk('web'), mk('worker')], exists: true, argo: 'Synced', running: null };
const incidents = [];
const clients = new Set();

const snapshot = () => ({
  at: Date.now(),
  clinic: { exists: state.exists, pods: state.exists ? state.pods : [], deployments: [] },
  'clinic-data': { exists: true, pods: [{ name: 'postgres-0', app: 'postgres', state: 'Running', ready: true, restarts: 0, lastReason: null }], deployments: [] },
  argo: { sync: state.argo, health: state.argo === 'Synced' ? 'Healthy' : 'Progressing', operation: state.argo === 'Synced' ? null : 'Running' },
});
const send = (event, data) => { for (const res of clients) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// A rough imitation of each healing, enough to see every state the page draws.
async function play(id, exp) {
  const victim = state.pods.find((p) => p.app === 'api');
  if (id === 'nuke-namespace') { state.exists = false; state.argo = 'OutOfSync'; await wait(6000); state.exists = true; }
  else if (['scale-zero', 'delete-web', 'delete-api-svc', 'bad-release', 'delete-secret', 'rogue-netpol'].includes(id)) {
    if (id === 'scale-zero' || id === 'delete-web') state.pods = state.pods.filter((p) => p.app !== 'web');
    state.argo = 'OutOfSync'; await wait(4000);
    if (!state.pods.some((p) => p.app === 'web')) state.pods.push({ ...mk('web'), ready: false, state: 'ContainerCreating' }, { ...mk('web'), ready: false, state: 'ContainerCreating' });
    state.argo = 'Synced';
  } else if (['crash', 'leak', 'hang'].includes(id)) {
    Object.assign(victim, { ready: false, state: id === 'hang' ? 'Running' : 'CrashLoopBackOff' }); await wait(3000);
    Object.assign(victim, { ready: true, state: 'Running', restarts: victim.restarts + 1, lastReason: id === 'leak' ? 'OOMKilled' : 'Error' });
  } else {
    const gone = id === 'delete-api-pods' ? state.pods.filter((p) => p.app === 'api') : [victim];
    for (const p of gone) p.state = 'Terminating';
    await wait(1500);
    state.pods = state.pods.filter((p) => !gone.includes(p));
    state.pods.push(...gone.map(() => ({ ...mk('api'), ready: false, state: 'ContainerCreating' })));
  }
  await wait(2500);
  for (const p of state.pods) Object.assign(p, { ready: true, state: 'Running' });
  Object.assign(exp, { status: 'recovered', recoveryMs: Date.now() - exp.startedAt, endedAt: Date.now() });
  incidents.unshift({ ...exp });
  state.running = null;
  send('experiment', exp);
}

setInterval(() => send('snapshot', snapshot()), 1000);
setInterval(() => {
  const api = state.exists ? state.pods.filter((p) => p.app === 'api' && p.ready) : [];
  send('probes', Array.from({ length: 5 }, (_, i) => {
    const pod = api[i % (api.length || 1)];
    return pod ? { at: Date.now(), ok: true, status: 200, pod: pod.name, ms: 4 } : { at: Date.now(), ok: false, status: 0, pod: null, ms: 1000 };
  }));
}, 1000);

createServer((req, res) => {
  const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*' }); res.end(JSON.stringify(body)); };
  if (req.method === 'OPTIONS') { res.writeHead(204, { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type', 'access-control-allow-methods': 'GET, POST' }); return res.end(); }
  if (req.url === '/chaos/stream') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'access-control-allow-origin': '*' });
    res.write(`event: snapshot\ndata: ${JSON.stringify(snapshot())}\n\n`);
    clients.add(res); req.on('close', () => clients.delete(res)); return;
  }
  if (req.url === '/chaos/actions') return json(200, ids.map((id, i) => ({ id, title: titles[i], heavy: heavy.has(id) })));
  if (req.url === '/chaos/incidents') return json(200, incidents);
  if (req.url === '/chaos/status') return json(200, { enabled: true, experiment: state.running });
  const m = req.url.match(/^\/chaos\/actions\/([a-z-]+)$/);
  if (req.method === 'POST' && m) {
    if (!ids.includes(m[1])) return json(404, { reason: 'unknown-action' });
    if (state.running) return json(409, { reason: 'busy' });
    const exp = { id: crypto.randomUUID(), action: m[1], title: titles[ids.indexOf(m[1])], startedAt: Date.now(), status: 'running' };
    state.running = exp; send('experiment', exp); play(m[1], exp);
    return json(202, exp);
  }
  json(404, { error: 'not found' });
}).listen(8787, () => console.log('mock chaos-api on http://localhost:8787'));
```

- [ ] **Step 2: Check it.**
  - Run `node scripts/lab-mock.mjs &`, then `curl -s localhost:8787/chaos/actions | head -c 120`.
  - Run `curl -s -N --max-time 2 localhost:8787/chaos/stream | head -c 200`; it should show a snapshot.
  - Kill it.
- [ ] **Step 3: Commit** `chore(lab): a local mock of chaos-api`

---

### Task 4: The page and the live scene

**Files:** Create `lab/index.html` and `lab/lab.js`; add the `.lab-*` section to `styles.css`.

This is design work. The structure, names and behaviour below are binding; the exact pixel styling is the implementer's to get right against `DESIGN.md`. Verify it visually (Task 6).

**`lab/index.html`:**

- **Shell:** copy it from `work/restore-drill/index.html`.
  - head: title `Break my Kubernetes lab · Het Patel`; description `A real Kubernetes cluster you can break. Pick a failure and watch Kubernetes and Argo CD heal it, live.`; canonical `https://hetops.dev/lab/`; og/twitter tags reuse `/assets/og/og-home.png`, or whatever the homepage uses.
  - Same nav and footer as that page, with no `aria-current` in the case-study nav.
- **Hero** (inside `<main id="main" class="lab-main wrap">`):
  - `<h1>` "Break my Kubernetes lab"
  - one lede line: "A real cluster on my server, not a simulation. Pick a failure below and watch Kubernetes and Argo CD put it back. Every request you see is real."
  - a mode pill `#lab-mode`: text `Connecting…`, then `Live` (moss dot) or `Simulation` (sclera-3), with `aria-live="polite"`.
- **`<section id="lab-live" hidden>`:**
  - **The scene `#lab-scene`:** an `<svg viewBox="0 0 720 720" role="img" aria-label="Live cluster: namespaces as rings, pods as nodes, requests as dots">` containing these groups:
    - `g.lab-rings`: two circles at r=150 (`clinic-data`) and r=270 (`clinic`), each with a mono ring label;
    - `g.lab-argo`: a circle at r=300 drawn as the gold Argo CD arc;
    - `g.lab-pods`;
    - `g.lab-dots`;
    - `circle.lab-pupil` at the centre, r=46, labelled "ingress" under it.
  - **`#lab-argo-state`:** a line under the scene, "Argo CD: Synced · Healthy", plus `#lab-probe-line` for the reduced-motion status line. That line is also visible as a quiet caption for everyone.
  - **`#lab-clock`:**
    - the running experiment's title;
    - a big gold mono timer `#lab-timer` (the one gold thing in this region), showing `0.0 s`;
    - the target `#lab-target`, "target 30 s".
    - After recovery the timer freezes, and the verdict shows `#lab-verdict`: "healed in 4.1 s, inside the 30 s target" (moss) or "… over the target" (alert).
  - **`#lab-actions`:**
    - three groups built from `GROUPS`, each an `<h3>` plus its note plus pill buttons `button.lab-act[data-action=id]` (with the `title` from `/chaos/actions`);
    - heavy actions get a mono `heavy` marker;
    - `#lab-check` is the Turnstile mount (`data-sitekey="1x00000000000000000000AA"`);
    - `#lab-say` (`aria-live="polite"`) holds refusal sentences.
  - **`#lab-story`:** "What just happened".
    - On an experiment start: that action's `explain`, plus a `<details>` toggle "The kubectl an engineer would run" showing `<code>` with `kubectl`.
    - Below it, an `ol#lab-feed` with the newest narration line first (from `diffSnapshots`; at most 12 lines kept; each `li` gets class `lab-ok|lab-warn|lab-down`).
  - **`#lab-incidents`:** "Recent experiments", an `ol`. Each row: title, `verdict(exp).label`, and target, with a relative time ("3 min ago"). At most 10.
- **`<section id="lab-sim" hidden>`:**
  - Copy the homepage `#chaos` section markup from `index.html` (lines 440-466) verbatim: same ids and classes, so `chaos.js` and the existing CSS work unchanged.
  - Change its sub-text to: "Simulation: the live lab is offline right now, so this runs the same scenarios in your browser."
- **Scripts:**
  - `<script src="/chaos.js" defer></script>`. It no-ops while `#chaos` is hidden and runs fine once the section is shown.
  - `<script type="module" src="/lab/lab.js"></script>`.
  - Turnstile is loaded **by `lab.js`** only in live mode (append `https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit` as a script), so simulation visitors never call Cloudflare.

**`lab/lab.js` behaviour:**

1. **Connect and choose a mode.**
   - `const API = apiBase(location.search)`. Open `new EventSource(API + '/chaos/stream')`.
   - If no `snapshot` event has arrived within 5 s, or the stream errors before the first snapshot, close it and enter **simulation mode**: unhide `#lab-sim`, set `#lab-mode` to `Simulation`, and stop.
   - On the first snapshot, enter **live mode**: unhide `#lab-live`, set `#lab-mode` to `Live`, then fetch `/chaos/actions`, `/chaos/incidents` and `/chaos/status`.
   - Let `EventSource` reconnect on its own after live mode starts; show `Reconnecting…` in `#lab-mode` while `readyState` is CONNECTING.
2. **`snapshot` event:**
   - Diff it against the previous snapshot with `diffSnapshots`, then prepend the lines to `#lab-feed`.
   - Re-render the pods with `ringLayout(livePods(ns.pods), …)` for each ring: a `g.lab-pod` per pod holding a circle (r=16) with class `lab-ok|lab-starting|lab-down` and an SVG `<title>` with the full name and state. Key nodes by pod name: update existing ones (move with a CSS transform transition) instead of rebuilding.
   - If a namespace has `exists:false`, give its ring class `lab-gone` (dashed, alert) and change the ring label to "clinic: deleted".
   - Argo CD:
     - the arc gets class `lab-synced` when Synced, otherwise `lab-drift` (dashed and pulsing, no pulse under reduced motion);
     - `#lab-argo-state` text reads `Argo CD: ${sync} · ${health}`, and while `operation === 'Running'` it reads `Argo CD: drift detected, reverting`.
3. **`probes` event:**
   - For each result, if motion is allowed, animate a 4 px dot from the pupil to that pod's position: moss if ok; if failed, an alert-coloured dot that travels out 40% of the way and fades.
   - Use the Web Animations API on a `circle` with `transform: translate(...)`; remove it on `finish`.
   - Spread each batch over 1 s (200 ms apart).
   - Always update `#lab-probe-line` from `probeSummary`: `Last second: 5 of 5 requests answered (2 pods)`.
4. **`experiment` event:**
   - `running`: set the clock title, start a `requestAnimationFrame` timer from `startedAt` (under reduced motion, update with `setInterval` every 1 s instead), show the target, write `explain` + `kubectl` into `#lab-story`, and disable every `.lab-act`.
   - `recovered`, `timeout` or `error`: stop the timer at `recoveryMs` (or the elapsed time), show `#lab-verdict` from `verdict(exp)`, prepend it to `#lab-incidents`, and re-enable the buttons.
   - The status from `/chaos/status` on load seeds a running experiment the same way, so a visitor arriving mid-experiment sees the clock running.
5. **Buttons:** handled in Task 5. In this task, render them disabled.
6. **Rules:**
   - Under reduced motion, render no dots and use no transitions.
   - Use `textContent` only.
   - Fire Umami events `lab-live` / `lab-sim` once per mode with `window.umami && window.umami.track(...)`.

**CSS** (append to `styles.css` under a `/* lab console */` comment):

- **Layout:** the scene on the left (about 58%), with clock, actions and story on the right. Single column under 1024 px; the scene stays a square with `max-width: 100%`.
- **Rings:** `stroke: var(--line-2)`, no fill.
- **Pods:**
  - `.lab-ok`: `var(--moss)`
  - `.lab-starting`: `var(--gold)` stroke only (hollow)
  - `.lab-down`: `var(--err)`
- **Pupil:** fill `var(--ink)` with a `var(--line-2)` stroke (One Pupil Rule).
- **Argo CD arc:** gold stroke 2 px.
- **Buttons:** reuse the line-pill look; disabled at 0.45 opacity.
- **Timer:** mono, gold, `clamp(2.4rem, 5vw, 3.6rem)`.
- **Structure:** no boxes; separate regions with 1 px `var(--line)` rules and space.
- **Feed lines:** mono 13 px, with a 6 px dot before each in its tone colour.

- [ ] **Step 1:** Write `lab/index.html`, `lab/lab.js` and the CSS as specified.
- [ ] **Step 2:** Add `node --check lab/lab.js` to the CI step from Task 2.
- [ ] **Step 3: Check it locally.**
  - Start `node scripts/lab-mock.mjs` and a static server at the repo root (`npx --yes http-server -p 4321 -c-1 .`).
  - Open `http://localhost:4321/lab/?api=http://localhost:8787`: live mode should come up, pods drawn on both rings, dots flowing, and the Argo CD state shown.
  - Open `http://localhost:4321/lab/` with the mock stopped: the simulation should appear within 5 s, labelled.
  - The console must have no errors in either mode.
- [ ] **Step 4: Commit** `feat(lab): the live cluster scene and the simulation fallback`

---

### Task 5: Actions, Turnstile, refusals and the incident log

**Files:** Modify `lab/lab.js` (and CSS if needed).

- [ ] **Step 1: Turnstile.**
  - In live mode, load the Turnstile script once.
  - Then `turnstile.render('#lab-check', { sitekey: el.dataset.sitekey, appearance: 'interaction-only', callback: (t) => { token = t; enableButtons(); }, 'expired-callback': () => { token = null; disableButtons(); } })`.
  - The buttons stay disabled until there is a token **and** no experiment is running **and** `status.enabled` is true.
  - If not enabled, write `refusalText('disabled')` into `#lab-say` and keep the buttons disabled.
- [ ] **Step 2: Press a button.**
  - `fetch(API + '/chaos/actions/' + id, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ turnstileToken: token }) })`.
  - Then always do `token = null; turnstile.reset('#lab-check')`.
  - A `202` needs no handling here: the `experiment` event drives the clock (Task 4).
  - Any other status: read the JSON and write `refusalText(body.reason, body.retryAfterMs)` into `#lab-say`.
  - A network failure: `refusalText()`.
  - Umami: `lab-break` with `{ action: id }`.
- [ ] **Step 3: Incident log.** Render `/chaos/incidents` (the first 10) on load. Prepend on every finished experiment. Refresh the relative times every 30 s.
- [ ] **Step 4: Check it with the mock** (the mock accepts any token; the test site key always passes):
  - Press "Kill a pod". The clock should start, an api node go red and disappear, a hollow gold node appear and turn moss, the feed narrate, the verdict appear, and an incident row be added.
  - Press "Nuke the clinic namespace". The outer ring should go dashed/alert, the Argo CD arc go dashed, and both recover.
  - Press a second button while one is running. All buttons should be disabled.
  - Then `curl -X POST localhost:8787/chaos/actions/kill-pod` while one is running. It should return 409, and the page should stay consistent.
- [ ] **Step 5: Commit** `feat(lab): chaos buttons with Turnstile, refusals and the incident log`

---

### Task 6: Wire it into the site, verify, PR

**Files:** Modify `index.html`, `sitemap.xml`, `Dockerfile`, `nginx/security-headers.conf`, `.github/workflows/ci.yml`.

- [ ] **Step 1: Homepage link.** In the `#chaos` section head of `index.html`, append to the `p.sub` a link: ` <a class="more" href="/lab/" data-umami-event="lab-open" data-umami-event-from="home-chaos">Break the real one <i class="ph ph-arrow-right"></i></a>`. If `ph-arrow-right` has no mask rule in `styles.css`, use an icon that has one, e.g. `ph-arrow-up-right`.
- [ ] **Step 2: Sitemap.** Add `<url><loc>https://hetops.dev/lab/</loc><changefreq>weekly</changefreq><priority>0.8</priority></url>` to `sitemap.xml`.
- [ ] **Step 3: Dockerfile.** Add `COPY lab /usr/share/nginx/html/lab` after the `writing` line. Do not copy `tests` or `scripts`.
- [ ] **Step 4: CSP** in `nginx/security-headers.conf`:
  - `connect-src`: append `https://lab.hetops.dev https://challenges.cloudflare.com`
  - `script-src`: append `https://challenges.cloudflare.com`
  - add the directive `frame-src https://challenges.cloudflare.com;`
  - Keep the existing hash untouched. `scripts/check-csp.mjs` only checks `index.html`'s inline script, and the lab page has no inline scripts.
- [ ] **Step 5: CI smoke test.** Find the docker-build smoke test's list of curled paths in `ci.yml` and add `/lab/`, `/lab/lab.js` and `/lab/core.js`.
- [ ] **Step 6: Visual verification (controller, with the Browser pane).**
  - Run the mock and the static server.
  - Screenshot live mode at desktop width and at 375 px: idle, mid-experiment, and after recovery.
  - Screenshot simulation mode.
  - Check reduced motion with the emulated media feature: no dots, and the probe line updates.
  - Fix anything that breaks `DESIGN.md` (boxes, glows, multiple gold accents in one region).
- [ ] **Step 7: PR.**
  - Commit `feat(lab): link the lab from the homepage; CSP for lab.hetops.dev and Turnstile`.
  - Push and open the PR "feat: hetops.dev/lab, break the real Kubernetes lab". Wait for CI to go green.
  - Merge (owner-approved self-merge), then verify `https://hetops.dev/lab/` after Coolify deploys. It should show **Simulation**, because Cloudflare Access still guards lab.hetops.dev until Task 7.

---

### Task 7 (owner): Open the stream to the public, in the Cloudflare dashboard

Until this task, `lab.hetops.dev` is guarded by Access, so the page always shows the simulation. Do this when you want the live view public. Experiments still stay off (the kill switch) until the go-public gate.

- [ ] **Step 1: Access bypass for `/chaos` only.**
  - In Zero Trust → Access → Applications → Add an application → Self-hosted, set name `lab-chaos-public`, domain `lab.hetops.dev`, path `chaos`.
  - Add a policy `public` with action **Bypass** and include **Everyone**.
  - A more specific path wins over the existing whole-host application, so `/`, `/api` and Argo CD stay owner-only.
  - Verify from a private browser window: `https://lab.hetops.dev/chaos/actions` returns the JSON list, and `https://lab.hetops.dev/` still asks for your email PIN.
- [ ] **Step 2: Rate limit the button.**
  - In the hetops.dev zone → Security → WAF → Rate limiting rules → Create, name the rule `chaos-actions`.
  - If the URI Path starts with `/chaos/actions/` and the request method is `POST`, then block; the threshold is 10 requests per 1 minute per IP, with a 1-minute duration.
- [ ] **Step 3: The real Turnstile widget.**
  - In Turnstile → Add widget, set name `hetops-lab`, hostname `hetops.dev`, and mode **Managed**.
  - Send Claude the **site key** (it is public).
  - Seal the **secret key** without printing it. On the server:

```bash
cd ~/hetops-k8s-lab && git pull
read -rs -p "Turnstile SECRET key: " TS; echo
printf %s "$TS" | kubectl -n chaos create secret generic chaos-secrets --from-file=TURNSTILE_SECRET=/dev/stdin --dry-run=client -o yaml | kubeseal --format yaml --merge-into apps/chaos/sealed-chaos-secrets.yaml; unset TS
BT=$(openssl rand -hex 24)
printf %s "$BT" | kubectl -n chaos create secret generic chaos-secrets --from-file=BYPASS_TOKEN=/dev/stdin --dry-run=client -o yaml | kubeseal --format yaml --merge-into apps/chaos/sealed-chaos-secrets.yaml
printf %s "$BT" | xclip -selection clipboard 2>/dev/null || { umask 077; printf %s "$BT" > ~/bypass-token.txt; }; unset BT
git commit -am "chaos: real Turnstile secret, rotate bypass token" && git push
kubectl -n chaos rollout restart deploy/chaos-api     # env vars from a Secret are read only at start
```

  - Store the new bypass token in your password manager straight from `~/bypass-token.txt` (open it in an editor, don't `cat` it into a screenshot), then `shred -u ~/bypass-token.txt`.
  - Claude then swaps `data-sitekey` in `lab/index.html` for the real site key (a small PR).
- [ ] **Step 4:** The kill switch stays `"false"` until game day and the 3-night self-test gate (plans 5 and 6). Until then, the page shows the live cluster with the buttons paused.
