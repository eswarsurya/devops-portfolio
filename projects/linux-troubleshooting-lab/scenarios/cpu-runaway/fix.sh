#!/usr/bin/env bash
# Stop the runaway process: SIGTERM first, SIGKILL only if it ignores it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

pid="$(pgrep -x report-worker | head -1 || true)"
if [[ -n "$pid" ]]; then
  echo "Sending SIGTERM to report-worker (pid $pid)"
  kill -TERM "$pid"
  if ! wait_until 5 bash -c "! kill -0 $pid"; then
    echo "Still alive after 5s, sending SIGKILL"
    kill -KILL "$pid"
  fi
fi
stop_bg app
echo "report-worker stopped. The lasting fix is in the code: workers should block on a queue, not spin."
