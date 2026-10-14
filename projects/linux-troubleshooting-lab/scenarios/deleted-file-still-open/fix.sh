#!/usr/bin/env bash
# 1. Free the space now: truncate the deleted file through /proc (no restart).
# 2. Make the app let go of it: SIGHUP makes it reopen its log at the real path.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
MNT=/srv/linux-lab-logs

pid="$(pgrep -x audit-logger | head -1)"
for f in /proc/"$pid"/fd/*; do
  if [[ "$(readlink "$f")" == "$MNT/"*" (deleted)" ]]; then
    echo "Truncating $(readlink "$f") via $f"
    : > "$f"
  fi
done
df -h "$MNT"

echo "Sending SIGHUP so the app reopens $MNT/app.log"
kill -HUP "$pid"
wait_until 5 test -f "$MNT/app.log"
df -h "$MNT"
