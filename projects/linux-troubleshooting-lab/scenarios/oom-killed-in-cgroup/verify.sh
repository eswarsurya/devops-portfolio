#!/usr/bin/env bash
# Healthy = the service is running, no OOM kills in its cgroup over 6 seconds,
# and memory stays well under the limit.
set -euo pipefail
systemctl is-active --quiet lab-cache.service || { echo "lab-cache is not active"; exit 1; }
cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value lab-cache.service)"
check() {
  local kills cur max
  kills="$(awk '$1 == "oom_kill" {print $2}' "$cg/memory.events")"
  cur="$(cat "$cg/memory.current")"
  max="$(cat "$cg/memory.max")"
  echo "oom_kill=$kills memory.current=$cur memory.max=$max"
  [[ "$kills" -eq 0 ]] && (( cur < max * 8 / 10 ))
}
check
sleep 6
check
