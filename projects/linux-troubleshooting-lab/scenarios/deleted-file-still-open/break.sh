#!/usr/bin/env bash
# A 64 MiB filesystem fills up with a 40 MiB log. Someone deletes the log to
# free space, but the app still has it open, so the space is not released.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

MNT=/srv/linux-lab-logs
truncate -s 64M "$STATE/disk.img"
mkfs.ext4 -q -F "$STATE/disk.img"
mkdir -p "$MNT"
mount -o loop "$STATE/disk.img" "$MNT"

start_bg logger python3 "$HERE/logger.py" "$MNT/app.log" 40
pid="$(cat "$STATE/logger.pid")"
big_enough() { [[ -f "$MNT/app.log" ]] && (( $(stat -c %s "$MNT/app.log") >= 40 * 1024 * 1024 )); }
wait_until 60 big_enough
df -h "$MNT"

echo "Deleting the big log to 'free space' while the app still holds it open..."
rm -f "$MNT/app.log"
df -h "$MNT"

fd="$(for f in /proc/"$pid"/fd/*; do
        [[ "$(readlink "$f")" == "$MNT/app.log (deleted)" ]] && basename "$f"
      done | head -1)"
plant pid "$pid"
plant deleted_file "$MNT/app.log"
plant fd "$fd"
