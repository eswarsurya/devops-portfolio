#!/usr/bin/env bash
# Stop the stuck producer and run a healthy one. The consumer was never broken.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

stop_bg producer
echo "Stuck producer stopped. Starting a healthy producer."
start_bg producer python3 "$HERE/jobs.py" producer "$STATE/jobs.fifo" "$STATE/consumer.status"
wait_until 10 grep -q 'processed job-3' "$STATE/consumer.status"
cat "$STATE/consumer.status"
