// CrowdSec -> Cloudflare IP List bouncer (SIEM track, T4). Runs once per CronJob tick:
// read the active ban decisions from CrowdSec's local API, then REPLACE the Cloudflare list with them.
// Replacing (not adding) keeps it idempotent: expired or deleted bans disappear on the next tick.
// A WAF custom rule on lab.hetops.dev blocks any IP in the list, at Cloudflare's edge.
const { LAPI_URL, LAPI_KEY, CF_TOKEN, CF_ACCOUNT, CF_LIST, ALLOW = '', CF_API = 'https://api.cloudflare.com/client/v4' } = process.env;

// Second safety net after CrowdSec's own whitelist: never push our own infrastructure.
const allow = new Set(ALLOW.split(',').map((s) => s.trim()).filter(Boolean));

const lapi = await fetch(`${LAPI_URL}/v1/decisions?type=ban`, { headers: { 'X-Api-Key': LAPI_KEY }, signal: AbortSignal.timeout(10_000) });
if (!lapi.ok) throw new Error(`CrowdSec LAPI answered ${lapi.status}`);
const decisions = (await lapi.json()) ?? [];   // the API returns null, not [], when there are none

const ips = [...new Set(decisions
  .filter((d) => ['ip', 'range'].includes(String(d.scope).toLowerCase()))
  .map((d) => d.value))]
  .filter((ip) => !allow.has(ip))
  .sort();

const cf = await fetch(`${CF_API}/accounts/${CF_ACCOUNT}/rules/lists/${CF_LIST}/items`, {
  method: 'PUT',                                // "replace all items"
  headers: { authorization: `Bearer ${CF_TOKEN}`, 'content-type': 'application/json' },
  body: JSON.stringify(ips.map((ip) => ({ ip, comment: 'crowdsec ban' }))),
  signal: AbortSignal.timeout(15_000),
});
const body = await cf.json();
if (!body.success) throw new Error(`Cloudflare refused the update: ${JSON.stringify(body.errors)}`);
console.log(JSON.stringify({ synced: ips.length, ips, operation: body.result?.operation_id }));
