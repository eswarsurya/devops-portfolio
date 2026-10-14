#!/usr/bin/env bash
# OpenSearch cluster administration drills against the 3-node cluster in docker-compose.yml.
# Each drill does the task, then checks the result.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

OS=${OS_URL:-http://localhost:9201}
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "::error title=opensearch drills::$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 3; done; return 1; }
section() { echo; echo "== $1"; }
api() { local method=$1 path=$2; shift 2; curl -fsS -X "$method" "$OS$path" -H 'Content-Type: application/json' "$@"; }
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
health() { api GET /_cluster/health | jq_ "d['status']"; }
is_green() { [ "$(health 2>/dev/null)" = green ]; }
doc_count() { api POST /logs-*/_refresh >/dev/null 2>&1; api GET '/logs-*/_count' | jq_ "d['count']"; }

for _ in $(seq 1 60); do api GET /_cluster/health >/dev/null 2>&1 && break; sleep 5; done

# ---------------------------------------------------------------------------
section "1. Cluster formation"
check "cluster is green" retry 40 is_green
nodes=$(api GET /_cluster/health | jq_ "d['number_of_nodes']")
check "three nodes joined ($nodes)" test "$nodes" = 3
manager=$(api GET '/_cat/cluster_manager?h=node' | tr -d '[:space:]')
check "a cluster manager is elected ($manager)" test -n "$manager"

# ---------------------------------------------------------------------------
section "2. Index lifecycle (ISM) and templates"
check "ISM policy logs-retention created" api PUT /_plugins/_ism/policies/logs-retention --data-binary @ism-policy.json -o /dev/null
check "index template for logs-* created" api PUT /_index_template/logs --data-binary @index-template.json -o /dev/null
bulk=$(python3 - <<'EOF'
import json, random, datetime
now = datetime.datetime.now(datetime.timezone.utc)
for i in range(500):
    print(json.dumps({"index": {"_index": "logs-checkout"}}))
    print(json.dumps({"@timestamp": (now - datetime.timedelta(seconds=i)).isoformat(),
                      "service": random.choice(["checkout", "payments", "search"]),
                      "level": random.choice(["INFO"] * 8 + ["WARN", "ERROR"]),
                      "message": f"request {i} handled", "latency_ms": random.randint(5, 900)}))
EOF
)
api POST /_bulk --data-binary "$bulk"$'\n' -o /dev/null
count=$(doc_count)
check "500 log events indexed ($count)" test "$count" = 500
shards=$(api GET /logs-checkout/_settings | jq_ "d['logs-checkout']['settings']['index']['number_of_shards']")
check "template applied: 3 primary shards" test "$shards" = 3
attached() { api GET /_plugins/_ism/explain/logs-checkout | jq_ "d['logs-checkout'].get('index.plugins.index_state_management.policy_id') or d['logs-checkout'].get('policy_id')" | grep -q logs-retention; }
check "ISM policy attached to the new index automatically" retry 20 attached
errors=$(api GET '/logs-*/_count?q=level:ERROR' | jq_ "d['count']")
echo "      ERROR events in the sample: $errors"

# ---------------------------------------------------------------------------
section "3. Snapshot and restore"
check "shared filesystem snapshot repository registered" \
  api PUT /_snapshot/nightly -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}' -o /dev/null
check "snapshot of logs-* taken" \
  api PUT '/_snapshot/nightly/snap-1?wait_for_completion=true' -d '{"indices":"logs-*","include_global_state":false}' -o /dev/null
api DELETE /logs-checkout -o /dev/null
gone() { [ "$(curl -s -o /dev/null -w '%{http_code}' "$OS/logs-checkout")" = 404 ]; }
check "index deleted (simulated accident)" gone
check "index restored from the snapshot" \
  api POST '/_snapshot/nightly/snap-1/_restore?wait_for_completion=true' -d '{"indices":"logs-*"}' -o /dev/null
restored() { [ "$(doc_count)" = 500 ]; }
check "all 500 events are back" retry 20 restored
check "cluster green after restore" retry 40 is_green

# ---------------------------------------------------------------------------
section "4. Decommission a node safely (shard allocation filtering)"
api PUT /_cluster/settings -d '{"persistent":{"cluster.routing.allocation.exclude._name":"os3"}}' -o /dev/null
os3_empty() { ! api GET '/_cat/shards?h=node' | grep -qw os3; }
check "all shards moved off os3" retry 60 os3_empty
check "cluster stayed green while draining os3" is_green
api PUT /_cluster/settings -d '{"persistent":{"cluster.routing.allocation.exclude._name":null}}' -o /dev/null
os3_used() { api GET '/_cat/shards?h=node' | grep -qw os3; }
check "os3 receives shards again after the exclusion is cleared" retry 60 os3_used

# ---------------------------------------------------------------------------
section "5. Unplanned node failure"
docker compose stop os3 >/dev/null 2>&1
survived() { [ "$(doc_count 2>/dev/null)" = 500 ]; }
check "with os3 down, every event is still searchable (replicas promoted)" retry 20 survived
not_red() { [ "$(health 2>/dev/null)" != red ]; }
check "cluster is not red with one node down ($(health))" not_red
docker compose start os3 >/dev/null 2>&1
check "cluster back to green after os3 rejoins" retry 60 is_green

# ---------------------------------------------------------------------------
section "6. Rolling restart of a node"
api PUT /_cluster/settings -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}' -o /dev/null
api POST /_flush -o /dev/null
docker compose restart os2 >/dev/null 2>&1
os2_back() { api GET '/_cat/nodes?h=name' | grep -qw os2; }
check "os2 rejoined after restart" retry 60 os2_back
api PUT /_cluster/settings -d '{"persistent":{"cluster.routing.allocation.enable":null}}' -o /dev/null
check "replica allocation re-enabled and cluster green" retry 60 is_green

# ---------------------------------------------------------------------------
section "7. Dashboards"
dash_ok() { curl -fsS http://localhost:5602/api/status | jq_ "d['status']['overall']['state']" | grep -q green; }
check "OpenSearch Dashboards is up" retry 40 dash_ok

echo
if [ "$failures" -eq 0 ]; then echo "All drills passed."; else echo "$failures drill check(s) failed."; fi
exit "$failures"
