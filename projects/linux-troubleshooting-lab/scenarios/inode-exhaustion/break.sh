#!/usr/bin/env bash
# A small filesystem with few inodes. A session cache writes one tiny file per
# session and never cleans up. Space is fine; inodes run out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

MNT=/srv/linux-lab-data
truncate -s 64M "$STATE/disk.img"
# -N asks for very few inodes, so the demo fills them in seconds.
mkfs.ext4 -q -F -N 1024 "$STATE/disk.img"
mkdir -p "$MNT"
mount -o loop "$STATE/disk.img" "$MNT"
mkdir -p "$MNT/app/uploads" "$MNT/app/cache/sessions"

echo "Filling inodes with session files..."
i=0
while : > "$MNT/app/cache/sessions/sess_$i" 2>/dev/null; do
  i=$(( i + 1 ))
done
echo "created $i session files before the filesystem refused"
df -h "$MNT"
df -i "$MNT"

plant mount "$MNT"
plant inode_use 100%
plant top_dir "$MNT/app/cache/sessions"
plant write_error "No space left on device"
