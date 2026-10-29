#!/bin/sh
# Applies the JSON in this folder to Elasticsearch. Run by the es-setup Job after every sync.
set -eu
ES=https://ops-logs-es-http.logging.svc:9200
c() { r=0; curl -sS --fail-with-body --cacert /certs/ca.crt -u "elastic:$ELASTIC_PASSWORD" -H 'content-type: application/json' "$@" || r=$?; echo; return "$r"; }
until c "$ES/_cluster/health?wait_for_status=yellow&timeout=30s" >/dev/null; do sleep 5; done
c -X PUT "$ES/_ilm/policy/logs-lab-7d" --data-binary @/setup/ilm-logs-lab-7d.json
c -X PUT "$ES/_index_template/logs-lab" --data-binary @/setup/template-logs-lab.json
# A template change only reaches new backing indices: roll the security stream over once, unless it does not exist yet (the
# first index will come from the template) or its write index (last in the list) already maps the audit object as flattened
# with the template's depth_limit. Idempotent: after the rollover the new write index matches.
DEPTH=$(grep -o '"depth_limit": *[0-9]*' /setup/template-logs-lab.json | head -1 | grep -o '[0-9]*$' || true)
: "${DEPTH:?no depth_limit in template-logs-lab.json}"
CODE=$(c -o /dev/null -w '%{http_code}' "$ES/_data_stream/logs-lab-security" 2>/dev/null || true)
case $CODE in
  404) echo "logs-lab-security does not exist yet: no rollover" ;;
  200)
    W=$(c "$ES/_data_stream/logs-lab-security?filter_path=data_streams.indices.index_name" | grep -o '"index_name": *"[^"]*"' | tail -1 | cut -d'"' -f4)
    : "${W:?no write index in the logs-lab-security response}"
    M=$(c "$ES/$W/_mapping/field/k8s_audit.requestObject?include_defaults=true")
    if echo "$M" | grep -q '"type": *"flattened"' && echo "$M" | grep -q "\"depth_limit\": *$DEPTH[,}]"; then
      echo "$W already maps k8s_audit.requestObject as flattened, depth_limit $DEPTH: no rollover"
    else
      c -X POST "$ES/logs-lab-security/_rollover"
    fi ;;
  *) echo "GET _data_stream/logs-lab-security returned '$CODE'" >&2; exit 1 ;;
esac
c -X PUT "$ES/_snapshot/local" --data-binary @/setup/repo-local.json
c -X POST "$ES/_snapshot/local/_verify"
c -X PUT "$ES/_slm/policy/nightly-all" --data-binary @/setup/slm-nightly-all.json
for f in /setup/repo-r2.json; do [ -f "$f" ] || continue
  c -X PUT "$ES/_snapshot/r2" --data-binary @"$f"; c -X POST "$ES/_snapshot/r2/_verify"
  c -X PUT "$ES/_slm/policy/nightly-security" --data-binary @/setup/slm-nightly-security.json
done
