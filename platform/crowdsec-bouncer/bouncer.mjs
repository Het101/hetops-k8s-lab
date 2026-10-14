// CrowdSec -> Cloudflare IP List bouncer (SIEM track, T4). Runs once per CronJob tick:
// read the active ban decisions from CrowdSec's local API, compare with the Cloudflare list, and only when they
// differ REPLACE the list. Replacing (not adding) keeps it idempotent: expired bans disappear on the next change.
// Writing only on a difference matters: list replacements are rate-limited bulk operations (T4: writing every
// minute regardless got error 10040).
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

const listUrl = `${CF_API}/accounts/${CF_ACCOUNT}/rules/lists/${CF_LIST}/items`;
const auth = { authorization: `Bearer ${CF_TOKEN}` };

const current = await (await fetch(`${listUrl}?per_page=500`, { headers: auth, signal: AbortSignal.timeout(15_000) })).json();
if (!current.success) throw new Error(`Cloudflare list read failed: ${JSON.stringify(current.errors)}`);
const have = current.result.map((i) => i.ip).sort();
if (JSON.stringify(have) === JSON.stringify(ips)) {
  console.log(JSON.stringify({ unchanged: ips.length, ips }));
  process.exit(0);
}

const cf = await fetch(listUrl, {
  method: 'PUT',                                // "replace all items"
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify(ips.map((ip) => ({ ip, comment: 'crowdsec ban' }))),
  signal: AbortSignal.timeout(15_000),
});
const body = await cf.json();
if (body.errors?.some((e) => e.code === 10040)) {     // rate limited: not a failure, the next tick retries
  console.log(JSON.stringify({ ratelimited: true, wanted: ips }));
  process.exit(0);
}
if (!body.success) throw new Error(`Cloudflare refused the update: ${JSON.stringify(body.errors)}`);
console.log(JSON.stringify({ synced: ips.length, from: have.length, ips, operation: body.result?.operation_id }));
