#!/usr/bin/env bash
# Healthy = the consumer is alive and has processed jobs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
pgrep -x job-consumer >/dev/null || { echo "consumer is not running"; exit 1; }
done_jobs="$(grep -c '^processed' "$STATE/consumer.status" || true)"
echo "jobs processed: $done_jobs"
[[ "$done_jobs" -ge 1 ]]
