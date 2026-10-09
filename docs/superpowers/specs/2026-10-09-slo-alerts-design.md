# Monitoring, sub-project 2: SLOs and alerts (design)

## SLI and SLO

**Counter:** `chaos_visits_total{result="good|bad"}`, emitted by chaos-api's prober at 5 visits/s.

- A visit is **good** only if the page and `/api` both answered 2xx within 1 s (the prober's timeout).
- So errors, refused connections and slowness all count as bad.

**SLO:** 99% of visits good, over a rolling 7 days. That gives:

- an error budget of 1%, about 100 minutes of fully failed visits per week;
- a nightly self-test that costs roughly 3–4 minutes of it.

**Ingress traffic (RED per route, with 5xx and 499 counted as bad):** diagnostic only. It never feeds alerts.

## Rules

PrometheusRule `lab-slo` in the `monitoring` namespace, under `platform/monitoring/extras/`.

**Recording rules:**

- `lab:visits_bad:ratio_rate{5m,30m,1h,6h,1d,3d,7d}`, computed as `(bad or vector(0)) / total`.
- `lab:slo_budget_remaining = 1 - ratio_rate7d / 0.01`.
- `lab:slo_burn_rate{window}`, which is the ratio divided by 0.01.

**Alerts** (label `team: lab`):

| Alert | Severity | Fires when |
|---|---|---|
| SLOBurnFast | critical | burn > 14.4 over 1h **and** over 5m |
| SLOBurnSlow | warning | burn > 6 over 6h **and** over 30m |
| SLOBudgetExhausted | warning | budget remaining < 0, for 10m |
| DatabaseUnreachable | critical | `(max(pg_up{job="postgres"}) or vector(0)) == 0`, for 3m |
| LabNotHealing | warning | `increase(chaos_experiments_total{status=~"timeout\|error"}[1h]) > 0` |
| SLIMissing | critical | `absent(chaos_visits_total)`, for 10m |

**Normal chaos does not page.** The burn rates over 1 h are:

- about 0.8× for one experiment;
- about 1.5× for a namespace nuke;
- about 6.7× for the full nightly self-test (1.1× over 6 h).

Real abuse (about 20 experiments in an hour, roughly 17×) does page.

## Alertmanager routing

- **The `team: lab` alerts go to Telegram,** with resolve messages: `group_wait` 30s, `group_interval` 5m, `repeat_interval` 4h.
- **The bot token** is a sealed Secret `alertmanager-telegram`, mounted through `alertmanagerSpec.secrets` and referenced with `bot_token_file`.
- **The chat id** goes in the values file.
- **Everything else goes to a `null` receiver.** The chart's built-in alerts fire constantly during chaos, so they stay visible but never notify.
- **Optional:** the always-firing Watchdog is sent every 2 min to a HetOps Status push monitor as a dead man's switch. Whether the push URL accepts POST is verified in the lab.

## Dashboard

"Clinic lab — SLO" (uid `lab-slo`):

- the SLI over 5m and 1h;
- a budget-remaining gauge;
- the current burn rates;
- the budget over the last 7 days;
- alert states (`ALERTS{team="lab"}`);
- the failing route right now, from ingress 5xx and 499.

## Labs

| Lab | Content |
|---|---|
| S1 | The counter and the SLI rules |
| S2 | Budget and burn rules, plus the dashboard |
| S3 | The Telegram bot, Alertmanager routing and a test alert |
| S4 | The alert rules, a real DatabaseUnreachable on the phone, and optionally the Watchdog |
