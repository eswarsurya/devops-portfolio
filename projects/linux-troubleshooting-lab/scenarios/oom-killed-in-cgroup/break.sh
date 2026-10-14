#!/usr/bin/env bash
# Run a leaking cache worker as a systemd service with a 64 MiB memory limit
# (cgroup v2 memory.max) and no swap. The kernel OOM killer will kill it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

printf 'mode=leak\n' > "$STATE/cache.conf"

systemd-run --unit=lab-cache \
  --property=MemoryMax=64M \
  --property=MemorySwapMax=0 \
  --property=OOMPolicy=continue \
  /bin/bash "$HERE/supervisor.sh" "$STATE/cache.conf"

cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value lab-cache.service)"
echo "service cgroup: $cg"
# Wait for the first OOM kill (the worker allocates 2 MiB every 50 ms).
if ! wait_until 60 grep -Eq '^oom_kill [1-9]' "$cg/memory.events"; then
  echo "no OOM kill happened within 60s"
  cat "$cg/memory.events"
  exit 1
fi
echo "first OOM kill recorded in $cg/memory.events"

plant unit lab-cache.service
plant killed_comm cache-worker
plant memory_max 67108864
plant oom_killed yes
