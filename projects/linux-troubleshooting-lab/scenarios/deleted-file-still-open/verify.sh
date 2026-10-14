#!/usr/bin/env bash
# Healthy = df and du agree (within 10 MiB of filesystem overhead) and no
# deleted file is held open on the mount.
set -euo pipefail
MNT=/srv/linux-lab-logs
used_mb="$(df -BM --output=used "$MNT" | tail -1 | tr -dc '0-9')"
files_mb="$(du -sm "$MNT" | awk '{print $1}')"
held="$(lsof -nP -a +L1 "$MNT" 2>/dev/null | awk 'NR>1' | wc -l)"
echo "df used ${used_mb} MiB, du ${files_mb} MiB, deleted-but-open files: $held"
(( used_mb - files_mb < 10 )) && [[ "$held" -eq 0 ]]
