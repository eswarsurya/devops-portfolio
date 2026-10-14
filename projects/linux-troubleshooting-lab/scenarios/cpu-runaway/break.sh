#!/usr/bin/env bash
# Start a process whose worker threads spin in a busy loop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

gcc -O1 -pthread -o "$STATE/report-worker" "$HERE/spin.c"
start_bg app "$STATE/report-worker" 2
pid="$(cat "$STATE/app.pid")"
wait_until 5 test -d "/proc/$pid"
sleep 3   # let it burn for a moment, like a real incident

plant pid "$pid"
plant comm report-worker
plant busy_threads 2
echo "report-worker started with 2 spinning threads (pid $pid)"
