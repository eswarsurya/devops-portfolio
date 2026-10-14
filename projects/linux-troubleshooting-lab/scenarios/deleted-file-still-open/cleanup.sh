#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
MNT=/srv/linux-lab-logs
stop_bg logger
pkill -KILL -x audit-logger 2>/dev/null || true
if mountpoint -q "$MNT"; then
  umount "$MNT" 2>/dev/null || umount -l "$MNT"
fi
# A loop device set up by mount -o loop is released on umount (autoclear);
# detach any that is still attached to our image, just in case.
losetup -j "$STATE/disk.img" 2>/dev/null | cut -d: -f1 | xargs -r -n1 losetup -d 2>/dev/null
rmdir "$MNT" 2>/dev/null
rm -f "$STATE/disk.img"
exit 0
