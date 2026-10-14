#!/usr/bin/env bash
# Deploy the parent with a SIGCHLD handler and restart it. Restarting the old
# parent alone also clears the current zombies (they are re-parented to PID 1,
# which reaps them), but they would come back with the next jobs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

printf 'mode=reap\n' > "$STATE/batch.conf"
systemctl restart lab-batch.service
sleep 3
echo "zombies left: $(ps -eo stat=,comm= | awk '$1 ~ /^Z/ && $2 == "batch-child"' | wc -l)"
