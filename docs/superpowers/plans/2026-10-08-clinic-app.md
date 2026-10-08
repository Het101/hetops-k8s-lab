# Clinic App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Het101/hetops-clinic`, the Wizlo-shaped demo app (API, worker, migrate job, report job, web), and publish its ARM64 images to GHCR, ready for the platform labs to deploy.

**Architecture:** One Node 22 + Fastify codebase produces one API image, used four ways: `api` (server), `worker` (server with `RUN_JOBS=true`), `migrate` (`node api/src/migrate.js`) and `nightly-report` (`node api/src/jobs.js report`). A second, static web image is served by unprivileged nginx. Multi-tenancy follows the spec: an admin database lists tenants, and each tenant has its own database on the same Postgres server. Code is built for dependency injection: `buildApp({ config, db, actions })`, so every route is unit-tested without a database. One integration test runs against real Postgres in CI.

**Tech Stack:** Node 22, Fastify 5, node-postgres (`pg`) 8, `node:test`, Docker (multi-stage, non-root), GitHub Actions on `ubuntu-24.04-arm`, GHCR.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-08-chaos-lab-design.md` in `Het101/hetops-k8s-lab`.
- Images are ARM64 only (`linux/arm64`), tagged with the 7-character commit SHA. There is no `latest` tag. One extra tag, `bad`, is built with `READINESS_ALWAYS_FAIL=true`.
- Containers run as UID 1000, not root, and listen on port 8080. They must work with a read-only root filesystem (only `/tmp` is writable).
- `/internal/*` endpoints need header `X-Chaos-Token` equal to env `INTERNAL_TOKEN`. An empty token means they are disabled.
- Readiness checks only the admin database. It never checks tenant databases.
- No code, names or data from the healthcare client. The demo tenants are `riverside`, `northgate` and `lakeview`.
- Logs are JSON on stdout (Fastify's built-in pino).
- Commits and PRs carry no Claude attribution lines. Work goes through PRs to `main`.
- GitHub account: Het101. Use `GH_TOKEN=$(gh auth token --user Het101)`, and push with `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.

## File Structure

```text
hetops-clinic/
  package.json                 scripts, dependencies
  .gitignore, .dockerignore
  Dockerfile                   API image (api, worker, migrate, report)
  api/src/config.js            env -> config object (one responsibility: parsing)
  api/src/db.js                admin pool + per-tenant pools
  api/src/app.js               buildApp(): all HTTP routes, no I/O at import time
  api/src/jobs.js              reminders loop + nightly report (+ CLI entry)
  api/src/migrate.js           create databases, apply SQL migrations, seed tenants (+ CLI entry)
  api/src/server.js            process entry: wires config, db, app, jobs, signals
  api/migrations/admin/001_tenants.sql
  api/migrations/tenant/001_appointments.sql
  api/migrations/tenant/002_seed.sql
  api/test/config.test.js
  api/test/app.test.js
  api/test/jobs.test.js
  api/test/integration.test.js  (runs only when DB_HOST is set)
  web/index.html, web/app.js, web/style.css
  web/Dockerfile
  .github/workflows/ci.yml
  README.md
```

---

### Task 1: Repository and config parsing

**Files:**
- Create: `package.json`, `.gitignore`, `api/src/config.js`, `api/test/config.test.js`

**Interfaces:**
- Produces: `loadConfig(env = process.env) -> { port, db: { host, port, user, password, adminDb }, internalToken, runJobs, readinessAlwaysFail, version, pod }`. It throws `Error('missing env: ...')` when `DB_HOST`, `DB_USER` or `DB_PASSWORD` is missing.

- [ ] **Step 1: Create the GitHub repo and local clone**

```bash
cd "C:/Users/HetPatel/Personal/HetOps"
GH_TOKEN=$(gh auth token --user Het101) gh repo create Het101/hetops-clinic --public --description "Demo multi-tenant clinic app for the HetOps Kubernetes chaos lab"
git clone https://github.com/Het101/hetops-clinic.git
cd hetops-clinic
git checkout -b feat/clinic-app
```

- [ ] **Step 2: Add package.json and .gitignore**

`package.json`:

```json
{
  "name": "hetops-clinic",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "start": "node api/src/server.js",
    "migrate": "node api/src/migrate.js",
    "report": "node api/src/jobs.js report",
    "test": "node --test \"api/test/*.test.js\""
  }
}
```

`.gitignore`:

```text
node_modules/
```

Then install dependencies:

```bash
npm install fastify@^5 pg@^8
```

- [ ] **Step 3: Write the failing test**

`api/test/config.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../src/config.js';

const base = { DB_HOST: 'pg', DB_USER: 'clinic', DB_PASSWORD: 'secret' };

test('applies defaults', () => {
  const c = loadConfig(base);
  assert.equal(c.port, 8080);
  assert.deepEqual(c.db, { host: 'pg', port: 5432, user: 'clinic', password: 'secret', adminDb: 'clinic_admin' });
  assert.equal(c.internalToken, '');
  assert.equal(c.runJobs, false);
  assert.equal(c.readinessAlwaysFail, false);
  assert.equal(c.version, 'dev');
});

test('reads overrides', () => {
  const c = loadConfig({ ...base, PORT: '9000', DB_PORT: '6432', DB_ADMIN_NAME: 'adm', INTERNAL_TOKEN: 'tok',
    RUN_JOBS: 'true', READINESS_ALWAYS_FAIL: 'true', APP_VERSION: 'abc1234', HOSTNAME: 'api-7d9-x2' });
  assert.equal(c.port, 9000);
  assert.equal(c.db.port, 6432);
  assert.equal(c.db.adminDb, 'adm');
  assert.equal(c.internalToken, 'tok');
  assert.equal(c.runJobs, true);
  assert.equal(c.readinessAlwaysFail, true);
  assert.equal(c.version, 'abc1234');
  assert.equal(c.pod, 'api-7d9-x2');
});

test('fails fast on missing database settings', () => {
  assert.throws(() => loadConfig({ DB_HOST: 'pg' }), /missing env: DB_USER, DB_PASSWORD/);
});
```

- [ ] **Step 4: Run it and see it fail**

Run: `npm test`
Expected: FAIL, `Cannot find module '.../api/src/config.js'`.

- [ ] **Step 5: Implement**

`api/src/config.js`:

```js
// Parses environment variables once; everything else receives the result.
export function loadConfig(env = process.env) {
  const missing = ['DB_HOST', 'DB_USER', 'DB_PASSWORD'].filter((k) => !env[k]);
  if (missing.length) throw new Error(`missing env: ${missing.join(', ')}`);
  return {
    port: Number(env.PORT ?? 8080),
    db: {
      host: env.DB_HOST,
      port: Number(env.DB_PORT ?? 5432),
      user: env.DB_USER,
      password: env.DB_PASSWORD,
      adminDb: env.DB_ADMIN_NAME ?? 'clinic_admin',
    },
    internalToken: env.INTERNAL_TOKEN ?? '', // empty = /internal/* always refuses
    runJobs: env.RUN_JOBS === 'true',
    readinessAlwaysFail: env.READINESS_ALWAYS_FAIL === 'true',
    version: env.APP_VERSION ?? 'dev',
    pod: env.HOSTNAME ?? 'local',
  };
}
```

- [ ] **Step 6: Run the tests and see them pass**

Run: `npm test`
Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json .gitignore api/src/config.js api/test/config.test.js
git commit -m "feat: config parsing with fail-fast on missing database settings"
```

---

### Task 2: HTTP app: health, whoami, internal chaos endpoints

**Files:**
- Create: `api/src/app.js`, `api/test/app.test.js`

**Interfaces:**
- Consumes: the config object from Task 1.
- Produces:
  - `buildApp({ config, db, actions = defaultActions, logger = true }) -> FastifyInstance`.
  - `tokenOk(given, expected) -> boolean`.
  - `defaultActions = { crash, leak, hang }`.
  - The `db` contract that Task 3 implements: `ping(): Promise<void>`, `listTenants(): Promise<{slug,name,db_name}[]>`, `tenant(slug): Promise<pg.Pool|null>`, `close(): Promise<void>`.

- [ ] **Step 1: Write the failing tests**

`api/test/app.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp, tokenOk } from '../src/app.js';
import { loadConfig } from '../src/config.js';

const config = (extra = {}) => ({
  ...loadConfig({ DB_HOST: 'h', DB_USER: 'u', DB_PASSWORD: 'p', INTERNAL_TOKEN: 'tok', HOSTNAME: 'api-1', APP_VERSION: 'v1' }),
  ...extra,
});
const fakeDb = (over = {}) => ({
  ping: async () => {},
  listTenants: async () => [{ slug: 'riverside', name: 'Riverside Family Clinic', db_name: 'clinic_riverside' }],
  tenant: async () => null,
  close: async () => {},
  ...over,
});
const app = (opts = {}) => buildApp({ config: config(), db: fakeDb(), logger: false, ...opts });

test('healthz is always ok', async () => {
  const res = await app().inject('/healthz');
  assert.equal(res.statusCode, 200);
});

test('readyz is 200 when the admin database answers', async () => {
  assert.equal((await app().inject('/readyz')).statusCode, 200);
});

test('readyz is 503 when the admin database fails', async () => {
  const res = await app({ db: fakeDb({ ping: async () => { throw new Error('down'); } }) }).inject('/readyz');
  assert.equal(res.statusCode, 503);
  assert.equal(res.json().reason, 'database');
});

test('readyz is 503 in the bad-release build', async () => {
  const res = await app({ config: config({ readinessAlwaysFail: true }) }).inject('/readyz');
  assert.equal(res.statusCode, 503);
  assert.equal(res.json().reason, 'bad-release');
});

test('whoami reports pod, version and tenant count', async () => {
  const res = await app().inject('/api/whoami');
  assert.deepEqual(res.json(), { pod: 'api-1', version: 'v1', tenants: 1 });
});

test('clinics list hides database names', async () => {
  const res = await app().inject('/api/clinics');
  assert.deepEqual(res.json(), [{ slug: 'riverside', name: 'Riverside Family Clinic' }]);
});

test('internal endpoints refuse a missing or wrong token', async () => {
  const calls = [];
  const a = app({ actions: { crash: () => calls.push('crash') } });
  assert.equal((await a.inject({ method: 'POST', url: '/internal/crash' })).statusCode, 401);
  assert.equal((await a.inject({ method: 'POST', url: '/internal/crash', headers: { 'x-chaos-token': 'nope' } })).statusCode, 401);
  assert.deepEqual(calls, []);
});

test('internal endpoints are disabled when no token is configured', async () => {
  const a = app({ config: config({ internalToken: '' }) });
  const res = await a.inject({ method: 'POST', url: '/internal/crash', headers: { 'x-chaos-token': '' } });
  assert.equal(res.statusCode, 401);
});

test('internal action runs after the 202 is sent', async () => {
  const calls = [];
  const a = app({ actions: { leak: () => calls.push('leak') } });
  const res = await a.inject({ method: 'POST', url: '/internal/leak', headers: { 'x-chaos-token': 'tok' } });
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json(), { accepted: 'leak', pod: 'api-1' });
  await new Promise((r) => setTimeout(r, 150));
  assert.deepEqual(calls, ['leak']);
});

test('unknown and prototype action names are 404', async () => {
  const a = app({ actions: { crash: () => {} } });
  for (const name of ['nope', 'constructor', '__proto__', 'toString']) {
    const res = await a.inject({ method: 'POST', url: `/internal/${name}`, headers: { 'x-chaos-token': 'tok' } });
    assert.equal(res.statusCode, 404, name);
  }
});

test('tokenOk compares exactly', () => {
  assert.equal(tokenOk('tok', 'tok'), true);
  assert.equal(tokenOk('tok2', 'tok'), false);
  assert.equal(tokenOk(undefined, 'tok'), false);
  assert.equal(tokenOk('', ''), false);
});
```

- [ ] **Step 2: Run it and see it fail**

Run: `npm test`
Expected: FAIL, `Cannot find module '.../api/src/app.js'`.

- [ ] **Step 3: Implement**

`api/src/app.js`:

```js
import Fastify from 'fastify';
import { createHash, timingSafeEqual } from 'node:crypto';

// What the chaos API can make a pod do. Each one is healed by a different Kubernetes mechanism.
export const defaultActions = {
  crash: () => process.exit(1), // kubelet restarts the container
  leak: () => { // grows past the memory limit -> OOMKilled (exit 137)
    const hog = [];
    setInterval(() => hog.push(Buffer.alloc(16 * 1024 * 1024, 1)), 250);
  },
  hang: () => { for (;;) { /* block the event loop until the liveness probe restarts us */ } },
};

