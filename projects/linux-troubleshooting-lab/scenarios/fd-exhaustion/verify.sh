#!/usr/bin/env bash
# Healthy = no EMFILE in the current log and the descriptor count stays flat.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

systemctl is-active --quiet lab-upload-api.service || { echo "service not active"; exit 1; }
pid="$(systemctl show -p MainPID --value lab-upload-api.service)"
before="$(ls "/proc/$pid/fd" | wc -l)"
sleep 2
after="$(ls "/proc/$pid/fd" | wc -l)"
errors="$(grep -c 'ERROR' "$STATE/upload-api.log" || true)"
echo "open fds: $before -> $after, errors in log: $errors"
[[ "$errors" -eq 0 && "$after" -le $(( before + 2 )) && "$after" -lt 20 ]]
