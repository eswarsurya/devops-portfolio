#!/usr/bin/env bash
# Game day: break the running compose cluster on purpose and check that
# monitoring sees it, the system recovers, and the alert clears.
#
# Needs the compose stack up (kv1-3 and Prometheus). Steps:
#   1. steady background traffic, check nothing is alerting
#   2. kill kv3: the quorum absorbs it; a ticket alert, no page
#   3. write a marker key while kv3 is down
#   4. kill kv2: quorum lost, kv1 returns 503s; the fast burn page must fire
#   5. restart kv2 and kv3: all ready, kv3 catches up on the marker
#   6. wait for the page to clear, then report impact in error-budget terms
#
# Writes a timeline to the job summary (docs/incidents/ uses it).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

LOAD_RATE=${LOAD_RATE:-50}
DETECT_TIMEOUT=${DETECT_TIMEOUT:-300}
RESOLVE_TIMEOUT=${RESOLVE_TIMEOUT:-720}
LOAD_CONTAINER=kv-gameday-load
timeline=$(mktemp)
start=$SECONDS

mark() {
  local t=$((SECONDS - start))
  printf '| +%02d:%02d | %s | %s |\n' $((t / 60)) $((t % 60)) "$1" "$2" | tee -a "$timeline"
}

cleanup() {
  # One annotation with the whole timeline, so it shows on the run page
  # even when a later check fails.
  if [ -s "$timeline" ]; then notice "game day timeline" "$(oneline < "$timeline")"; fi
  docker rm -f "$LOAD_CONTAINER" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Baseline
wait_ready "${NODES[@]}"
wait_http "$PROM_URL/-/ready" 200 60 || fail "prometheus" "Prometheus is not ready"
docker run -d --name "$LOAD_CONTAINER" --network "$NETWORK" \
  -v "$PWD/loadtest:/scripts:ro" -e MODE=soak -e "SOAK_RATE=$LOAD_RATE" -e SOAK_SECONDS=3600 \
  "$K6_IMAGE" run -q /scripts/kv.js > /dev/null
mark "load started" "k6 sends $LOAD_RATE req/s spread over kv1, kv2, kv3 (80% reads, 20% writes)"
sleep 75
for a in KVErrorBudgetBurnFast KVErrorBudgetBurnMedium; do
  [ "$(alert_state "$a")" = inactive ] || fail "baseline" "$a is active before any fault was injected"
done
mark "baseline healthy" "5m error ratio $(prom_value 'slo:kv_errors:ratio_rate5m'); no burn-rate alerts"

# 2. Lose one node: the cluster should absorb it.
docker compose kill kv3 > /dev/null
mark "fault 1: kv3 killed" "SIGKILL, no clean shutdown"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary "written-while-kv3-down" \
  "http://127.0.0.1:$(client_port kv1)/kv/gameday-marker")
[ "$code" = 200 ] || fail "one node down" "PUT with kv3 down returned $code, want 200 (quorum is 2 of 3)"
mark "write with kv3 down" "PUT gameday-marker via kv1 returned 200"
wait_alert KVNodeDown firing 120 || fail "detect node down" "KVNodeDown did not fire within 120s"
mark "KVNodeDown firing" "ticket severity; nobody is paged for one node"
sleep 30
for a in KVErrorBudgetBurnFast KVErrorBudgetBurnMedium; do
  [ "$(alert_state "$a")" = inactive ] || fail "one node down" "$a fired with only one node down"
done
mark "one node down absorbed" "5m error ratio $(prom_value 'slo:kv_errors:ratio_rate5m'); no burn-rate page"

# 3. Lose a second node: no quorum anywhere.
docker compose kill kv2 > /dev/null
fault_at=$SECONDS
mark "fault 2: kv2 killed" "only kv1 left; it cannot reach 2 replicas"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(client_port kv1)/kv/gameday-marker")
[ "$code" = 503 ] || fail "quorum lost" "GET via kv1 without quorum returned $code, want 503"
mark "kv1 refuses without quorum" "GET returned 503, not a possibly stale value"
wait_alert KVErrorBudgetBurnFast firing "$DETECT_TIMEOUT" ||
  fail "detection" "KVErrorBudgetBurnFast did not fire within ${DETECT_TIMEOUT}s of losing quorum"
detect=$((SECONDS - fault_at))
mark "KVErrorBudgetBurnFast firing (page)" "${detect}s after quorum was lost; 5m error ratio $(prom_value 'slo:kv_errors:ratio_rate5m')"

# 4. Mitigate: bring both nodes back.
docker compose start kv2 kv3 > /dev/null
mark "mitigation: kv2 and kv3 restarted" "docker compose start"
wait_ready "${NODES[@]}"
mitigated=$((SECONDS - fault_at))
mark "all nodes ready" "quorum restored ${mitigated}s after it was lost"
code=000
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(peer_port kv3)/internal/kv/gameday-marker" || true)
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ] || fail "catch-up" "kv3 never received the write made while it was down"
mark "kv3 caught up" "its local copy now has gameday-marker (anti-entropy after restart)"
body=$(curl -s "http://127.0.0.1:$(client_port kv3)/kv/gameday-marker")
[ "$body" = "written-while-kv3-down" ] || fail "read after recovery" "kv3 returned '$body'"

# 5. Wait for the page to clear on its own.
wait_alert KVErrorBudgetBurnFast inactive "$RESOLVE_TIMEOUT" ||
  fail "resolution" "KVErrorBudgetBurnFast still active ${RESOLVE_TIMEOUT}s after recovery"
mark "KVErrorBudgetBurnFast resolved" "the 5m window no longer shows errors above 14.4x the budget rate"

# 6. Impact, from the servers' own counters.
window=$((SECONDS - start + 30))
total=$(prom_value "sum(increase(kv_http_requests_total{route=\"kv\"}[${window}s]))")
errors=$(prom_value "sum(increase(kv_http_requests_total{route=\"kv\",code=~\"5..\"}[${window}s]))")
impact=$(python3 - "$total" "$errors" "$window" <<'PY'
import sys
total, errors, window = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
rps = total / window
budget = 0.001 * rps * 28 * 86400  # failures allowed in 28 days at this rate
print(f"{errors:.0f} of {total:.0f} requests failed ({100 * errors / total:.2f}%). "
      f"At {rps:.0f} req/s a 28-day budget allows {budget:.0f} failures; "
      f"this exercise used {100 * errors / budget:.1f}% of it.")
PY
)
mark "impact (server-side)" "$impact"
docker rm -f "$LOAD_CONTAINER" > /dev/null

{
  echo "### Game day timeline"
  echo
  echo "| time | event | detail |"
  echo "|---|---|---|"
  cat "$timeline"
  echo
  echo "Requests sent to a node while it was dead fail at the client and never reach the servers' counters, so the impact above undercounts what clients saw. See docs/incidents/postmortem-gameday-quorum-loss.md."
} | summary
