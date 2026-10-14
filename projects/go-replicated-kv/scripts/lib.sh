#!/usr/bin/env bash
# Shared helpers for the load test and game day scripts. Source this file.

PROM_URL=${PROM_URL:-http://127.0.0.1:9090}
K6_IMAGE=${K6_IMAGE:-grafana/k6:0.54.0}
NETWORK=${NETWORK:-kv_default}
# shellcheck disable=SC2034 # used by the scripts that source this file
NODES=(kv1 kv2 kv3)

# Port of each node's client API on the host (see docker-compose.yml).
client_port() { echo "808${1#kv}"; }
peer_port() { echo "707${1#kv}"; }

# summary: append stdin to the GitHub job summary, or print it locally.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat; fi
}

# notice TITLE MESSAGE: a GitHub annotation in CI, a plain line locally.
notice() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=$1::$2"; else echo "[$1] $2"; fi
}

# oneline: encode stdin as one annotation message (newlines become %0A).
oneline() { sed -e ':a' -e 'N' -e '$!ba' -e 's/%/%25/g' -e 's/\r//g' -e 's/\n/%0A/g'; }

# fail TITLE MESSAGE: report an error and exit.
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=$1::$2"; else echo "ERROR [$1] $2" >&2; fi
  exit 1
}

# wait_http URL CODE TIMEOUT_SECONDS: poll until URL answers with CODE.
wait_http() {
  local url=$1 want=$2 deadline=$((SECONDS + $3)) code
  while [ "$SECONDS" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" || true)
    [ "$code" = "$want" ] && return 0
    sleep 1
  done
  return 1
}

# wait_ready NODE...: wait until every node reports ready.
wait_ready() {
  local n
  for n in "$@"; do
    wait_http "http://127.0.0.1:$(client_port "$n")/readyz" 200 90 || fail "not ready" "$n did not become ready within 90s"
  done
}

# alert_state NAME: prints firing, pending or inactive.
alert_state() {
  local state
  state=$(curl -s --max-time 5 "$PROM_URL/api/v1/alerts" |
    jq -r --arg n "$1" '[.data.alerts[] | select(.labels.alertname == $n) | .state] | if index("firing") then "firing" elif index("pending") then "pending" else "inactive" end' 2>/dev/null)
  echo "${state:-inactive}"
}

# wait_alert NAME STATE TIMEOUT_SECONDS: poll until the alert reaches STATE.
wait_alert() {
  local deadline=$((SECONDS + $3))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(alert_state "$1")" = "$2" ] && return 0
    sleep 5
  done
  return 1
}

# prom_value EXPR: first value of an instant query, or "NaN".
prom_value() {
  curl -s --max-time 5 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[0].value[1] // "NaN"'
}
