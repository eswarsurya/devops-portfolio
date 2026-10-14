#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
MNT=/srv/linux-lab-data
if mountpoint -q "$MNT"; then
  umount "$MNT" 2>/dev/null || umount -l "$MNT"
fi
losetup -j "$STATE/disk.img" 2>/dev/null | cut -d: -f1 | xargs -r -n1 losetup -d 2>/dev/null
rmdir "$MNT" 2>/dev/null
rm -f "$STATE/disk.img"
exit 0
