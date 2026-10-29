# Fast, graceful deploys: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every HetOps app deployed by Coolify stops gracefully in under 5 s and reports healthy within seconds, so a deploy takes ~25-35 s instead of 60-82 s and drops no request.

**Architecture:** per app repo: a SIGTERM/SIGINT handler that drains the HTTP server (Node) or `STOPSIGNAL SIGQUIT` (nginx); Docker health checks with `--start-interval=1s`; BuildKit npm cache; a CI job "stops gracefully" that fails without the fix.

**Tech Stack:** Node 22 + Express / node:http, nginx:alpine, Docker 29 (BuildKit, HEALTHCHECK start-interval), GitHub Actions, Coolify v4.0.0-beta.470.

**Spec:** [hetops-k8s-lab/docs/superpowers/specs/2026-10-29-graceful-deploys-design.md](../specs/2026-10-29-graceful-deploys-design.md).

## Global Constraints

- Repos (local checkouts under `C:/Users/HetPatel/Personal/HetOps/`, remotes on GitHub `Het101/<repo>`): restore-drill, radar-cloud, hetops-dns, hetops-portfolio. One PR per repo, in that order. Each merge deploys the live site through Coolify on the lab; merge only with every check green.
- Shutdown deadline 10 s inside the app (below Docker's 30 s); CI asserts `docker stop -t 30` < 5 s and exit code 0.
- `HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=1s --retries=3` with each app's existing health command (wget against its health route); the portfolio keeps its `--timeout=3s`.
- No behaviour change beyond shutdown, health check, build caching, and (hetops-dns) `USER node` + a health route if missing. No dependency added.
- Commits: author `Het Patel <patel.x.het@gmail.com>`, GPG-signed, never `--no-gpg-sign`, no Claude attribution, subject under 72 characters (some repos enforce it with a hook). Push with the Het101 token (`gh auth token --user Het101`).
- Never print secrets (Coolify env values included).
- Every step and measurement goes to `C:\Users\HetPatel\Personal\HetOps\journal-pending.md` (the controller writes it from reports).

## The deploy measurement (used by every task)

On the lab, Coolify's last finished deploy of an app, phase by phase (`APP` = a prefix of the Coolify application name, e.g. `radar-cloud`):

```sql
with q as (select q.logs, q.created_at from application_deployment_queues q join applications a on a.id::text=q.application_id
  where a.name like 'APP%' and q.status='finished' order by q.created_at desc limit 1)
select substr(l->>'timestamp',12,8) t, left(regexp_replace(l->>'output','\s+',' ','g'),110) line
from q, jsonb_array_elements(q.logs::jsonb) l where (l->>'hidden')::boolean is not true;
```

Run with `ssh ubuntu@140.245.13.138 'docker exec -i coolify-db psql -U coolify -d coolify -A -t -F" | "' < query.sql`. Record: build time ("Building docker image started" to "completed"), health wait ("New container started" to "is healthy"), stop ("Removing old containers" to "Rolling update completed"), total.

---

### Task 1: restore-drill

**Files:** `server.js` (shutdown), `Dockerfile` (HEALTHCHECK, npm cache mount, `# syntax=docker/dockerfile:1` first line if absent), `.github/workflows/ci.yml` (new job).

- [ ] **Step 1: The failing CI job first.** Add to `ci.yml`:

```yaml
  stops-gracefully:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<the SHA this workflow already pins, or v4 pinned by SHA>
      - name: Build
        run: docker build -t app:ci .
      - name: Starts healthy, stops in under 5 s with exit 0
        run: |
          docker run -d --name app app:ci
          for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' app)" = healthy ] && break; sleep 1; done
          docker inspect -f '{{.State.Health.Status}}' app | grep -qx healthy
          start=$(date +%s%N); docker stop -t 30 app; ms=$(( ($(date +%s%N) - start) / 1000000 ))
          code=$(docker inspect -f '{{.State.ExitCode}}' app); echo "stop took ${ms} ms, exit ${code}"
          [ "$ms" -lt 5000 ] && [ "$code" -eq 0 ]
```

If the app needs environment variables to start (read the README / config loader), pass harmless test values with `-e`; never real secrets. Push on a branch `fix/graceful-stop`; expected: the job fails ("stop took ~10000-30000 ms" or exit 137/143).

- [ ] **Step 2: Shutdown in `server.js`.** Keep the server object returned by `createServer(agent).listen(...)` and add:

```js
// Graceful stop (deploys): stop accepting, close idle keep-alive sockets, let in-flight requests finish, exit 0.
// Bounded at 10 s, below Docker's 30 s, so a stuck request can't hold a deploy.
function shutdown(signal) {
  console.log(`[drill] ${signal}: shutting down`);
  setTimeout(() => process.exit(1), 10_000).unref();
  server.close(() => process.exit(0));
  server.closeIdleConnections();
}
process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
```

Also clear restore-drill's drill scheduler timer (the `setInterval`/`setTimeout` that runs drills every N hours) inside `shutdown` so it cannot keep the process alive; name it from the code, don't guess.

- [ ] **Step 3: Dockerfile.** First line `# syntax=docker/dockerfile:1`; `RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev` in the deps stage (package files copied before the rest, as now); HEALTHCHECK per Global Constraints. If the deps stage runs as a non-root user, the cache target is that user's npm cache dir instead.

- [ ] **Step 4: CI green, then the existing tests.** Push; the new job passes ("stop took <5000 ms, exit 0"), all other jobs still pass. Locally (if Docker is available) the same script passes.

- [ ] **Step 5: PR, merge, measure.** PR `fix: graceful stop and fast health checks`; merge (squash) when green; Coolify deploys. Run the measurement for `restore-drill`: stop < 5 s, health wait < 5 s. Compare with the baseline (median 65 s, start period 20 s, stop 30 s). Check the site's health route answers after deploy.

### Task 2: radar-cloud

Same steps as Task 1 in repo radar-cloud (`server.js` uses `app.listen(port, ...)` at about line 290: keep the returned server; clear any `setInterval` timers the app starts for scans/backups in `shutdown`, named from the code). Baseline: median 71 s; 29 Oct deploy: build 18 s, start period 20 s, stop 30 s, total ~82 s.

### Task 3: hetops-dns

Same steps as Task 1 in repo hetops-dns (`app.listen(PORT, ...)` at about line 4419), plus:
- **A health route** if none exists: `GET /api/health` → `200 {"ok":true,"version":<package.json version>}` with no other work; if one exists under another path, use it.
- **`USER node`** in the final stage, after files are copied (`COPY --chown=node:node`), and confirm the app writes nothing outside writable paths at runtime (read the code for file writes; if it writes, give it a writable directory owned by node).
- HEALTHCHECK per Global Constraints against that route (busybox `wget -qO-`).
Baseline: median 55 s, no health check.

### Task 4: hetops-portfolio

Repo hetops-portfolio (nginx:alpine, built by Coolify from `docker-compose.yml`):
- `STOPSIGNAL SIGQUIT` in the Dockerfile; HEALTHCHECK keeps its command, gains `--start-interval=1s` (and `--start-period=30s`, `--timeout=3s`).
- The CI job as in Task 1, with the threshold "< 5 s and exit 0".
- Check `docker-compose.yml` does not override `stop_signal`/`healthcheck` (if it does, align it there).
Baseline: median 18 s.

### Task 5: Close out

- [ ] The spec's "Done when", each with the measured deploy phases before and after, into `journal-pending.md` (Part 13 entry "Sub-project 3: fast, graceful deploys"), and the Start here progress item.
- [ ] Memory `oci-hetops-3.md`: sub-project 3 redefined and done.
- [ ] hetops.dev lab page: not needed (no visible change).
