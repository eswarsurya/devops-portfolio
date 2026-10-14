#!/usr/bin/env bash
# The service keeps "crashing". Why do its workers die?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

step "1. What does the service log say?"
show systemctl status lab-cache.service --no-pager --lines=0
show journalctl -u lab-cache.service --no-pager -n 12 -o cat
echo "Exit status 137 = 128 + 9: the worker was killed by SIGKILL. Nobody in user space sent it, so ask the kernel."

step "2. Did the kernel OOM killer do it?"
show_sh "journalctl -k --no-pager -o short-monotonic | grep -iE 'invoked oom-killer|out of memory|oom-kill:' | tail -n 6"
oomline="$(journalctl -k --no-pager -o cat | grep -E 'Killed process [0-9]+ \(' | tail -n 1)"
ctxline="$(journalctl -k --no-pager -o cat | grep -E 'oom-kill:.*oom_memcg=' | tail -n 1)"
if [[ -z "$oomline" ]]; then
  # Fall back to the kernel ring buffer if journald did not keep kernel messages.
  oomline="$(dmesg | grep -E 'Killed process [0-9]+ \(' | tail -n 1)"
  ctxline="$(dmesg | grep -E 'oom-kill:.*oom_memcg=' | tail -n 1)"
fi
echo "Last kill:    $oomline"
echo "Constraint:   $ctxline"
killed_comm="$(sed -nE 's/.*Killed process [0-9]+ \(([^)]+)\).*/\1/p' <<<"$oomline")"
memcg="$(sed -nE 's/.*oom_memcg=([^,]+).*/\1/p' <<<"$ctxline")"
echo "CONSTRAINT_MEMCG means the limit of one cgroup was hit, not the whole machine running out of RAM."
echo "The cgroup that hit its limit: $memcg"

step "3. What limit does that cgroup have, and how often has it been hit?"
cg="/sys/fs/cgroup$memcg"
show cat "$cg/memory.max"
show cat "$cg/memory.swap.max"
show cat "$cg/memory.current"
[[ -f "$cg/memory.peak" ]] && show cat "$cg/memory.peak"
show cat "$cg/memory.events"
echo "memory.events: 'max' = times usage hit memory.max, 'oom_kill' = processes the OOM killer killed."
oom_kills="$(awk '$1 == "oom_kill" {print $2}' "$cg/memory.events")"
show systemctl show lab-cache.service -p MemoryMax -p MemorySwapMax -p OOMPolicy -p ControlGroup

step "4. What is in the cgroup now, and how fast does it grow?"
show systemd-cgls --no-pager -u "$(basename "$memcg")"
echo "memory.current every 0.5s for 5s (the supervisor restarts the worker 2s after each kill):"
for i in $(seq 1 10); do
  printf '  %4ss  %10s bytes  oom_kill=%s\n' "$(( i * 5 / 10 )).$(( i * 5 % 10 ))" \
    "$(cat "$cg/memory.current")" "$(awk '$1 == "oom_kill" {print $2}' "$cg/memory.events")"
  sleep 0.5
done
echo "Each new worker grows towards the limit and is killed again: a leak, not a one-off spike."

finding unit "$(basename "$memcg")"
finding killed_comm "$killed_comm"
finding memory_max "$(cat "$cg/memory.max")"
if [[ "${oom_kills:-0}" -gt 0 ]]; then finding oom_killed yes; else finding oom_killed no; fi
