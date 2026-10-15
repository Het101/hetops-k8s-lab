// CrowdSec -> Cloudflare WAF rule bouncer (SIEM track, T4). Runs once per CronJob tick:
// read the active ban decisions from CrowdSec's local API and write them into the expression of the WAF custom
// rule "CrowdSec bans (lab)" on the hetops.dev zone. Writes only when the IP set changed; with no bans the rule
// is disabled. (A first version used a Cloudflare IP List; list writes got locked by Cloudflare's rate limiter,
// even in the dashboard, so the IPs now live in the rule itself, behind the normal Rulesets API limits.)
const { LAPI_URL, LAPI_KEY, CF_TOKEN, CF_ZONE, ALLOW = '', CF_API = 'https://api.cloudflare.com/client/v4' } = process.env;
const RULE = 'CrowdSec bans (lab)';           // the rule's description in the dashboard
const HOST = 'lab.hetops.dev';
const MAX_IPS = 200;                          // the free plan caps an expression at 4096 characters

// Second safety net after CrowdSec's own whitelist: never block our own infrastructure.
const allow = new Set(ALLOW.split(',').map((s) => s.trim()).filter(Boolean));

const lapi = await fetch(`${LAPI_URL}/v1/decisions?type=ban`, { headers: { 'X-Api-Key': LAPI_KEY }, signal: AbortSignal.timeout(10_000) });
if (!lapi.ok) throw new Error(`CrowdSec LAPI answered ${lapi.status}`);
const decisions = (await lapi.json()) ?? [];   // the API returns null, not [], when there are none

let ips = [...new Set(decisions
  .filter((d) => ['ip', 'range'].includes(String(d.scope).toLowerCase()))
  .map((d) => d.value))]
  .filter((ip) => !allow.has(ip))
  .sort();
if (ips.length > MAX_IPS) {
  console.log(JSON.stringify({ warning: `more than ${MAX_IPS} bans; keeping the first ${MAX_IPS}`, total: ips.length }));
  ips = ips.slice(0, MAX_IPS);
}

const cf = async (path, init = {}) => {
  const res = await fetch(`${CF_API}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${CF_TOKEN}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(15_000),
  });
  const body = await res.json();
  if (!body.success) throw new Error(`Cloudflare ${init.method ?? 'GET'} ${path}: ${res.status} ${JSON.stringify(body.errors)}`);
  return body.result;
};

const entry = await cf(`/zones/${CF_ZONE}/rulesets/phases/http_request_firewall_custom/entrypoint`);
const rule = entry.rules?.find((r) => r.description === RULE);
if (!rule) throw new Error(`WAF custom rule "${RULE}" not found on the zone`);

const wantEnabled = ips.length > 0;
const wantExpr = wantEnabled
  ? `(http.host eq "${HOST}" and ip.src in {${ips.join(' ')}})`
  : `(http.host eq "${HOST}" and ip.src in {192.0.2.1})`;   // TEST-NET placeholder: never a real visitor

if (rule.expression === wantExpr && rule.enabled === wantEnabled) {
  console.log(JSON.stringify({ unchanged: ips.length, ips }));
  process.exit(0);
}

await cf(`/zones/${CF_ZONE}/rulesets/${entry.id}/rules/${rule.id}`, {
  method: 'PATCH',
  body: JSON.stringify({ description: rule.description, action: rule.action, expression: wantExpr, enabled: wantEnabled }),
});
console.log(JSON.stringify({ synced: ips.length, enabled: wantEnabled, ips }));
