#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
stop_bg producer
stop_bg consumer
pkill -KILL -x job-producer 2>/dev/null || true
pkill -KILL -x job-consumer 2>/dev/null || true
rm -f "$STATE/jobs.fifo"
exit 0
