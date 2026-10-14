#!/usr/bin/env bash
# Run a batch parent that forks children and never reaps them.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

printf 'mode=noreap\n' > "$STATE/batch.conf"
systemd-run --unit=lab-batch python3 "$HERE/batch_parent.py" "$STATE/batch.conf"

zombies() { ps -eo stat=,comm= | awk '$1 ~ /^Z/ && $2 == "batch-child"' | wc -l; }
enough_zombies() { [[ "$(zombies)" -ge 8 ]]; }
wait_until 15 enough_zombies
echo "zombies now: $(zombies)"

plant parent_pid "$(systemctl show -p MainPID --value lab-batch.service)"
plant parent_comm batch-parent
plant zombie_count 8
plant unit lab-batch.service
plant kill9_removes_zombie no
