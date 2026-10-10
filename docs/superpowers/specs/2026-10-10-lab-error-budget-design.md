# Monitoring, sub-project 3: the error budget on hetops.dev/lab (design)

**Goal:** visitors see that their click cost the lab something. The page shows the SLO's error budget live, each experiment's cost, and an enforced error budget policy: when the budget is spent, chaos freezes.

**Decisions (owner, 2026-10-10):**

- Purpose: "my click cost them something" (budget and burn rate), not a trophy case or a mini-Grafana.
- Budget spent: **enforce** the policy (freeze), not just show it.
- Nightly self-test: **counted** in the SLI, and it **runs even when frozen** (it is the lab's release check).
- Data path: **chaos-api reads Prometheus**. The SLO is defined once, in the recording rules of sub-project 2.

## chaos-api

### `src/slo.js`: `SloReader`

- **Polling:** every 30 s it runs four fixed instant queries against `PROM_URL` + `/api/v1/query`, using Node's fetch:

  | Field | Query |
  |---|---|
  | `budget` | `lab:slo_budget_remaining` |
  | `sli7d` | `1 - lab:visits_bad:ratio_rate7d` |
  | `burn5m` | `lab:slo_burn_rate{window="5m"}` |
  | `burn1h` | `lab:slo_burn_rate{window="1h"}` |

- **`read()` returns** `{ budget, sli7d, burn5m, burn1h, at }`. It returns `null` if the last complete good read is more than 2 minutes old, or if none has happened yet.
- **Queries are constants.** No request data ever reaches Prometheus.
- **`PROM_URL`:** `http://kps-kube-prometheus-stack-prometheus.monitoring:9090`.

### The freeze (error budget policy), in the Guard

- **Thresholds** are read from `chaos-config`: `FREEZE_AT` (default `0`) and `REOPEN_AT` (default `0.05`).
- **Freeze** when `budget <= FREEZE_AT`. **Reopen** only when `budget >= REOPEN_AT`. The gap between the two prevents flapping.
- **A frozen POST** `/chaos/actions/:id` returns **423** `{ "error": "budget-spent" }`.
- **The bypass token ignores the freeze**, for the self-test and the owner.
- **Fail-open:** when `read()` is `null`, the lab is not frozen. The `SLIMissing` alert covers monitoring outages.
- **The freeze state is in memory.** After a restart it is recomputed from the next read.

### Cost per experiment

- The runner counts the prober's bad visits between the experiment's start and its finish.
- `cost = badVisits / 30240`, where 30,240 = 5 visits/s × 604,800 s × 1%. It is stored on the experiment and incident record as a fraction, e.g. `0.0012` for 0.12%.

### Exposure

- **`/chaos/status`** gains `slo: { budget, sli7d, burn5m, burn1h, frozen }`, or `slo: null`.
- **The SSE stream** sends an `slo` event every 30 s, with the same object.
- **A new gauge**, `chaos_frozen`, is 0 or 1.

## hetops-k8s-lab

- **`apps/chaos`:**
  - the env var `PROM_URL`;
  - `FREEZE_AT` and `REOPEN_AT` in `chaos-config`;
  - an image tag bump.
- **NetworkPolicy:** chaos-api egress to namespace `monitoring`, TCP 9090. Prometheus has no ingress policy, so nothing more is needed.

## hetops-portfolio (lab page)

**"Error budget" panel**, in the right column under the clock:

- **The meter:** budget left, 0–100%.
  - Amber below 25%.
  - At 0 or below it reads **"Spent"** in red.
  - Label: `71% of this week's error budget left`.
- **Context line:** `99.70% of visits good over 7 days · target 99%`.
- **Burn line:**
  - Normally: `Burning 0.3× budget pace`.
  - With burn5m at 2 or more: `Burning 12.5× right now (1 h: 1.0×)`.
  - A "?" explains that 1× = the whole budget in exactly 7 days.

**Cost:** the story feed and the "Recent experiments" row show `cost 0.12% of the weekly budget`.

**Frozen:**

- The buttons are disabled and Turnstile is hidden.
- Text: "Error budget spent. The lab is frozen until reliability recovers. Reopens as older incidents age out of the 7-day window."

**Unknown** (`slo: null`): `Budget unavailable right now`, and the lab stays open.

**Page rules:** `textContent` only; no ad-blocker class words; works at 375 px; reduced motion = no meter animation; existing colour tokens.

**Mock:** `scripts/lab-mock.mjs` emits `slo` events and supports `?slo=frozen` and `?slo=none`.

## Testing

- **chaos-api, node:test:**
  - `SloReader` parses a response, and returns `null` when stale or on fetch failure;
  - freeze at 0, still frozen at 0.03, reopen at 0.05, open when unknown;
  - bypass ignores the freeze; a frozen POST returns 423;
  - cost maths.
- **Page:** tested by hand against the mock in all three states, at 375 px and with reduced motion.

## Rollout (three PRs)

1. **chaos-api:** fail-open, so it is safe before the network rule exists.
2. **hetops-k8s-lab:** `PROM_URL`, the thresholds, the egress rule and the tag.
3. **hetops-portfolio:** the panel. The owner deploys it in Coolify and checks the built commit.

## Labs

| Lab | Content |
|---|---|
| P1 | Query Prometheus from the chaos pod. Predict the result before and after the egress rule. |
| P2 | Watch the panel during a kill-postgres. Predict the cost. |
| P3 | Real freeze test: raise `FREEZE_AT` and `REOPEN_AT` above the current budget for a few minutes, see 423 and the frozen page, then restore them. |

## Out of scope

- An exact "reopens at" time.
- Latency and restart charts on the public page.
- Grafana public dashboards.
