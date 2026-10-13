#!/usr/bin/env bash
# Wait for a cleaner grid, but never block forever: after MAX_WAIT_MINUTES the job goes ahead.
# If the API can't be reached, the gate opens immediately: a monitoring tool must never stop delivery.
set -uo pipefail

api=${API_URL:?set API_URL}
limit=${MAX_INTENSITY:-250}
max_wait=${MAX_WAIT_MINUTES:-120}
poll=${POLL_MINUTES:-15}
out=${GITHUB_OUTPUT:-/dev/null}
waited=0

while :; do
  if ! body=$(curl -fsS --max-time 10 "${api%/}/api/now"); then
    echo "::warning title=carbon gate::Grid Signal unreachable, continuing without waiting"
    echo "waited_minutes=${waited}" >>"$out"
    exit 0
  fi
  intensity=$(python3 -c 'import json,sys; print(round(json.load(sys.stdin)["intensity_g_per_kwh"]))' <<<"$body")
  if ((intensity <= limit)); then
    echo "Grid at ${intensity} gCO2/kWh (limit ${limit}). Going ahead after ${waited} min."
    break
  fi
  if ((waited >= max_wait)); then
    echo "::notice title=carbon gate::Still ${intensity} gCO2/kWh after ${waited} min. Going ahead anyway."
    break
  fi
  echo "Grid at ${intensity} gCO2/kWh, above ${limit}. Checking again in ${poll} min."
  sleep $((poll * 60))
  waited=$((waited + poll))
done

echo "intensity=${intensity}" >>"$out"
echo "waited_minutes=${waited}" >>"$out"
