#!/bin/sh
# Loads Kibana's setup from git after every sync: the data view, then the detection rules (overwrite: git wins).
set -eu
KB=http://ops-kibana-kb-http.logging.svc:5601
c() { curl -sS --fail-with-body -u "elastic:$ELASTIC_PASSWORD" -H 'kbn-xsrf: 1' "$@"; echo; }
until c "$KB/api/status" | grep -q '"level":"available"'; do sleep 10; done
c -X POST "$KB/api/data_views/data_view" -H 'content-type: application/json' --data-binary @/objects/data-view-lab-logs.json
c -X POST "$KB/api/detection_engine/rules/_import?overwrite=true" -F file=@/objects/rules.ndjson | tee /tmp/r
grep -q '"success":true' /tmp/r
