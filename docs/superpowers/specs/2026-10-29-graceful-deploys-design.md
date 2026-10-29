# Fast, graceful deploys

**Status:** design, 29 Oct 2026. Sub-project 3 of the ops cluster ([design](2026-10-27-ops-cluster-design.md)), redefined: it was "a Coolify build server on hetops-3". The code changes live in four app repos; this spec lives here with the other ops-cluster specs.

## Why the build server was dropped (owner, 29 Oct)

Measured in Coolify's database on the lab (last 30 days, finished deploys):

| App | Deploys | Median | 90th percentile |
| --- | --- | --- | --- |
| hetops-portfolio | 64 | 18 s | 169 s |
| hetops-dns | 33 | 55 s | (outliers) |
| tallybank (prebuilt image) | 30 | 13 s | 18 s |
| radar-cloud | 24 | 71 s | (outliers) |
| restore-drill | 9 | 65 s | 95 s |

The multi-hour "averages" were a few early-October rows Coolify updated hours after they finished; their logs show 16 to 165 s of real work. A typical deploy (radar-cloud, 29 Oct) spent: prepare and clone 11 s, **build 18 s**, health-check start period 20 s, **"Removing old containers" 30 s**.

So building costs the lab about 18 s of CPU per deploy, around 40 CPU-minutes a month. A build server would save that in exchange for root SSH from the lab into hetops-3 (the outside watcher), a registry, Docker on hetops-3 and a new deploy dependency. Not worth it; revisit only if build CPU shows up in the lab's metrics. The build server is not built.

## What wastes the time instead

1. **No app handles `SIGTERM`.** Node running as PID 1 has no default signal handling, so `docker stop` waits its full 30 s and then kills the process, cutting any request in flight. Every deploy pays 30 s, and visitors can see a failed request.
2. **Fixed health-check waits.** radar-cloud and restore-drill wait `--start-period=20s` before the first check; the app is ready in about a second.
3. **hetops-dns** has no health check (Coolify can't tell "started" from "ready") and runs as root.
4. **The portfolio is nginx**, which treats `SIGTERM` as an immediate stop; `SIGQUIT` is its graceful stop.

## Design

### Node apps (hetops-dns, radar-cloud, restore-drill)

- **Graceful shutdown in `server.js`:** on `SIGTERM` and `SIGINT`, stop accepting connections (`server.close()`), close idle keep-alive sockets (`server.closeIdleConnections()`), let in-flight requests finish, then exit 0. A 10 s deadline (`setTimeout(...).unref()`, exit 1) bounds it below Docker's 30 s. Background work (restore-drill's scheduled drills, radar-cloud's timers) is stopped with its timers cleared; a drill in progress is abandoned, as a crash would, and the next run retries.
- **Health checks that answer as soon as the app is ready:** `HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=1s --retries=3` (Docker 25+; the lab runs 29). During start-up Docker checks every second, so a ready app is marked healthy in 1 to 3 s; the start period only bounds how long a slow start may take.
- **hetops-dns:** `USER node` and a `HEALTHCHECK` on its health route (added if it has none: `GET /api/health` returning 200 and the version), like the other two.
- **Builds:** keep the two-stage layout; `npm ci` with a BuildKit cache mount (`RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev`) so repeated builds reuse downloaded packages; package files copied before the source so a code change doesn't reinstall dependencies.

### The portfolio (nginx)

- `STOPSIGNAL SIGQUIT` in its Dockerfile: nginx finishes open responses, then exits.
- Health check `--start-interval=1s` as above.

### Proof in each repo's CI

Each repo's existing `ci.yml` gains one job, **"stops gracefully"**: build the image, run it, wait until Docker reports it `healthy` (proves the health check), make one request to the health route, then time `docker stop -t 30` and assert it took **under 5 s** and the container's exit code is **0**. Without the fix the stop takes the full 30 s and the job fails; this is how the fix is proven, not only described.

## Rollout

One PR per repo, smallest traffic first: restore-drill, radar-cloud, hetops-dns, hetops-portfolio. Each: CI green (including the new job), merge, Coolify deploys it, then compare that deploy's phases in Coolify's log with the baseline above. The PR's own deploy is the first measured one, and the next real deploy confirms it.

## Done when

1. All four apps stop in under 5 s with exit 0 in CI, and in Coolify's log "Removing old containers" takes under 5 s.
2. A typical deploy of each Node app takes about 25 to 35 s end to end (from ~60 to 82 s).
3. hetops-dns runs as a non-root user and has a health check.
4. Each step and measurement is in the journal (via `journal-pending.md`).

## Not in scope

The build server and registry (above). tallybank (built in GitHub Actions; 13 s deploys). hetops-love (no deploys).
