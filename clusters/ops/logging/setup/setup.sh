#!/bin/sh
# Applies the JSON in this folder to Elasticsearch. Run by the es-setup Job after every sync.
set -eu
ES=https://ops-logs-es-http.logging.svc:9200
c() { curl -sS --fail-with-body --cacert /certs/ca.crt -u "elastic:$ELASTIC_PASSWORD" -H 'content-type: application/json' "$@"; echo; }
until c "$ES/_cluster/health?wait_for_status=yellow&timeout=30s" >/dev/null; do sleep 5; done
c -X PUT "$ES/_ilm/policy/logs-lab-7d" --data-binary @/setup/ilm-logs-lab-7d.json
c -X PUT "$ES/_index_template/logs-lab" --data-binary @/setup/template-logs-lab.json
# A template change only reaches new backing indices: roll the security stream over once, if no index of it carries the template's
# audit-object mapping yet (type flattened + the template's depth_limit). Idempotent: after the rollover the new write index matches.
DEPTH=$(grep -o '"depth_limit": *[0-9]*' /setup/template-logs-lab.json | head -1 | grep -o '[0-9]*$')
if c "$ES/_data_stream/logs-lab-security" >/dev/null 2>&1 && ! c "$ES/logs-lab-security/_mapping/field/k8s_audit.requestObject" | grep -q "\"type\":\"flattened\",\"depth_limit\":$DEPTH"; then
  c -X POST "$ES/logs-lab-security/_rollover"
fi
c -X PUT "$ES/_snapshot/local" --data-binary @/setup/repo-local.json
c -X POST "$ES/_snapshot/local/_verify"
c -X PUT "$ES/_slm/policy/nightly-all" --data-binary @/setup/slm-nightly-all.json
for f in /setup/repo-r2.json; do [ -f "$f" ] || continue
  c -X PUT "$ES/_snapshot/r2" --data-binary @"$f"; c -X POST "$ES/_snapshot/r2/_verify"
  c -X PUT "$ES/_slm/policy/nightly-security" --data-binary @/setup/slm-nightly-security.json
done
