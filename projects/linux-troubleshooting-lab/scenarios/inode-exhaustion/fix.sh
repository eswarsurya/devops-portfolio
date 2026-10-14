#!/usr/bin/env bash
# Delete the stale session files. In real life: only those older than the
# session timeout, e.g. find ... -mmin +60 -delete, run from a timer.
set -euo pipefail
MNT=/srv/linux-lab-data
before="$(find "$MNT/app/cache/sessions" -type f | wc -l)"
find "$MNT/app/cache/sessions" -type f -name 'sess_*' -delete
echo "deleted $before session files"
df -i "$MNT"
