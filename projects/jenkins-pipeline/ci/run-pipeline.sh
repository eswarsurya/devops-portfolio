#!/usr/bin/env bash
# Trigger the incident-api job with parameters, wait for it, save its console log.
# Usage: run-pipeline.sh AUTO_APPROVE=true [SIMULATE_BAD_RELEASE=true]
# Exits 0 only if the build result is SUCCESS. The result is also written to ./last-result.
set -euo pipefail

url=${JENKINS_URL:-http://localhost:8080}
job=${JOB:-incident-api}
auth="admin:${JENKINS_ADMIN_PASSWORD:?set JENKINS_ADMIN_PASSWORD}"
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

json() { python3 -c "import sys, json; d = json.load(sys.stdin); print($1)"; }

crumb=$(curl -fsS -u "$auth" -c "$jar" "$url/crumbIssuer/api/json" |
  json 'd["crumbRequestField"] + ":" + d["crumb"]')

params=()
for kv in "$@"; do params+=(--data-urlencode "$kv"); done

queue=$(curl -fsS -u "$auth" -b "$jar" -H "$crumb" -X POST "${params[@]}" \
  -D - -o /dev/null "$url/job/$job/buildWithParameters" |
  awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')
[[ -n "$queue" ]] || { echo "Jenkins did not queue the build"; exit 2; }

number=""
for _ in $(seq 1 90); do
  number=$(curl -fsS -u "$auth" "${queue}api/json" |
    json 'd["executable"]["number"] if d.get("executable") else ""')
  [[ -n "$number" ]] && break
  sleep 2
done
[[ -n "$number" ]] || { echo "Build never left the queue"; exit 2; }
echo "Build #${number} started with: $*"

result=""
for _ in $(seq 1 240); do
  result=$(curl -fsS -u "$auth" "$url/job/$job/$number/api/json" | json 'd["result"] or ""')
  [[ -n "$result" ]] && break
  sleep 5
done

curl -fsS -u "$auth" "$url/job/$job/$number/consoleText" >"build-${number}.log" || true
echo "${result:-TIMEOUT}" >last-result
echo "Build #${number} finished: ${result:-TIMEOUT} (log: build-${number}.log)"
[[ "$result" == "SUCCESS" ]]
