// CrowdSec -> Cloudflare WAF rule bouncer (SIEM track, T4). Runs once per CronJob tick:
// read the active ban decisions from CrowdSec's local API and write them into the expression of the WAF custom
// rule "CrowdSec bans (lab)" on the hetops.dev zone. Writes only when the IP set changed; with no bans the rule
// is disabled. (A first version used a Cloudflare IP List; list writes got locked by Cloudflare's rate limiter,
// even in the dashboard, so the IPs now live in the rule itself, behind the normal Rulesets API limits.)
import { request } from 'node:https';
import { readFileSync } from 'node:fs';

const { LAPI_URL, LAPI_TLS = '/etc/ssl/crowdsec-bouncer', CF_TOKEN, CF_ZONE, ALLOW = '', CF_API = 'https://api.cloudflare.com/client/v4' } = process.env;
const RULE = 'CrowdSec bans (lab)';           // the rule's description in the dashboard
const HOST = 'lab.hetops.dev';
const MAX_IPS = 200;                          // the free plan caps an expression at 4096 characters

// Second safety net after CrowdSec's own whitelist: never block our own infrastructure.
const allow = new Set(ALLOW.split(',').map((s) => s.trim()).filter(Boolean));

// mTLS (25 Oct): the bouncer signs in with the client certificate cert-manager issues (OU bouncer-ou), not an API key.
// The LAPI makes a "CrowdSec Bouncer@<pod IP>" entry from the certificate on each run, so the stale ones can be
// auto-deleted safely (bouncers_autodelete: cert). With a key, every run left a "cloudflare-list@<IP>" entry that
// could not be: the key lives only as long as one of those entries does. fetch cannot present a client certificate
// without the undici package, so this one call uses node:https.
const tls = {
  cert: readFileSync(`${LAPI_TLS}/tls.crt`),
  key: readFileSync(`${LAPI_TLS}/tls.key`),
  ca: readFileSync(`${LAPI_TLS}/ca.crt`),
};
const getJSON = (url) => new Promise((resolve, reject) => {
  const req = request(url, { ...tls, timeout: 10_000 }, (res) => {
    let body = '';
    res.setEncoding('utf8').on('data', (c) => { body += c; }).on('end', () => {
      if (res.statusCode !== 200) reject(new Error(`CrowdSec LAPI answered ${res.statusCode}`));
      else resolve(JSON.parse(body));
    });
  });
  req.on('timeout', () => req.destroy(new Error('CrowdSec LAPI timed out'))).on('error', reject).end();
});

const decisions = (await getJSON(`${LAPI_URL}/v1/decisions?type=ban`)) ?? [];   // null, not [], when there are none

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
