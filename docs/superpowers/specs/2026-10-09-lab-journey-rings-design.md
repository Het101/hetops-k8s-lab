# Lab console: the visitor's journey in the rings (design)

**Goal:** the hetops.dev/lab scene shows the full path of a real visit, not just api requests. A visit is three real hops:

1. the page, from a **web** pod;
2. `/api/whoami`, from an **api** pod;
3. that pod's query to **postgres**.

The scene keeps the site's circular "watching eye" form.

## The honest flow

`web` never calls `api`. The visitor's browser does both: it loads the page from web, then calls `/api` through the ingress. The api pod then reads postgres. So a visit is drawn as two trips out of the ingress, with the second continuing to postgres:

```text
ingress -> web pod -> (back to) ingress -> api pod -> postgres
```

- The api pod only reads the database when the request succeeds. `whoami` counts tenants, so a 2xx means the DB answered.
- worker -> postgres runs in the background. It is drawn as a static link with no dots, because we do not measure it.

## Data (one entry per visit in the `probes` SSE batch)

```js
{ at, ok, status, pod, ms,          // as today: the api hop (ok, status, api pod name, ms)
  web: { ok, pod } }                // NEW: the page hop and the web pod that served it
```

- **Backwards compatible:** today's page ignores `web`.
- **Real source** (after a layout is chosen):
  - web pods add `X-Pod: $hostname` to their responses (an nginx `add_header` in hetops-clinic);
  - chaos-api's prober does the two requests in order per visit, 5 visits a second.
- **Prototype source:** `scripts/lab-mock.mjs` picks a web pod per visit.

## Two layouts to compare (prototype), switched by `?layout=a` or `?layout=c` (default `a`)

### A. Depth rings

- **Pupil = ingress** (as today).
- **Rings from inside out = hop order:**
  - ring 1: **web**;
  - ring 2: **api**;
  - ring 3: **data**, with postgres plus the worker. The worker sits next to postgres because postgres is all it talks to.
- **Each ring is labelled** by tier: "web", "api", "data".
- **A visit:**
  1. pupil -> web pod;
  2. fade back to the pupil;
  3. pupil -> api pod;
  4. api pod -> postgres, outward along a short arc or line.
- **Arrival:** each pod hit gives the small ring "ping" the page already has.

### C. Data at the core

- **The pupil becomes postgres**, the data at the heart.
- **Rings from outside in:**
  - ring 1, outer: **web**;
  - ring 2: **api**;
  - the worker sits on the api ring's inner edge, next to the core.
- **Ingress is a small mark on the rim** at 12 o'clock, where visits enter.
- **A visit:**
  1. rim mark -> web pod;
  2. back to the rim;
  3. rim -> api pod;
  4. api pod -> the core (postgres).

## Shared rules (both layouts)

- **Same tones:** green Ready, hollow gold starting, red broken.
- **Same "namespace deleted" treatment:** the ring for that tier goes dashed red.
- **The Argo CD arc stays the outermost gold ring.**
- **Failed hops:**
  - a failed web or api hop shows the dot dying 40% of the way;
  - an api hop that failed with 5xx while the api pod answered (DB down) shows the api -> postgres leg in red, dying halfway.
- **Status line** (sample wording): `Last second: 5 visits · page 5/5 (2 web pods) · api 5/5 (3 of 3 api pods) · database 5/5`.
- **Reduced motion:** no dots, status line only (as today).
- **Data handling:** `textContent` only. Pods are keyed by name, aimed at launch, and pinged on arrival (as today).
- **Class names:** no ad-blocker words.
- **Mobile:** both layouts must work at 375 px.

## Out of scope

- Probing the worker.
- Per-tenant data.
- Changing the timer, buttons, story or incidents.
