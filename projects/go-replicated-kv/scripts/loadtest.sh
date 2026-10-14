#!/usr/bin/env bash
# Run the k6 load test in a container on the compose network.
#
#   scripts/loadtest.sh LABEL MODE
#
# MODE is steady or step (see loadtest/kv.js). These are passed to k6 when
# set: TARGETS STEPS STEP_SECONDS STEADY_RATE STEADY_SECONDS KEYS WRITE_RATIO.
# Results go to $OUT_DIR/LABEL.md and LABEL.json and to the job summary.
# Exits non-zero if a threshold fails (steady mode checks the SLO).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

label=${1:?usage: loadtest.sh LABEL MODE}
mode=${2:?usage: loadtest.sh LABEL MODE}
OUT_DIR=${OUT_DIR:-$PWD/loadtest-results}
mkdir -p "$OUT_DIR"
chmod 777 "$OUT_DIR" # the k6 image runs as its own non-root user

env_args=()
for v in TARGETS STEPS STEP_SECONDS STEADY_RATE STEADY_SECONDS KEYS WRITE_RATIO; do
  if [ -n "${!v:-}" ]; then env_args+=(-e "$v=${!v}"); fi
done

rc=0
docker run --rm --network "$NETWORK" \
  -v "$PWD/loadtest:/scripts:ro" -v "$OUT_DIR:/out" \
  -e "MODE=$mode" -e "LABEL=$label" -e OUT=/out "${env_args[@]}" \
  "$K6_IMAGE" run -q /scripts/kv.js || rc=$?

if [ -f "$OUT_DIR/$label.md" ]; then
  summary < "$OUT_DIR/$label.md"
  echo | summary
  notice "load test $label" "$(oneline < "$OUT_DIR/$label.md")"
fi
if [ "$rc" -ne 0 ]; then
  fail "load test $label" "k6 exited with $rc (99 means a threshold failed). See $label.md in the job summary."
fi