export function tokenOk(given, expected) {
  if (typeof given !== 'string' || !expected) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function buildApp({ config, db, actions = defaultActions, logger = true }) {
  const app = Fastify({ logger });

  app.get('/healthz', async () => ({ ok: true }));

  // Readiness checks the admin database only: one tenant database failing must not pull every pod out of service.
  app.get('/readyz', async (req, reply) => {
    if (config.readinessAlwaysFail) return reply.code(503).send({ ready: false, reason: 'bad-release' });
    try {
      await db.ping();
      return { ready: true };
    } catch (err) {
      req.log.warn({ err: err.message }, 'readiness: admin database unreachable');
      return reply.code(503).send({ ready: false, reason: 'database' });
    }
  });

  app.get('/api/whoami', async () => ({
    pod: config.pod,
    version: config.version,
    tenants: (await db.listTenants()).length,
  }));

  app.get('/api/clinics', async () => (await db.listTenants()).map(({ slug, name }) => ({ slug, name })));

  app.register(async (internal) => {
    internal.addHook('onRequest', async (req, reply) => {
      if (!tokenOk(req.headers['x-chaos-token'], config.internalToken)) {
        return reply.code(401).send({ error: 'unauthorized' });
      }
    });
    internal.post('/internal/:action', async (req, reply) => {
      const name = req.params.action;
      if (!Object.hasOwn(actions, name)) return reply.code(404).send({ error: 'unknown action' });
      setTimeout(actions[name], 100); // let the 202 reach the caller first
      return reply.code(202).send({ accepted: name, pod: config.pod });
    });
  });

  return app;
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `npm test`
Expected: all tests pass (3 config + 11 app).

- [ ] **Step 5: Commit**

```bash
git add api/src/app.js api/test/app.test.js
git commit -m "feat: health, readiness, whoami and token-guarded chaos endpoints"
```

---

### Task 3: Tenant data access, appointment routes, CPU work route

**Files:**
- Create: `api/src/db.js`
- Modify: `api/src/app.js` (add three routes before `app.register(...)`)
- Modify: `api/test/app.test.js` (append tests)

**Interfaces:**
- Consumes: the `db` contract from Task 2, and `config.db` from Task 1.
- Produces: `createDb(dbConfig) -> { ping, listTenants, tenant, close }` (the contract above). Routes: `GET /api/clinics/:slug/appointments`, `POST /api/clinics/:slug/appointments` (body `{ patient, at }`), `GET /api/work`.

- [ ] **Step 1: Write the failing tests (append to `api/test/app.test.js`)**

```js
const fakePool = () => {
  const queries = [];
  return {
    queries,
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.startsWith('insert')) return { rows: [{ id: 1, patient: params[0], at: params[1], reminded: false }] };
      return { rows: [{ id: 1, patient: 'Ana', at: '2026-10-09T10:00:00.000Z', reminded: false }] };
    },
  };
};

test('appointments: unknown clinic is 404', async () => {
  const res = await app().inject('/api/clinics/nowhere/appointments');
  assert.equal(res.statusCode, 404);
});

test('appointments: lists from the tenant database', async () => {
  const pool = fakePool();
  const res = await app({ db: fakeDb({ tenant: async (slug) => (slug === 'riverside' ? pool : null) }) })
    .inject('/api/clinics/riverside/appointments');
  assert.equal(res.statusCode, 200);
  assert.equal(res.json()[0].patient, 'Ana');
  assert.match(pool.queries[0].sql, /from appointments/);
});

test('appointments: creates and trims to the newest 200', async () => {
  const pool = fakePool();
  const res = await app({ db: fakeDb({ tenant: async () => pool }) }).inject({
    method: 'POST', url: '/api/clinics/riverside/appointments',
    payload: { patient: 'Ben', at: '2026-10-09T11:00:00Z' },
  });
  assert.equal(res.statusCode, 201);
  assert.equal(res.json().patient, 'Ben');
  assert.match(pool.queries[1].sql, /limit 200/);
});

test('appointments: rejects bad input', async () => {
  const a = app({ db: fakeDb({ tenant: async () => fakePool() }) });
  for (const payload of [{}, { patient: '', at: '2026-10-09T11:00:00Z' }, { patient: 'x', at: 'tomorrow' },
    { patient: 'x'.repeat(81), at: '2026-10-09T11:00:00Z' }, { patient: 'x', at: '2026-10-09T11:00:00Z', extra: 1 }]) {
    const res = await a.inject({ method: 'POST', url: '/api/clinics/riverside/appointments', payload });
    assert.equal(res.statusCode, 400, JSON.stringify(payload));
  }
});

test('work burns CPU and returns a short hash', async () => {
  const res = await app().inject('/api/work');
  assert.equal(res.statusCode, 200);
  assert.match(res.json().hash, /^[0-9a-f]{12}$/);
});
```

Note on the `extra: 1` case: Fastify's default Ajv config strips extra properties (`removeAdditional: true`) instead of rejecting them. Step 3 turns that off for this route so the test holds.

- [ ] **Step 2: Run it and see it fail**

Run: `npm test`
Expected: the five new tests fail with 404 from Fastify (route not found).

- [ ] **Step 3: Implement the routes (add to `buildApp` in `api/src/app.js`, just before `app.register(`)**

```js
  app.get('/api/clinics/:slug/appointments', async (req, reply) => {
    const pool = await db.tenant(req.params.slug);
    if (!pool) return reply.code(404).send({ error: 'unknown clinic' });
    const { rows } = await pool.query('select id, patient, at, reminded from appointments order by at desc limit 20');
    return rows;
  });

  app.post('/api/clinics/:slug/appointments', {
    schema: {
      body: {
        type: 'object',
        required: ['patient', 'at'],
        additionalProperties: false,
        properties: {
          patient: { type: 'string', minLength: 1, maxLength: 80 },
          at: { type: 'string', format: 'date-time' },
        },
      },
    },
    validatorCompiler: ({ schema }) => strictAjv.compile(schema),
  }, async (req, reply) => {
    const pool = await db.tenant(req.params.slug);
    if (!pool) return reply.code(404).send({ error: 'unknown clinic' });
    const { rows } = await pool.query(
      'insert into appointments (patient, at) values ($1, $2) returning id, patient, at, reminded',
      [req.body.patient, req.body.at],
    );
    // ponytail: public demo, keep only the newest 200 rows per clinic; a proper retention job if this ever matters
    await pool.query('delete from appointments where id not in (select id from appointments order by id desc limit 200)');
    return reply.code(201).send(rows[0]);
  });

  // Deliberately CPU-heavy, for the traffic-spike experiment and the HPA.
  app.get('/api/work', async () => {
    let h = 'work';
    for (let i = 0; i < 20000; i++) h = createHash('sha256').update(h).digest('hex');
    return { hash: h.slice(0, 12) };
  });
```

Add the strict validator near the top of `api/src/app.js`. Fastify 5 depends on `ajv` and `ajv-formats`, so install them explicitly to import them:

```bash
npm install ajv@^8 ajv-formats@^3
```

```js
import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const strictAjv = addFormats(new Ajv({ allErrors: true, removeAdditional: false }));
```

- [ ] **Step 4: Implement `api/src/db.js`**

```js
import pg from 'pg';

// Admin pool for the tenant directory, plus one small pool per tenant database.
export function createDb(cfg) {
  const base = {
    host: cfg.host, port: cfg.port, user: cfg.user, password: cfg.password,
    connectionTimeoutMillis: 2000, query_timeout: 2000,
  };
  const admin = new pg.Pool({ ...base, database: cfg.adminDb, max: 5 });
  // ponytail: unbounded map, fine for 3 tenants; LRU with idle-pool close if tenants grow (see the healthcare platform lesson)
  const tenantPools = new Map();

  return {
    async ping() {
      await admin.query('select 1');
    },
    async listTenants() {
      const { rows } = await admin.query('select slug, name, db_name from tenants order by slug');
      return rows;
    },
    async tenant(slug) {
      if (!tenantPools.has(slug)) {
        const { rows } = await admin.query('select db_name from tenants where slug = $1', [slug]);
        if (!rows.length) return null;
        tenantPools.set(slug, new pg.Pool({ ...base, database: rows[0].db_name, max: 2 }));
      }
      return tenantPools.get(slug);
    },
    async close() {
      await Promise.all([admin.end(), ...[...tenantPools.values()].map((p) => p.end())]);
    },
  };
}
```

- [ ] **Step 5: Run the tests and see them pass**

Run: `npm test`
Expected: all tests pass (3 config + 16 app).

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json api/src/app.js api/src/db.js api/test/app.test.js
git commit -m "feat: per-tenant appointment routes, strict validation, CPU work route"
```

---

### Task 4: Migrations, demo tenants, and the integration test

**Files:**
- Create: `api/src/migrate.js`, `api/migrations/admin/001_tenants.sql`, `api/migrations/tenant/001_appointments.sql`, `api/migrations/tenant/002_seed.sql`, `api/test/integration.test.js`

**Interfaces:**
- Consumes: `loadConfig` (Task 1), `createDb` (Task 3), `buildApp` (Task 2).
- Produces:
  - `migrateAll({ db, failOnPurpose = false }, log = jsonLog) -> Promise<void>`.
  - `ensureDatabase(dbConfig, name) -> Promise<void>`.
  - `applyMigrations(client, dir) -> Promise<string[]>` (the files it applied).
  - `DEMO_TENANTS`.
  - CLI: `node api/src/migrate.js` exits 0 on success and 1 on failure. With `MIGRATE_FAIL=true` it fails on purpose (used in the private failing-migration lab, L7).

- [ ] **Step 1: Write the SQL**

`api/migrations/admin/001_tenants.sql`:

```sql
create table tenants (
  slug    text primary key,
  name    text not null,
  db_name text not null unique
);
```

`api/migrations/tenant/001_appointments.sql`:

```sql
create table appointments (
  id         bigserial primary key,
  patient    text not null,
  at         timestamptz not null,
  reminded   boolean not null default false,
  created_at timestamptz not null default now()
);
create table reports (
  day          date primary key,
  appointments integer not null
);
```

`api/migrations/tenant/002_seed.sql`:

```sql
insert into appointments (patient, at) values
  ('A. Patel', now() + interval '30 minutes'),
  ('J. Smith', now() + interval '3 hours'),
  ('M. Garcia', now() + interval '1 day');
```

- [ ] **Step 2: Write the failing integration test**

`api/test/integration.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../src/config.js';
import { createDb } from '../src/db.js';
import { buildApp } from '../src/app.js';
import { migrateAll } from '../src/migrate.js';

const skip = process.env.DB_HOST ? false : 'set DB_HOST, DB_USER, DB_PASSWORD to run against Postgres';

test('migrate is idempotent, then an appointment can be booked', { skip }, async () => {
  const config = loadConfig({ ...process.env, INTERNAL_TOKEN: 't' });
  const quiet = () => {};
  await migrateAll({ db: config.db }, quiet);
  await migrateAll({ db: config.db }, quiet); // second run must change nothing

  const db = createDb(config.db);
  const app = buildApp({ config, db, logger: false });
  try {
    assert.equal((await app.inject('/readyz')).statusCode, 200);
    assert.equal((await app.inject('/api/whoami')).json().tenants, 3);

    const created = await app.inject({
      method: 'POST', url: '/api/clinics/riverside/appointments',
      payload: { patient: 'Integration Test', at: '2026-10-09T10:00:00Z' },
    });
    assert.equal(created.statusCode, 201);

    const list = (await app.inject('/api/clinics/riverside/appointments')).json();
    assert.ok(list.some((a) => a.patient === 'Integration Test'));
    // tenant isolation: northgate's database must not see riverside's row
    const other = (await app.inject('/api/clinics/northgate/appointments')).json();
    assert.ok(!other.some((a) => a.patient === 'Integration Test'));
  } finally {
    await app.close();
    await db.close();
  }
});

test('MIGRATE_FAIL makes the migration fail on purpose', async () => {
  const config = loadConfig({ DB_HOST: 'unused', DB_USER: 'u', DB_PASSWORD: 'p' });
  await assert.rejects(migrateAll({ db: config.db, failOnPurpose: true }, () => {}), /failing on purpose/);
});
```

- [ ] **Step 3: Run it and see it fail**

Run: `npm test`
Expected: FAIL, `Cannot find module '.../api/src/migrate.js'`. (The Postgres test is skipped locally if `DB_HOST` is unset; CI runs it.)

- [ ] **Step 4: Implement `api/src/migrate.js`**

```js
import pg from 'pg';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadConfig } from './config.js';

const MIGRATIONS = fileURLToPath(new URL('../migrations/', import.meta.url));
const SAFE_NAME = /^[a-z][a-z0-9_]*$/;

export const DEMO_TENANTS = [
  { slug: 'riverside', name: 'Riverside Family Clinic', db: 'clinic_riverside' },
  { slug: 'northgate', name: 'Northgate Dental', db: 'clinic_northgate' },
  { slug: 'lakeview', name: 'Lakeview Physio', db: 'clinic_lakeview' },
];

const jsonLog = (msg, extra = {}) => console.log(JSON.stringify({ msg, ...extra }));

async function withClient(cfg, database, fn) {
  const client = new pg.Client({ host: cfg.host, port: cfg.port, user: cfg.user, password: cfg.password, database });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

export async function ensureDatabase(cfg, name) {
  if (!SAFE_NAME.test(name)) throw new Error(`unsafe database name: ${name}`);
  await withClient(cfg, 'postgres', async (c) => {
    const { rowCount } = await c.query('select 1 from pg_database where datname = $1', [name]);
    if (!rowCount) await c.query(`create database "${name}"`); // name checked against SAFE_NAME above
  });
}

export async function applyMigrations(client, dir) {
  await client.query('create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())');
  const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort();
  const applied = [];
  for (const file of files) {
    const { rowCount } = await client.query('select 1 from schema_migrations where name = $1', [file]);
    if (rowCount) continue;
    const sql = await readFile(join(dir, file), 'utf8');
    await client.query('begin');
    try {
      await client.query(sql);
      await client.query('insert into schema_migrations (name) values ($1)', [file]);
      await client.query('commit');
      applied.push(file);
    } catch (err) {
      await client.query('rollback');
      throw new Error(`${file}: ${err.message}`);
    }
  }
  return applied;
}

export async function migrateAll({ db: cfg, failOnPurpose = false }, log = jsonLog) {
  if (failOnPurpose) throw new Error('MIGRATE_FAIL is set: failing on purpose (failing-migration lab)');

  await ensureDatabase(cfg, cfg.adminDb);
  const tenants = await withClient(cfg, cfg.adminDb, async (c) => {
    const applied = await applyMigrations(c, join(MIGRATIONS, 'admin'));
    log('admin migrated', { applied });
    for (const t of DEMO_TENANTS) {
      await c.query('insert into tenants (slug, name, db_name) values ($1, $2, $3) on conflict (slug) do nothing', [t.slug, t.name, t.db]);
    }
    return (await c.query('select slug, db_name from tenants order by slug')).rows;
  });

  for (const t of tenants) {
    await ensureDatabase(cfg, t.db_name);
    const applied = await withClient(cfg, t.db_name, (c) => applyMigrations(c, join(MIGRATIONS, 'tenant')));
    log('tenant migrated', { tenant: t.slug, applied });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = loadConfig();
  migrateAll({ db: config.db, failOnPurpose: process.env.MIGRATE_FAIL === 'true' }).then(
    () => process.exit(0),
    (err) => {
      console.error(JSON.stringify({ msg: 'migration failed', error: err.message }));
      process.exit(1); // the Job's backoffLimit: 0 turns this into a blocked rollout
    },
  );
}
```

- [ ] **Step 5: Run the tests**

Run: `npm test`
Expected: all unit tests pass. The integration test is reported as skipped locally unless `DB_HOST` is set. If Docker is available, run it for real:

```bash
docker run -d --name clinic-pg -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
DB_HOST=localhost DB_USER=postgres DB_PASSWORD=test npm test
docker rm -f clinic-pg
```

Expected with Docker: all tests pass, including the integration test.

- [ ] **Step 6: Commit**

```bash
git add api/src/migrate.js api/migrations api/test/integration.test.js
git commit -m "feat: idempotent per-tenant migrations with demo clinics and failure switch"
```

---

### Task 5: Background jobs: reminders loop and nightly report

**Files:**
- Create: `api/src/jobs.js`, `api/test/jobs.test.js`

**Interfaces:**
- Consumes: the `db` contract (Task 2/3).
- Produces:
  - `runReminders(db, log) -> Promise<number>` (rows reminded).
  - `startJobs({ db, log, everyMs = 60000 }) -> Timer`.
  - `runReport(db, log) -> Promise<void>`.
  - CLI: `node api/src/jobs.js report`.
  - `log` is pino-shaped: `{ info(obj, msg), error(obj, msg) }`.

- [ ] **Step 1: Write the failing tests**

`api/test/jobs.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runReminders, runReport } from '../src/jobs.js';

function setup(rowCount) {
  const queries = [];
  const pool = { query: async (sql) => { queries.push(sql); return { rowCount }; } };
  const db = {
    listTenants: async () => [{ slug: 'riverside' }, { slug: 'lakeview' }],
    tenant: async () => pool,
  };
  const lines = [];
  const log = { info: (obj, msg) => lines.push({ ...obj, msg }), error: (obj, msg) => lines.push({ ...obj, msg }) };
  return { db, log, queries, lines };
}

test('reminders run once per tenant and log only when something changed', async () => {
  const { db, log, queries, lines } = setup(2);
  assert.equal(await runReminders(db, log), 4);
  assert.equal(queries.length, 2);
  assert.match(queries[0], /set reminded = true/);
  assert.deepEqual(lines.map((l) => l.tenant), ['riverside', 'lakeview']);
});

test('reminders stay quiet when nothing is due', async () => {
  const { db, log, lines } = setup(0);
  assert.equal(await runReminders(db, log), 0);
  assert.equal(lines.length, 0);
});

test('report upserts one row per tenant', async () => {
  const { db, log, queries } = setup(1);
  await runReport(db, log);
  assert.equal(queries.length, 2);
  assert.match(queries[0], /on conflict \(day\) do update/);
});
```

- [ ] **Step 2: Run it and see it fail**

Run: `npm test`
Expected: FAIL, `Cannot find module '.../api/src/jobs.js'`.

- [ ] **Step 3: Implement `api/src/jobs.js`**

```js
import { pathToFileURL } from 'node:url';
import pino from 'pino';
import { loadConfig } from './config.js';
import { createDb } from './db.js';

// Runs only in the worker Deployment (RUN_JOBS=true). Running it in every API replica
// would remind every patient once per replica: the scheduled-jobs lesson from the healthcare platform.
export async function runReminders(db, log) {
  let total = 0;
  for (const t of await db.listTenants()) {
    const pool = await db.tenant(t.slug);
    const { rowCount } = await pool.query(
      "update appointments set reminded = true where not reminded and at < now() + interval '1 hour'",
    );
    if (rowCount) log.info({ tenant: t.slug, reminded: rowCount }, 'reminders sent');
    total += rowCount;
  }
  return total;
}

export function startJobs({ db, log, everyMs = 60000 }) {
  const tick = () => runReminders(db, log).catch((err) => log.error({ err: err.message }, 'reminders failed'));
  tick();
  return setInterval(tick, everyMs);
}

export async function runReport(db, log) {
  for (const t of await db.listTenants()) {
    const pool = await db.tenant(t.slug);
    await pool.query(
      `insert into reports (day, appointments)
       select current_date, count(*) from appointments
       on conflict (day) do update set appointments = excluded.appointments`,
    );
    log.info({ tenant: t.slug }, 'nightly report written');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] === 'report') {
  const log = pino();
  const db = createDb(loadConfig().db);
  runReport(db, log)
    .then(() => db.close())
    .then(() => process.exit(0), (err) => { log.error({ err: err.message }, 'report failed'); process.exit(1); });
}
```

`pino` is already installed as a Fastify dependency. Add it explicitly so the import is declared:

```bash
npm install pino@^9
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `npm test`
Expected: all tests pass (3 new job tests).

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json api/src/jobs.js api/test/jobs.test.js
git commit -m "feat: reminders loop for the worker and a nightly report job"
```

---

### Task 6: Server entry point and the API image

**Files:**
- Create: `api/src/server.js`, `Dockerfile`, `.dockerignore`

**Interfaces:**
- Consumes: `loadConfig`, `createDb`, `buildApp`, `startJobs`.
- Produces: an image whose default command is the server. The build args are `APP_VERSION` and `READINESS_ALWAYS_FAIL`; it runs as UID 1000 on port 8080. The same image runs migrations with command `node api/src/migrate.js`, and the report with `node api/src/jobs.js report`.

- [ ] **Step 1: Implement `api/src/server.js`**

```js
import { loadConfig } from './config.js';
import { createDb } from './db.js';
import { buildApp } from './app.js';
import { startJobs } from './jobs.js';

const config = loadConfig();
const db = createDb(config.db);
const app = buildApp({ config, db });

if (config.runJobs) startJobs({ db, log: app.log });

// Kubernetes sends SIGTERM, waits terminationGracePeriodSeconds, then SIGKILL.
// Closing Fastify finishes in-flight requests before we exit.
const shutdown = async (signal) => {
  app.log.info({ signal }, 'shutting down');
  await app.close();
  await db.close();
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

await app.listen({ port: config.port, host: '0.0.0.0' });
```

- [ ] **Step 2: Check it fails fast without configuration**

Run: `node api/src/server.js`
Expected: the process exits immediately with `Error: missing env: DB_HOST, DB_USER, DB_PASSWORD`. That's the CrashLoopBackOff you'd see if the Secret were missing, which is action 11's failure mode.

- [ ] **Step 3: Write `Dockerfile` and `.dockerignore`**

`Dockerfile`:

```dockerfile
# Build stage: production dependencies only.
FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Runtime stage.
FROM node:22-slim
ARG APP_VERSION=dev
ARG READINESS_ALWAYS_FAIL=false
ENV NODE_ENV=production \
    APP_VERSION=$APP_VERSION \
    READINESS_ALWAYS_FAIL=$READINESS_ALWAYS_FAIL \
    PORT=8080
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY api/src ./api/src
COPY api/migrations ./api/migrations
# Numeric UID so Kubernetes can verify runAsNonRoot (the node image's "node" user is 1000).
USER 1000
EXPOSE 8080
CMD ["node", "api/src/server.js"]
```

`.dockerignore`:

```text
node_modules
.git
api/test
web
```

- [ ] **Step 4: Build and smoke-test the image (only if Docker is available locally; otherwise CI covers it in Task 8)**

```bash
docker build -t clinic-api:local .
docker run --rm clinic-api:local node -e "console.log(process.getuid())"
```

Expected: the build succeeds and the second command prints `1000`.

- [ ] **Step 5: Commit**

```bash
git add api/src/server.js Dockerfile .dockerignore
git commit -m "feat: server entry with graceful SIGTERM and a non-root API image"
```

---

### Task 7: Web front end and its image

**Files:**
- Create: `web/index.html`, `web/app.js`, `web/style.css`, `web/Dockerfile`

**Interfaces:**
- Consumes: `/api/clinics`, `/api/clinics/:slug/appointments` (GET, POST) and `/api/whoami`, all same-origin. The Ingress (lab L5) routes `/api` to the api Service.
- Produces: image `clinic-web`, serving static files on port 8080 as a non-root user.

- [ ] **Step 1: Write `web/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Clinic bookings demo</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main>
    <h1>Clinic bookings</h1>
    <p class="note">Demo app for the HetOps Kubernetes chaos lab. Every name and booking here is fake.</p>
    <label>Clinic <select id="clinic"></select></label>
    <form id="book">
      <input id="patient" placeholder="Patient name" maxlength="80" required>
      <input id="at" type="datetime-local" required>
      <button type="submit">Book</button>
    </form>
    <ul id="list"></ul>
    <p class="pod" id="pod" aria-live="polite">Connecting...</p>
  </main>
  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Write `web/app.js`**

```js
const $ = (id) => document.getElementById(id);
const DOWN = 'API unavailable: the cluster is healing';

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) throw new Error(String(res.status));
  return res.json();
}

async function loadList() {
  const rows = await api(`/api/clinics/${encodeURIComponent($('clinic').value)}/appointments`);
  $('list').replaceChildren(...rows.map((a) => {
    const li = document.createElement('li');
    li.textContent = `${new Date(a.at).toLocaleString()} · ${a.patient}${a.reminded ? ' · reminded' : ''}`;
    return li;
  }));
}

async function loadClinics() {
  const clinics = await api('/api/clinics');
  $('clinic').replaceChildren(...clinics.map((c) => new Option(c.name, c.slug)));
  await loadList();
}

async function whoami() {
  try {
    const w = await api('/api/whoami');
    $('pod').textContent = `Served by ${w.pod} · ${w.version}`;
  } catch {
    $('pod').textContent = DOWN;
  }
}

$('clinic').addEventListener('change', () => loadList().catch(() => { $('pod').textContent = DOWN; }));
$('book').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    await api(`/api/clinics/${encodeURIComponent($('clinic').value)}/appointments`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ patient: $('patient').value, at: new Date($('at').value).toISOString() }),
    });
    $('patient').value = '';
    await loadList();
  } catch {
    $('pod').textContent = DOWN;
  }
});

loadClinics().catch(() => { $('pod').textContent = DOWN; });
whoami();
setInterval(whoami, 2000);
```

- [ ] **Step 3: Write `web/style.css`**

```css
:root { color-scheme: light dark; --ink: #1c1d1f; --muted: #5d6066; --line: #d9dbe0; --bg: #fbfbfa; }
@media (prefers-color-scheme: dark) { :root { --ink: #e8e8e6; --muted: #a0a3a8; --line: #33363b; --bg: #141517; } }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 system-ui, sans-serif; }
main { max-width: 640px; margin: 0 auto; padding: 32px 16px; }
.note, .pod { color: var(--muted); font-size: 14px; }
form { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0; }
input, select, button { font: inherit; padding: 8px 10px; border: 1px solid var(--line); border-radius: 6px; background: transparent; color: inherit; }
button { cursor: pointer; }
ul { padding: 0; list-style: none; }
li { padding: 8px 0; border-bottom: 1px solid var(--line); }
.pod { font-family: ui-monospace, monospace; }
```

- [ ] **Step 4: Write `web/Dockerfile`**

```dockerfile
# Unprivileged nginx listens on 8080 and runs as UID 101.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY web/index.html web/app.js web/style.css /usr/share/nginx/html/
EXPOSE 8080
```

- [ ] **Step 5: Check the page renders (optional, if Docker is available)**

```bash
docker build -f web/Dockerfile -t clinic-web:local .
docker run --rm -p 8081:8080 clinic-web:local
```

Open `http://localhost:8081`. Expected: the page loads and shows "API unavailable: the cluster is healing" (there's no API behind it locally). That's the same message visitors see during a namespace nuke.

- [ ] **Step 6: Commit**

```bash
git add web
git commit -m "feat: static booking page showing which pod served it"
```

---

### Task 8: CI, ARM64 images on GHCR, README, PR

**Files:**
- Create: `.github/workflows/ci.yml`, `README.md`

**Interfaces:**
- Produces, on every push to `main`: `ghcr.io/het101/clinic-api:<sha7>`, `ghcr.io/het101/clinic-api:bad`, `ghcr.io/het101/clinic-web:<sha7>`. The labs and the chaos API reference these names.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: test
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s --health-timeout 5s --health-retries 10
    env:
      DB_HOST: localhost
      DB_USER: postgres
      DB_PASSWORD: test
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npm test

  images:
    if: github.event_name == 'push'
    needs: test
    runs-on: ubuntu-24.04-arm   # native ARM64 build, no QEMU; matches the Oracle ARM node
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: v
        run: echo "sha=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - name: api image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/arm64
          push: true
          build-args: |
            APP_VERSION=${{ steps.v.outputs.sha }}
          tags: ghcr.io/het101/clinic-api:${{ steps.v.outputs.sha }}
      - name: api bad-release image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/arm64
          push: true
          build-args: |
            APP_VERSION=bad-${{ steps.v.outputs.sha }}
            READINESS_ALWAYS_FAIL=true
          tags: ghcr.io/het101/clinic-api:bad
      - name: web image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: web/Dockerfile
          platforms: linux/arm64
          push: true
          tags: ghcr.io/het101/clinic-web:${{ steps.v.outputs.sha }}
```

- [ ] **Step 2: Write `README.md`**

````markdown
# hetops-clinic

A small multi-tenant clinic booking app, built as the workload for the [HetOps Kubernetes chaos lab](https://github.com/Het101/hetops-k8s-lab). Every name and booking is fake.

## Shape

| Piece | Command | Notes |
| --- | --- | --- |
| api | `node api/src/server.js` | Fastify on :8080. `/healthz`, `/readyz` (admin DB only), `/api/*` |
| worker | same, with `RUN_JOBS=true` | The only place scheduled jobs run |
| migrate | `node api/src/migrate.js` | Admin DB, then each tenant DB. `MIGRATE_FAIL=true` fails on purpose |
| report | `node api/src/jobs.js report` | Nightly CronJob |
| web | `web/` on unprivileged nginx :8080 | Shows which pod served each request |

One admin database lists the tenants; each clinic has its own database.

## Configuration

`DB_HOST`, `DB_USER`, `DB_PASSWORD` (required); `DB_PORT`, `DB_ADMIN_NAME`, `PORT`, `INTERNAL_TOKEN`, `RUN_JOBS`, `READINESS_ALWAYS_FAIL`, `APP_VERSION`.

`/internal/crash`, `/internal/leak` and `/internal/hang` exist for chaos experiments. They need the `X-Chaos-Token` header, and are disabled when `INTERNAL_TOKEN` is empty.

## Develop

```bash
npm ci
npm test                       # unit tests
docker run -d --name clinic-pg -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17
DB_HOST=localhost DB_USER=postgres DB_PASSWORD=test npm test   # plus the integration test
```

Images (ARM64) are published by CI on every push to `main`: `ghcr.io/het101/clinic-api:<sha>`, `ghcr.io/het101/clinic-api:bad`, `ghcr.io/het101/clinic-web:<sha>`.
````

- [ ] **Step 3: Run the whole suite one last time**

Run: `npm test`
Expected: everything passes. The integration test shows as skipped unless `DB_HOST` is set.

- [ ] **Step 4: Commit, push, open the PR**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "ci: test against Postgres, publish ARM64 images to GHCR"
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin feat/clinic-app
GH_TOKEN=$(gh auth token --user Het101) gh pr create --repo Het101/hetops-clinic --base main --head feat/clinic-app \
  --title "feat: clinic demo app (api, worker, migrate, report, web)" \
  --body "The workload for the HetOps chaos lab, per docs/superpowers/specs/2026-10-08-chaos-lab-design.md in hetops-k8s-lab. Unit tests plus an integration test against Postgres in CI; ARM64 images to GHCR on merge."
```

Expected: the PR's `test` job passes, including the integration test against the Postgres service. If it fails, fix the cause on the branch and push again.

- [ ] **Step 5: Merge, then check the images**

After `test` is green: `GH_TOKEN=$(gh auth token --user Het101) gh pr merge --repo Het101/hetops-clinic --squash --delete-branch`.
Expected: the `images` job runs on `main` and pushes all three tags.

- [ ] **Step 6: Make the packages public (the owner does this in the browser)**

New GHCR packages start private, and the cluster pulls without credentials. On github.com → Het101 → Packages → `clinic-api` → Package settings → Change visibility → Public. Repeat for `clinic-web`.

Verify from the server:

```bash
sudo crictl pull ghcr.io/het101/clinic-api:bad
```

Expected: the pull succeeds with no authentication.
